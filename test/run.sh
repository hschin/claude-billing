#!/usr/bin/env sh
# shellcheck disable=SC1091,SC2329

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

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all tests passed\n'
