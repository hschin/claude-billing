#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2329

# Behavioral regression tests. Run from the repository root with bash and zsh.

REPO_DIR=$(pwd)
SCRIPT="$REPO_DIR/claude_billing.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-billing-test.XXXXXX") || exit 1
failures=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

assert_eq() {
  expected=$1
  actual=$2
  message=$3
  if [ "$expected" != "$actual" ]; then
    printf '    expected %s, got %s: %s\n' "$expected" "$actual" "$message" >&2
    return 1
  fi
}

run_test() {
  name=$1
  shift
  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name"
    failures=$((failures + 1))
  fi
}

desktop_restore_failure_preserves_both_sessions() (
  HOME="$TEST_ROOT/restore-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  pgrep() { return 1; }

  app="$HOME/Library/Application Support/Claude"
  target="$HOME/.claude-billing/desktop/personal"
  mkdir -p "$app" "$target"
  printf '%s' 'work-session' > "$app/Cookies"
  printf '%s' '{}' > "$app/config.json"
  printf '%s' 'personal-session' > "$target/Cookies"
  printf '%s' 'not-json' > "$target/config-oauth.json"
  _cb_accounts_write "work personal" "work"
  _cb_desktop_owner_set "work"

  claude_billing desktop personal >/dev/null 2>&1

  assert_eq "work" "$(_cb_desktop_owner_get)" "owner must not change after a failed restore" || return 1
  assert_eq "work-session" "$(cat "$app/Cookies")" "live session must remain untouched" || return 1
  assert_eq "personal-session" "$(cat "$target/Cookies")" "target cookie stash must be preserved" || return 1
  assert_eq "not-json" "$(cat "$target/config-oauth.json")" "target metadata stash must be preserved"
)

desktop_backup_replaces_a_stale_logged_in_session() (
  HOME="$TEST_ROOT/stale-backup"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  pgrep() { return 1; }

  app="$HOME/Library/Application Support/Claude"
  work="$HOME/.claude-billing/desktop/work"
  target="$HOME/.claude-billing/desktop/personal"
  mkdir -p "$app" "$work" "$target"
  printf '%s' '{}' > "$app/config.json"
  printf '%s' 'stale-work-session' > "$work/Cookies"
  printf '%s' 'personal-session' > "$target/Cookies"
  printf '%s' '{}' > "$target/config-oauth.json"
  _cb_accounts_write "work personal" "work"
  _cb_desktop_owner_set "work"

  claude_billing desktop personal >/dev/null 2>&1

  if [ -e "$work/Cookies" ]; then
    printf '    stale work cookie stash still exists\n' >&2
    return 1
  fi
  assert_eq "personal-session" "$(cat "$app/Cookies")" "target session should become live"
)

nounset_no_args_shows_usage() (
  HOME="$TEST_ROOT/nounset"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  set -u
  output=$(claude_billing 2>&1)
  rc=$?
  set +u

  assert_eq "0" "$rc" "no-argument invocation should show help" || return 1
  case "$output" in
    "Usage: claude-billing"*) return 0 ;;
    *) printf '    usage output was not printed\n' >&2; return 1 ;;
  esac
)

bedrock_rejects_an_empty_explicit_profile() (
  HOME="$TEST_ROOT/empty-profile"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{"EXISTING":"yes"}}' > "$HOME/.claude/settings.json"
  {
    printf '%s\n' 'CLAUDE_BILLING_REGION="us-east-1"'
    printf '%s\n' 'CLAUDE_BILLING_SONNET="sonnet"'
    printf '%s\n' 'CLAUDE_BILLING_OPUS="opus"'
    printf '%s\n' 'CLAUDE_BILLING_HAIKU="haiku"'
    printf '%s\n' 'CLAUDE_BILLING_FABLE=""'
    printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE_MODE="explicit"'
    printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE=""'
  } > "$HOME/.claude-billing.conf"

  claude_billing bedrock >/dev/null 2>&1
  rc=$?

  assert_eq "1" "$rc" "empty explicit profile should be rejected" || return 1
  assert_eq "missing" "$(jq -r '.env.AWS_PROFILE // "missing"' "$HOME/.claude/settings.json")" \
    "settings must remain unchanged"
)

configure_rejects_an_empty_explicit_profile() (
  HOME="$TEST_ROOT/config-empty-profile"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  aws() { return 1; }

  responses="$HOME/responses"
  mkdir -p "$HOME"
  printf '2\n\n' > "$responses"
  exec 3< "$responses"
  # shellcheck disable=SC2162  # callers pass -r through "$@"
  _cb_read() { read "$@" <&3; }

  claude_billing config >/dev/null 2>&1
  rc=$?
  exec 3<&-

  assert_eq "1" "$rc" "configuration should reject an empty explicit profile" || return 1
  if [ -e "$HOME/.claude-billing.conf" ]; then
    printf '    invalid configuration file was written\n' >&2
    return 1
  fi
)

failed_installer_download_preserves_the_installed_script() (
  home="$TEST_ROOT/installer-download"
  bin="$home/bin"
  installed="$home/.claude-billing/claude_billing.sh"
  mkdir -p "$bin" "$(dirname "$installed")"
  printf '%s' 'known-good-installed-copy' > "$installed"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=""'
    printf '%s\n' 'while [ "$#" -gt 0 ]; do'
    printf '%s\n' '  if [ "$1" = "-o" ]; then shift; out=$1; fi'
    printf '%s\n' '  shift'
    printf '%s\n' 'done'
    printf '%s\n' ': > "$out"'
    printf '%s\n' 'exit 22'
  } > "$bin/curl"
  chmod +x "$bin/curl"

  PATH="$bin:$PATH" HOME="$home" bash "$REPO_DIR/install.sh" >/dev/null 2>&1
  rc=$?

  if [ "$rc" -eq 0 ]; then
    printf '    failed download unexpectedly succeeded\n' >&2
    return 1
  fi
  assert_eq "known-good-installed-copy" "$(cat "$installed")" \
    "a failed update must preserve the installed script"
)

uninstall_removes_only_the_legacy_source_line() (
  HOME="$TEST_ROOT/uninstall-legacy-source"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"

  mkdir -p "$HOME"
  printf '%s\n' \
    'export MY_TOOL_NOTE=claude-billing-custom' \
    "source \"$HOME/.claude-billing/claude_billing.sh\"" \
    'export KEEP_ME=yes' > "$HOME/.zshrc"
  responses="$HOME/responses"
  printf 'y\nn\nn\n' > "$responses"
  exec 3< "$responses"
  # shellcheck disable=SC2162  # callers pass -r through "$@"
  _cb_read() { read "$@" <&3; }

  claude_billing uninstall >/dev/null 2>&1
  rc=$?
  exec 3<&-

  assert_eq "0" "$rc" "uninstall should succeed" || return 1
  assert_eq "export MY_TOOL_NOTE=claude-billing-custom
export KEEP_ME=yes" "$(cat "$HOME/.zshrc")" \
    "uninstall must preserve unrelated shell configuration"
)

failed_subscription_restore_rolls_back_the_mode_switch() (
  HOME="$TEST_ROOT/subscription-restore-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  claude() { return 1; }

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{"ANTHROPIC_API_KEY":"old-key"}}' > "$HOME/.claude/settings.json"

  claude_billing subscription > "$HOME/output" 2>&1
  rc=$?

  assert_eq "1" "$rc" "failed authentication should fail the switch" || return 1
  assert_eq "old-key" "$(jq -r '.env.ANTHROPIC_API_KEY' "$HOME/.claude/settings.json")" \
    "settings should roll back after failed authentication" || return 1
  if [ -e "$HOME/.claude-billing-mode" ]; then
    printf '    mode cache was written after failed authentication\n' >&2
    return 1
  fi
  case "$(cat "$HOME/output")" in
    *Switched*) printf '    success message was printed after failed authentication\n' >&2; return 1 ;;
  esac
)

failed_oauth_backup_rolls_back_api_mode() (
  HOME="$TEST_ROOT/api-backup-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{"EXISTING":"yes"}}' > "$HOME/.claude/settings.json"
  _cb_cred_file_store "anthropic-api-key" "api-key"
  _cb_cred_file_store "Claude Code-credentials" "oauth-token"
  chmod 500 "$HOME"

  claude_billing api > "$HOME/.claude/output" 2>&1
  rc=$?
  chmod 700 "$HOME"

  assert_eq "1" "$rc" "failed OAuth backup should fail the API switch" || return 1
  assert_eq "missing" "$(jq -r '.env.ANTHROPIC_API_KEY // "missing"' "$HOME/.claude/settings.json")" \
    "settings should roll back after failed OAuth backup" || return 1
  assert_eq "oauth-token" "$(_cb_cred_file_retrieve "Claude Code-credentials")" \
    "the live OAuth token should remain available" || return 1
  if [ -e "$HOME/.claude-billing-mode" ]; then
    printf '    mode cache was written after failed OAuth backup\n' >&2
    return 1
  fi
)

failed_oauth_backup_rolls_back_bedrock_mode() (
  HOME="$TEST_ROOT/bedrock-backup-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{"EXISTING":"yes"}}' > "$HOME/.claude/settings.json"
  {
    printf '%s\n' 'CLAUDE_BILLING_REGION="us-east-1"'
    printf '%s\n' 'CLAUDE_BILLING_SONNET="sonnet"'
    printf '%s\n' 'CLAUDE_BILLING_OPUS="opus"'
    printf '%s\n' 'CLAUDE_BILLING_HAIKU="haiku"'
    printf '%s\n' 'CLAUDE_BILLING_FABLE=""'
    printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE_MODE="inherit"'
    printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE=""'
  } > "$HOME/.claude-billing.conf"
  _cb_cred_file_store "Claude Code-credentials" "oauth-token"
  chmod 500 "$HOME"

  claude_billing bedrock > "$HOME/.claude/output" 2>&1
  rc=$?
  chmod 700 "$HOME"

  assert_eq "1" "$rc" "failed OAuth backup should fail the Bedrock switch" || return 1
  assert_eq "missing" "$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // "missing"' "$HOME/.claude/settings.json")" \
    "settings should roll back after failed OAuth backup" || return 1
  if [ -e "$HOME/.claude-billing-mode" ]; then
    printf '    mode cache was written after failed OAuth backup\n' >&2
    return 1
  fi
)

add_key_preserves_shell_state_when_storage_fails() (
  HOME="$TEST_ROOT/add-key-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  # shellcheck disable=SC2162  # callers pass -r through "$@"
  _cb_read() { read "$@" <<< "secret-value"; }
  key="user-value"

  mkdir -p "$HOME/output"
  chmod 500 "$HOME"
  claude_billing add-key > "$HOME/output/result" 2>&1
  rc=$?
  chmod 700 "$HOME"

  assert_eq "1" "$rc" "failed credential storage should fail add-key" || return 1
  assert_eq "user-value" "$key" "add-key must not overwrite a caller variable" || return 1
  case "$(cat "$HOME/output/result")" in
    *saved*) printf '    success message was printed after failed storage\n' >&2; return 1 ;;
  esac
)

remove_account_keeps_registration_when_secret_deletion_fails() (
  HOME="$TEST_ROOT/remove-account-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"

  mkdir -p "$HOME/output"
  _cb_accounts_write "work" ""
  _cb_cred_file_store "$(_cb_acct_service "work")" "oauth-token"
  _cb_cred_file_store "$(_cb_acct_meta_service "work")" '{"accountUuid":"work"}'
  chmod 500 "$HOME"

  claude_billing remove-account work > "$HOME/output/result" 2>&1
  rc=$?
  chmod 700 "$HOME"

  assert_eq "1" "$rc" "failed secret deletion should fail account removal" || return 1
  assert_eq "work" "$(_cb_accounts_list)" "account must remain registered for retry" || return 1
  assert_eq "oauth-token" "$(_cb_cred_file_retrieve "$(_cb_acct_service "work")")" \
    "stored token must remain manageable"
)

uninstall_reports_failed_secret_deletion() (
  HOME="$TEST_ROOT/uninstall-secret-failure"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"

  mkdir -p "$HOME/output"
  _cb_cred_file_store "anthropic-api-key" "api-key"
  responses="$HOME/responses"
  printf 'y\ny\nn\n' > "$responses"
  exec 3< "$responses"
  # shellcheck disable=SC2162  # callers pass -r through "$@"
  _cb_read() { read "$@" <&3; }
  chmod 500 "$HOME"

  claude_billing uninstall > "$HOME/output/result" 2>&1
  rc=$?
  chmod 700 "$HOME"
  exec 3<&-

  assert_eq "1" "$rc" "uninstall should report partial credential cleanup" || return 1
  assert_eq "api-key" "$(_cb_cred_file_retrieve "anthropic-api-key")" \
    "failed deletion must not be reported as complete" || return 1
  case "$(cat "$HOME/output/result")" in
    *"Removed Anthropic API key"*) printf '    failed deletion was reported as removed\n' >&2; return 1 ;;
  esac
)

run_test "failed desktop restore preserves live and stashed sessions" \
  desktop_restore_failure_preserves_both_sessions
run_test "desktop backup replaces a stale logged-in session" \
  desktop_backup_replaces_a_stale_logged_in_session
run_test "no-argument invocation works with nounset" \
  nounset_no_args_shows_usage
run_test "Bedrock rejects an empty explicit AWS profile" \
  bedrock_rejects_an_empty_explicit_profile
run_test "configuration rejects an empty explicit AWS profile" \
  configure_rejects_an_empty_explicit_profile
run_test "failed installer download preserves the installed script" \
  failed_installer_download_preserves_the_installed_script
run_test "uninstall removes only the legacy source line" \
  uninstall_removes_only_the_legacy_source_line
run_test "failed subscription restore rolls back the mode switch" \
  failed_subscription_restore_rolls_back_the_mode_switch
run_test "failed OAuth backup rolls back API mode" \
  failed_oauth_backup_rolls_back_api_mode
run_test "failed OAuth backup rolls back Bedrock mode" \
  failed_oauth_backup_rolls_back_bedrock_mode
run_test "add-key preserves shell state when storage fails" \
  add_key_preserves_shell_state_when_storage_fails
run_test "remove-account keeps registration when secret deletion fails" \
  remove_account_keeps_registration_when_secret_deletion_fails
run_test "uninstall reports failed secret deletion" \
  uninstall_reports_failed_secret_deletion

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all tests passed\n'
