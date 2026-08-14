#!/usr/bin/env bash
# The test cases define command mocks that ShellCheck cannot see being invoked
# after claude_billing.sh is sourced. SC2317 is used by ShellCheck 0.9, while
# newer releases report the same intentional pattern as SC2329.
# shellcheck disable=SC1091,SC2016,SC2317,SC2329

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
  rc=$?

  assert_eq "1" "$rc" "an explicit failed desktop switch should return an error" || return 1
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

desktop_switch_relaunches_a_running_app() (
  HOME="$TEST_ROOT/desktop-relaunch"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  running="$HOME/claude-running"
  open_call="$HOME/open-call"
  mkdir -p "$HOME"
  touch "$running"
  pgrep() { [ -f "$running" ]; }
  osascript() { rm -f "$running"; }
  open() { printf '%s\n' "$*" > "$open_call"; }
  sleep() { :; }
  # shellcheck disable=SC2034  # assigns _cb_desktop_quit's dynamically scoped local
  _cb_read() { confirm=""; }

  app="$HOME/Library/Application Support/Claude"
  target="$HOME/.claude-billing/desktop/personal"
  mkdir -p "$app" "$target"
  printf '%s' 'work-session' > "$app/Cookies"
  printf '%s' '{}' > "$app/config.json"
  printf '%s' 'personal-session' > "$target/Cookies"
  printf '%s' '{}' > "$target/config-oauth.json"
  _cb_accounts_write "work personal" "work"
  _cb_desktop_owner_set "work"

  claude_billing desktop personal >/dev/null 2>&1 || return 1

  assert_eq "-b com.anthropic.claudefordesktop" "$(cat "$open_call")" "a running Claude.app should reopen after switching" || return 1
  assert_eq "personal" "$(_cb_desktop_owner_get)" "the target account should own the relaunched app"
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

remove_account_yes_skips_the_active_account_prompt() (
  HOME="$TEST_ROOT/remove-account-yes"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  prompt_marker="$HOME/prompted"
  _cb_read() { touch "$prompt_marker"; return 1; }

  mkdir -p "$HOME/.claude-billing/desktop/work"
  _cb_accounts_write "work personal" "work"

  claude_billing remove-account work --yes >/dev/null 2>&1 || return 1

  [ ! -e "$prompt_marker" ] || {
    printf '    --yes unexpectedly prompted for confirmation\n' >&2
    return 1
  }
  assert_eq "personal" "$(_cb_accounts_list)" "confirmed removal should update the registry" || return 1
  assert_eq "" "$(_cb_active_get)" "confirmed removal should clear active ownership" || return 1
  [ ! -e "$HOME/.claude-billing/desktop/work" ] || {
    printf '    confirmed removal left the desktop stash behind\n' >&2
    return 1
  }
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

bedrock_explicit_profile_is_shown_in_the_mode_indicator() (
  HOME="$TEST_ROOT/bedrock-explicit-indicator"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{}}' > "$HOME/.claude/settings.json"
  {
    printf '%s\n' 'CLAUDE_BILLING_REGION="us-east-1"'
    printf '%s\n' 'CLAUDE_BILLING_SONNET="sonnet"'
    printf '%s\n' 'CLAUDE_BILLING_OPUS="opus"'
    printf '%s\n' 'CLAUDE_BILLING_HAIKU="haiku"'
    printf '%s\n' 'CLAUDE_BILLING_FABLE=""'
    printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE_MODE="explicit"'
    printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE="work-aws"'
  } > "$HOME/.claude-billing.conf"

  claude_billing bedrock >/dev/null 2>&1

  assert_eq "bedrock:work-aws" "$(claude_billing_prompt)" \
    "shell prompt should include the explicit AWS profile" || return 1
  assert_eq "bedrock:work-aws" "$(cat "$HOME/.claude-billing-mode")" \
    "statusline cache should include the explicit AWS profile"
)

status_resync_uses_the_inherited_bedrock_profile() (
  HOME="$TEST_ROOT/bedrock-inherited-indicator"
  AWS_PROFILE="team-aws"
  export HOME AWS_PROFILE
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"

  mkdir -p "$HOME/.claude"
  printf '%s' \
    '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-east-1"}}' \
    > "$HOME/.claude/settings.json"

  claude_billing status >/dev/null 2>&1

  assert_eq "bedrock:team-aws" "$(claude_billing_prompt)" \
    "status resync should include the inherited AWS profile"
)

json_status_exposes_menu_bar_state() (
  HOME="$TEST_ROOT/json-status"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"

  mkdir -p "$HOME/.claude"
  printf '%s' \
    '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-east-1","AWS_PROFILE":"work-aws"}}' \
    > "$HOME/.claude/settings.json"
  _cb_accounts_write "work personal" "work"

  output=$(claude_billing status --json)

  assert_eq "bedrock:work-aws" "$(printf '%s' "$output" | jq -r '.mode')" \
    "JSON status should expose the effective billing mode" || return 1
  assert_eq 'work,personal' "$(printf '%s' "$output" | jq -r '.accounts | join(",")')" \
    "JSON status should expose registered accounts"
)

# Seeds a fake ~/.aws with one sso-session shared by two profiles, one legacy
# profile pointing at the same start URL, and one expired session. The home
# directory is passed in because callers run inside their own subshell.
seed_aws_sso_fixture() {
  aws_home=$1
  mkdir -p "$aws_home/.aws/sso/cache"
  cat > "$aws_home/.aws/config" <<'EOF'
[profile dev]
sso_session = admin-session
sso_account_id = 111111111111

[sso-session admin-session]
sso_start_url = https://example.awsapps.com/start
sso_region = ap-southeast-1

[profile prod]
sso_session = admin-session

[sso-session other]
sso_start_url = https://other.awsapps.com/start/

[profile iam]
sso_session = other

[profile no-sso]
region = ap-southeast-1

[default]
sso_start_url = https://example.awsapps.com/start
EOF
  # Token files are named after the SHA-1 of the sso-session name, exactly as
  # the AWS CLI writes them. `orphan` shares the start URL but sits under a
  # different key (what a renamed session leaves behind) and carries a much
  # later expiry, so it must lose to the correctly keyed token.
  printf '%s' '{"startUrl":"https://example.awsapps.com/start/","expiresAt":"2026-08-14T13:00:00.123Z"}' \
    > "$aws_home/.aws/sso/cache/$(_cb_sha1 'admin-session').json"
  printf '%s' '{"startUrl":"https://example.awsapps.com/start","expiresAt":"2031-01-01T00:00:00Z"}' \
    > "$aws_home/.aws/sso/cache/$(_cb_sha1 'renamed-away').json"
  printf '%s' '{"startUrl":"https://other.awsapps.com/start","expiresAt":"2026-01-01T00:00:00Z"}' \
    > "$aws_home/.aws/sso/cache/$(_cb_sha1 'other').json"
  printf '%s' '{"clientId":"abc"}' > "$aws_home/.aws/sso/cache/registration.json"
  printf '%s' 'not json at all' > "$aws_home/.aws/sso/cache/broken.json"
}

# Usage tests never touch the network: `curl` is replaced by a shell function,
# and credentials use the file-backed Windows store.
usage_reports_limits_for_each_account() (
  HOME="$TEST_ROOT/usage-ok"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW

  # Access tokens expire in milliseconds; work is live, personal lapsed an hour ago.
  _cb_cred_store "Claude Code-credentials" \
    '{"claudeAiOauth":{"accessToken":"live-token","expiresAt":1786712400000}}'
  _cb_cred_store "Claude Code-credentials-acct-personal" \
    '{"claudeAiOauth":{"accessToken":"stale-token","expiresAt":1786705200000}}'
  _cb_accounts_write "work personal" "work"
  curl() {
    cat >/dev/null
    printf '%s' '{"limits":[{"kind":"session","group":"session","percent":72.0,"severity":"warning","is_active":true},{"kind":"weekly_all","group":"weekly","percent":41,"severity":"normal","resets_at":"2026-08-19T01:59:59.838154+00:00","is_active":true}],"spend":{"enabled":true,"percent":86,"severity":"warning","used":{"amount_minor":1720,"currency":"USD","exponent":2},"limit":{"amount_minor":2000,"currency":"USD","exponent":2}}}'
    printf '\n200'
  }

  output=$(_cb_usage_json)

  assert_eq "work,personal" "$(printf '%s' "$output" | jq -r 'map(.account) | join(",")')" \
    "usage should be reported per registered account" || return 1
  assert_eq "ok" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "the live account should report usage" || return 1
  assert_eq "72" "$(printf '%s' "$output" | jq -r '.[0].limits[0].percent')" \
    "fractional percents should be rounded to integers" || return 1
  assert_eq "86" "$(printf '%s' "$output" | jq -r '.[0].spend.percent')" \
    "extra usage credits should be reported when enabled" || return 1
  assert_eq "17.2" "$(printf '%s' "$output" | jq -r '.[0].spend.used')" \
    "spend should be converted from minor units" || return 1
  assert_eq "token-expired" "$(printf '%s' "$output" | jq -r '.[1].status')" \
    "an expired token must be reported, not refreshed or used" || return 1
  assert_eq "600" "$(wc -c < "$HOME/.claude-billing/usage-cache.json" | tr -d ' ' | sed 's/^[0-9]*$/600/')" \
    "usage results should be cached" || return 1
  assert_eq "600" "$(stat -f '%Lp' "$HOME/.claude-billing/usage-cache.json" 2>/dev/null || stat -c '%a' "$HOME/.claude-billing/usage-cache.json")" \
    "the usage cache must not be world-readable"
)

usage_reports_the_prepaid_credit_balance() (
  HOME="$TEST_ROOT/usage-credits"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW
  _cb_cred_store "Claude Code-credentials" \
    '{"claudeAiOauth":{"accessToken":"live-token","expiresAt":1786712400000}}'
  # The credits endpoint is per organization, so it needs the account identity.
  printf '%s' '{"oauthAccount":{"organizationUuid":"org-uuid-1"}}' > "$HOME/.claude.json"
  curl() {
    config=$(cat)
    case "$config" in
      *prepaid/credits*)
        case "$config" in
          *org-uuid-1*) ;;
          *) printf '\n400'; return 0 ;;
        esac
        printf '%s' '{"amount":8871,"currency":"USD","balance":{"money":null,"credits":{"amount_minor":8871,"exponent":2}},"tranches":[{"remaining_amount_minor_units":590,"expires_at":"2027-03-27T00:00:00Z"}],"promo_tranches":[{"remaining_amount_minor_units":8279,"expires_at":"2026-09-19T00:00:00Z"}],"next_expires_at":"2026-09-19T00:00:00Z"}'
        printf '\n200'
        ;;
      *)
        printf '%s' '{"limits":[{"kind":"session","percent":10,"severity":"normal","is_active":true}]}'
        printf '\n200'
        ;;
    esac
  }

  output=$(_cb_usage_json)

  assert_eq "88.71" "$(printf '%s' "$output" | jq -r '.[0].credits.balance')" \
    "the credit balance should be converted from minor units" || return 1
  assert_eq "USD" "$(printf '%s' "$output" | jq -r '.[0].credits.currency')" \
    "the credit currency should be reported" || return 1
  assert_eq "2026-09-19T00:00:00Z" "$(printf '%s' "$output" | jq -r '.[0].credits.nextExpiresAt')" \
    "the soonest expiry should be reported" || return 1
  assert_eq "82.79" "$(printf '%s' "$output" | jq -r '.[0].credits.expiringAmount')" \
    "the amount expiring soonest should be totalled across tranches" || return 1
  assert_eq "10" "$(printf '%s' "$output" | jq -r '.[0].limits[0].percent')" \
    "plan limits should still be reported alongside credits"
)

usage_survives_a_credits_endpoint_failure() (
  HOME="$TEST_ROOT/usage-credits-fail"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW
  _cb_cred_store "Claude Code-credentials" \
    '{"claudeAiOauth":{"accessToken":"live-token","expiresAt":1786712400000}}'
  printf '%s' '{"oauthAccount":{"organizationUuid":"org-uuid-1"}}' > "$HOME/.claude.json"
  # Not every account has credits: a refusal must not cost us the plan limits.
  curl() {
    config=$(cat)
    case "$config" in
      *prepaid/credits*) printf '\n403' ;;
      *)
        printf '%s' '{"limits":[{"kind":"session","percent":10,"severity":"normal","is_active":true}]}'
        printf '\n200'
        ;;
    esac
  }

  output=$(_cb_usage_json)

  assert_eq "ok" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "a credits failure must not fail the usage read" || return 1
  assert_eq "null" "$(printf '%s' "$output" | jq -r '.[0].credits')" \
    "credits should simply be absent when unavailable" || return 1
  assert_eq "10" "$(printf '%s' "$output" | jq -r '.[0].limits[0].percent')" \
    "plan limits should survive a credits failure"
)

usage_skips_credits_without_an_account_identity() (
  HOME="$TEST_ROOT/usage-credits-noorg"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW
  _cb_cred_store "Claude Code-credentials" \
    '{"claudeAiOauth":{"accessToken":"live-token","expiresAt":1786712400000}}'
  calls="$HOME/credits-calls"
  curl() {
    config=$(cat)
    case "$config" in
      *prepaid/credits*) printf '%s\n' "called" >> "$calls"; printf '\n200' ;;
      *)
        printf '%s' '{"limits":[]}'
        printf '\n200'
        ;;
    esac
  }

  _cb_usage_json >/dev/null

  if [ -e "$calls" ]; then
    printf '    the credits endpoint was called without an organization UUID\n' >&2
    return 1
  fi
)

usage_serves_fresh_entries_from_cache() (
  HOME="$TEST_ROOT/usage-cache"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW
  _cb_cred_store "Claude Code-credentials" \
    '{"claudeAiOauth":{"accessToken":"live-token","expiresAt":1786712400000}}'
  calls="$HOME/curl-calls"
  curl() {
    cat >/dev/null
    printf '%s\n' "call" >> "$calls"
    printf '%s' '{"limits":[{"kind":"session","percent":5,"severity":"normal","is_active":true}]}'
    printf '\n200'
  }

  _cb_usage_json >/dev/null
  _cb_usage_json >/dev/null
  first=$(wc -l < "$calls" | tr -d ' ')
  _cb_usage_json --refresh >/dev/null
  second=$(wc -l < "$calls" | tr -d ' ')

  assert_eq "1" "$first" "a fresh cache entry should not be refetched" || return 1
  assert_eq "2" "$second" "--refresh should force a fetch"
)

usage_keeps_the_last_good_figures_when_a_fetch_fails() (
  HOME="$TEST_ROOT/usage-stale"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW
  _cb_cred_store "Claude Code-credentials" \
    '{"claudeAiOauth":{"accessToken":"live-token","expiresAt":1786799999000}}'
  curl() {
    cat >/dev/null
    printf '%s' '{"limits":[{"kind":"session","percent":33,"severity":"normal","is_active":true}]}'
    printf '\n200'
  }
  _cb_usage_json >/dev/null

  # Ten minutes later the endpoint is down: the cached figure stays, flagged.
  CLAUDE_BILLING_TEST_NOW=1786709400
  curl() { cat >/dev/null; printf '\n500'; }
  output=$(_cb_usage_json)

  assert_eq "ok" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "the last good usage should survive a failed refresh" || return 1
  assert_eq "33" "$(printf '%s' "$output" | jq -r '.[0].limits[0].percent')" \
    "cached percentages should be preserved" || return 1
  assert_eq "600" "$(printf '%s' "$output" | jq -r '.[0].ageSeconds')" \
    "cached usage should report its age" || return 1
  assert_eq "api.anthropic.com returned HTTP 500" "$(printf '%s' "$output" | jq -r '.[0].staleReason')" \
    "a stale figure should say why it was not refreshed"
)

usage_reports_a_missing_login_without_calling_the_api() (
  HOME="$TEST_ROOT/usage-no-token"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="windows"
  mkdir -p "$HOME"
  curl() { printf '%s\n' "called" >> "$HOME/curl-calls"; printf '\n200'; }

  output=$(_cb_usage_json)

  assert_eq "no-token" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "no stored login should report no-token" || return 1
  if [ -e "$HOME/curl-calls" ]; then
    printf '    the API was called without a token\n' >&2
    return 1
  fi
)

sso_status_reports_expiry_for_each_session() (
  HOME="$TEST_ROOT/sso-status"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  seed_aws_sso_fixture "$HOME"
  # 2026-08-14T12:00:00Z — one hour before the live token expires.
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW

  output=$(_cb_sso_status_json "prod")

  assert_eq "admin-session,other" "$(printf '%s' "$output" | jq -r 'map(.name) | join(",")')" \
    "sessions should be grouped by start URL and named after the sso-session block" || return 1
  assert_eq "valid" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "a live token should report as valid" || return 1
  assert_eq "3600" "$(printf '%s' "$output" | jq -r '.[0].secondsRemaining')" \
    "the token keyed to this session should win over one that only shares its URL" || return 1
  assert_eq "default,dev,prod" "$(printf '%s' "$output" | jq -r '.[0].profiles | join(",")')" \
    "every profile sharing the start URL should be listed" || return 1
  assert_eq "true" "$(printf '%s' "$output" | jq -r '.[0].active')" \
    "the session behind the current Bedrock profile should be flagged" || return 1
  assert_eq "expired" "$(printf '%s' "$output" | jq -r '.[1].status')" \
    "a lapsed token should report as expired" || return 1
  assert_eq "false" "$(printf '%s' "$output" | jq -r '.[1].active')" \
    "unrelated sessions should not be flagged as in use"
)

sso_status_ignores_a_token_orphaned_by_a_session_rename() (
  HOME="$TEST_ROOT/sso-renamed"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  mkdir -p "$HOME/.aws/sso/cache"
  printf '%s\n' '[sso-session endeavourx]' 'sso_start_url = https://example.awsapps.com/start' \
    > "$HOME/.aws/config"
  # Left behind when the session was renamed: same portal, old lookup key. The
  # AWS CLI would refuse to use it, so neither may we.
  printf '%s' '{"startUrl":"https://example.awsapps.com/start","expiresAt":"2031-01-01T00:00:00Z"}' \
    > "$HOME/.aws/sso/cache/$(_cb_sha1 'admin-session').json"

  output=$(_cb_sso_status_json "")

  assert_eq "signed-out" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "a token under a former session name must not count as a live login"
)

sso_status_matches_legacy_profile_tokens_by_start_url() (
  HOME="$TEST_ROOT/sso-legacy-key"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  mkdir -p "$HOME/.aws/sso/cache"
  printf '%s\n' '[profile legacy]' 'sso_start_url = https://legacy.awsapps.com/start' \
    > "$HOME/.aws/config"
  # Legacy profiles have no session name, so the AWS CLI keys the token on the
  # start URL instead.
  printf '%s' '{"startUrl":"https://legacy.awsapps.com/start","expiresAt":"2026-08-14T13:00:00Z"}' \
    > "$HOME/.aws/sso/cache/$(_cb_sha1 'https://legacy.awsapps.com/start').json"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW

  output=$(_cb_sso_status_json "legacy")

  assert_eq "valid" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "legacy profile tokens should be matched on the start URL" || return 1
  assert_eq "profile" "$(printf '%s' "$output" | jq -r '.[0].kind')" \
    "a legacy profile login should be reported as profile-style"
)

sso_status_reports_a_missing_token_as_signed_out() (
  HOME="$TEST_ROOT/sso-signed-out"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  mkdir -p "$HOME/.aws"
  printf '%s\n' '[sso-session admin]' 'sso_start_url = https://example.awsapps.com/start' \
    > "$HOME/.aws/config"

  output=$(_cb_sso_status_json "")

  assert_eq "signed-out" "$(printf '%s' "$output" | jq -r '.[0].status')" \
    "a session with no cached token should report as signed out" || return 1
  assert_eq "null" "$(printf '%s' "$output" | jq -r '.[0].secondsRemaining')" \
    "an unknown expiry should stay null"
)

sso_status_is_empty_without_aws_config() (
  HOME="$TEST_ROOT/sso-none"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"

  assert_eq "[]" "$(_cb_sso_status_json "")" "no AWS config should yield no sessions"
)

sso_login_selects_the_matching_aws_flag() (
  HOME="$TEST_ROOT/sso-login"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  mkdir -p "$HOME/.aws"
  cat > "$HOME/.aws/config" <<'EOF'
[sso-session admin]
sso_start_url = https://example.awsapps.com/start

[default]
sso_start_url = https://legacy.awsapps.com/start
EOF
  aws() { printf '%s\n' "aws $*" >> "$HOME/aws-calls"; }

  claude_billing sso-login admin >/dev/null 2>&1
  claude_billing sso-login default >/dev/null 2>&1
  claude_billing sso-login nope >/dev/null 2>&1
  rc=$?

  assert_eq "1" "$rc" "an unknown session name should fail" || return 1
  assert_eq "aws sso login --sso-session admin" "$(sed -n 1p "$HOME/aws-calls")" \
    "sso-session logins should use --sso-session" || return 1
  assert_eq "aws sso login --profile default" "$(sed -n 2p "$HOME/aws-calls")" \
    "legacy profile logins should use --profile"
)

json_status_exposes_sso_sessions() (
  HOME="$TEST_ROOT/json-status-sso"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  seed_aws_sso_fixture "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW

  mkdir -p "$HOME/.claude"
  printf '%s' \
    '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-east-1","AWS_PROFILE":"dev"}}' \
    > "$HOME/.claude/settings.json"

  output=$(claude_billing status --json)

  assert_eq "admin-session" "$(printf '%s' "$output" | jq -r '.awsSso[0].name')" \
    "JSON status should expose AWS SSO sessions for the menu bar" || return 1
  assert_eq "true" "$(printf '%s' "$output" | jq -r '.awsSso[0].active')" \
    "the session behind the settings AWS_PROFILE should be flagged" || return 1
  assert_eq "expired" "$(printf '%s' "$output" | jq -r '.awsSso[1].status')" \
    "JSON status should expose expired sessions"
)

json_status_omits_sso_when_billing_is_not_bedrock() (
  HOME="$TEST_ROOT/json-status-sso-sub"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  seed_aws_sso_fixture "$HOME"
  CLAUDE_BILLING_TEST_NOW=1786708800
  export CLAUDE_BILLING_TEST_NOW

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{}}' > "$HOME/.claude/settings.json"

  output=$(claude_billing status --json)

  assert_eq "false" "$(printf '%s' "$output" | jq -r 'any(.awsSso[]; .active)')" \
    "no session should be in use when Claude Code is not on Bedrock" || return 1
  assert_eq "2" "$(printf '%s' "$output" | jq -r '.awsSso | length')" \
    "sessions should still be reported outside Bedrock mode"
)

json_status_names_the_profile_bedrock_would_use() (
  HOME="$TEST_ROOT/json-status-bedrock-profile"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"

  mkdir -p "$HOME/.claude"
  printf '%s' '{"env":{}}' > "$HOME/.claude/settings.json"
  printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE_MODE="explicit"' 'CLAUDE_BILLING_AWS_PROFILE="eaix-bedrock"' \
    > "$HOME/.claude-billing.conf"

  output=$(claude_billing status --json)

  assert_eq "eaix-bedrock" "$(printf '%s' "$output" | jq -r '.bedrockProfile')" \
    "an explicitly configured profile should be named outside Bedrock mode" || return 1
  assert_eq "config" "$(printf '%s' "$output" | jq -r '.bedrockProfileSource')" \
    "the profile source should say where it came from" || return 1

  # Inherit mode is not deterministic, so no profile is claimed.
  printf '%s\n' 'CLAUDE_BILLING_AWS_PROFILE_MODE="inherit"' 'CLAUDE_BILLING_AWS_PROFILE=""' \
    > "$HOME/.claude-billing.conf"
  output=$(claude_billing status --json)

  assert_eq "null" "$(printf '%s' "$output" | jq -r '.bedrockProfile')" \
    "an inherited profile should not be named" || return 1
  assert_eq "inherited" "$(printf '%s' "$output" | jq -r '.bedrockProfileSource')" \
    "inherit mode should be reported as inherited"
)

json_status_exposes_the_desktop_account() (
  HOME="$TEST_ROOT/json-status-desktop"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"

  mkdir -p "$HOME/.claude" "$HOME/Library/Application Support/Claude"
  printf '%s' '{"env":{}}' > "$HOME/.claude/settings.json"
  _cb_accounts_write "work personal" "work"
  _cb_desktop_owner_set "personal"

  output=$(claude_billing status --json)

  assert_eq "true" "$(printf '%s' "$output" | jq -r '.desktop.available')" \
    "JSON status should report Claude Desktop availability" || return 1
  assert_eq "personal" "$(printf '%s' "$output" | jq -r '.desktop.account')" \
    "JSON status should expose the independent Claude Desktop account"
)

menubar_installer_creates_an_app_and_launch_agent() (
  home="$TEST_ROOT/menubar-installer"
  bin="$home/bin"
  app="$home/Applications/Claude Billing.app"
  agent="$home/Library/LaunchAgents/com.hschin.claude-billing-menubar.plist"
  mkdir -p "$bin" "$home/.claude-billing"
  printf '%s\n' '# installed test fixture' > "$home/.claude-billing/claude_billing.sh"

  printf '%s\n' '#!/bin/sh' 'printf Darwin' > "$bin/uname"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'output=""'
    printf '%s\n' 'while [ "$#" -gt 0 ]; do'
    printf '%s\n' '  if [ "$1" = "-o" ]; then shift; output=$1; fi'
    printf '%s\n' '  shift'
    printf '%s\n' 'done'
    printf '%s\n' 'printf "#!/bin/sh\\n" > "$output"'
    printf '%s\n' 'chmod +x "$output"'
  } > "$bin/swiftc"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$bin/launchctl"
  chmod +x "$bin/uname" "$bin/swiftc" "$bin/launchctl"

  HOME="$home" PATH="$bin:$PATH" bash "$REPO_DIR/platform/macos/install-menubar.sh" >/dev/null 2>&1
  rc=$?

  assert_eq "0" "$rc" "menu bar installation should succeed" || return 1
  [ -x "$app/Contents/MacOS/ClaudeBillingMenuBar" ] || {
    printf '    menu bar executable was not installed\n' >&2
    return 1
  }
  [ -f "$agent" ] || {
    printf '    launch agent was not installed\n' >&2
    return 1
  }
  grep -q '<key>LSUIElement</key>' "$app/Contents/Info.plist" || {
    printf '    app is not configured as a menu-bar-only application\n' >&2
    return 1
  }
)

uninstall_removes_the_menu_bar_app() (
  HOME="$TEST_ROOT/uninstall-menubar"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  launchctl() { return 0; }

  app="$HOME/Applications/Claude Billing.app"
  agent="$HOME/Library/LaunchAgents/com.hschin.claude-billing-menubar.plist"
  mkdir -p "$app/Contents/MacOS" "$(dirname "$agent")"
  printf '%s' app > "$app/Contents/MacOS/ClaudeBillingMenuBar"
  printf '%s' agent > "$agent"
  responses="$HOME/responses"
  printf 'y\nn\nn\n' > "$responses"
  exec 3< "$responses"
  # shellcheck disable=SC2162  # callers pass -r through "$@"
  _cb_read() { read "$@" <&3; }

  claude_billing uninstall >/dev/null 2>&1
  rc=$?
  exec 3<&-

  assert_eq "0" "$rc" "uninstall should succeed" || return 1
  [ ! -e "$app" ] || {
    printf '    menu bar app was not removed\n' >&2
    return 1
  }
  [ ! -e "$agent" ] || {
    printf '    menu bar launch agent was not removed\n' >&2
    return 1
  }
)

menubar_install_command_runs_the_installed_helper() (
  HOME="$TEST_ROOT/menubar-command-install"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="macos"

  mkdir -p "$HOME/.claude-billing"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf install > "$HOME/menubar-command"'
  } > "$HOME/.claude-billing/install-menubar.sh"

  claude_billing menubar install >/dev/null 2>&1
  rc=$?

  assert_eq "0" "$rc" "menu bar install command should succeed" || return 1
  assert_eq "install" "$(cat "$HOME/menubar-command" 2>/dev/null)" \
    "menu bar install command should run the installed helper"
)

menubar_uninstall_command_passes_the_uninstall_flag() (
  HOME="$TEST_ROOT/menubar-command-uninstall"
  export HOME
  # shellcheck source=../claude_billing.sh
  . "$SCRIPT"
  _CB_PLATFORM="macos"

  mkdir -p "$HOME/.claude-billing"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "%s" "$1" > "$HOME/menubar-command"'
  } > "$HOME/.claude-billing/install-menubar.sh"

  claude_billing menubar uninstall >/dev/null 2>&1
  rc=$?

  assert_eq "0" "$rc" "menu bar uninstall command should succeed" || return 1
  assert_eq "--uninstall" "$(cat "$HOME/menubar-command" 2>/dev/null)" \
    "menu bar uninstall command should pass the standalone uninstall flag"
)

installer_downloads_the_menubar_helper_on_macos() (
  home="$TEST_ROOT/installer-menubar-helper"
  bin="$home/bin"
  mkdir -p "$bin"

  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'out=""'
    printf '%s\n' 'url=""'
    printf '%s\n' 'while [ "$#" -gt 0 ]; do'
    printf '%s\n' '  if [ "$1" = "-o" ]; then shift; out=$1; else url=$1; fi'
    printf '%s\n' '  shift'
    printf '%s\n' 'done'
    printf '%s\n' 'case "$url" in'
    printf '  */claude_billing.sh) cp %s/claude_billing.sh "$out"; printf '\''\\n_cb_read() { read "$@"; }\\n'\'' >> "$out" ;;\n' "$REPO_DIR"
    printf '  */platform/macos/install-menubar.sh) cp %s/platform/macos/install-menubar.sh "$out" ;;\n' "$REPO_DIR"
    printf '%s\n' '  *) exit 22 ;;'
    printf '%s\n' 'esac'
  } > "$bin/curl"
  printf '%s\n' '#!/bin/sh' 'printf Darwin' > "$bin/uname"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$bin/security"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$bin/claude"
  chmod +x "$bin/curl" "$bin/uname" "$bin/security" "$bin/claude"

  printf 'n\nn\nn\n' | HOME="$home" SHELL=/bin/bash PATH="$bin:$PATH" \
    bash "$REPO_DIR/install.sh" > "$home/install-output" 2>&1
  rc=$?

  if ! assert_eq "0" "$rc" "macOS installation should succeed"; then
    sed 's/^/    /' "$home/install-output" >&2
    return 1
  fi
  [ -x "$home/.claude-billing/install-menubar.sh" ] || {
    printf '    menu bar helper was not installed\n' >&2
    return 1
  }
)

run_test "failed desktop restore preserves live and stashed sessions" \
  desktop_restore_failure_preserves_both_sessions
run_test "desktop backup replaces a stale logged-in session" \
  desktop_backup_replaces_a_stale_logged_in_session
run_test "desktop switch relaunches a running app" \
  desktop_switch_relaunches_a_running_app
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
run_test "remove-account --yes skips the active account prompt" \
  remove_account_yes_skips_the_active_account_prompt
run_test "uninstall reports failed secret deletion" \
  uninstall_reports_failed_secret_deletion
run_test "Bedrock explicit profile is shown in the mode indicator" \
  bedrock_explicit_profile_is_shown_in_the_mode_indicator
run_test "status resync uses the inherited Bedrock profile" \
  status_resync_uses_the_inherited_bedrock_profile
run_test "JSON status exposes menu bar state" \
  json_status_exposes_menu_bar_state
run_test "usage reports limits for each account" \
  usage_reports_limits_for_each_account
run_test "usage reports the prepaid credit balance" \
  usage_reports_the_prepaid_credit_balance
run_test "usage survives a credits endpoint failure" \
  usage_survives_a_credits_endpoint_failure
run_test "usage skips credits without an account identity" \
  usage_skips_credits_without_an_account_identity
run_test "usage serves fresh entries from cache" \
  usage_serves_fresh_entries_from_cache
run_test "usage keeps the last good figures when a fetch fails" \
  usage_keeps_the_last_good_figures_when_a_fetch_fails
run_test "usage reports a missing login without calling the API" \
  usage_reports_a_missing_login_without_calling_the_api
run_test "AWS SSO status reports expiry for each session" \
  sso_status_reports_expiry_for_each_session
run_test "AWS SSO status ignores a token orphaned by a session rename" \
  sso_status_ignores_a_token_orphaned_by_a_session_rename
run_test "AWS SSO status matches legacy profile tokens by start URL" \
  sso_status_matches_legacy_profile_tokens_by_start_url
run_test "AWS SSO status reports a missing token as signed out" \
  sso_status_reports_a_missing_token_as_signed_out
run_test "AWS SSO status is empty without an AWS config" \
  sso_status_is_empty_without_aws_config
run_test "sso-login selects the matching AWS CLI flag" \
  sso_login_selects_the_matching_aws_flag
run_test "JSON status exposes AWS SSO sessions" \
  json_status_exposes_sso_sessions
run_test "JSON status reports SSO sessions outside Bedrock mode" \
  json_status_omits_sso_when_billing_is_not_bedrock
run_test "JSON status names the profile Bedrock would use" \
  json_status_names_the_profile_bedrock_would_use
run_test "JSON status exposes the Claude Desktop account" \
  json_status_exposes_the_desktop_account
run_test "menu bar installer creates an app and launch agent" \
  menubar_installer_creates_an_app_and_launch_agent
run_test "uninstall removes the menu bar app" \
  uninstall_removes_the_menu_bar_app
run_test "menu bar install command runs the installed helper" \
  menubar_install_command_runs_the_installed_helper
run_test "menu bar uninstall command passes the uninstall flag" \
  menubar_uninstall_command_passes_the_uninstall_flag
run_test "installer downloads the menu bar helper on macOS" \
  installer_downloads_the_menubar_helper_on_macos

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all tests passed\n'
