# shellcheck shell=bash
# claude-billing: switch Claude Code between billing modes (subscription, API, Bedrock)
_CB_VERSION="1.5.0"
# Config: ~/.claude-billing.conf
# Accounts: ~/.claude-billing-accounts (named claude.ai subscription logins)
# Requires: jq, aws CLI (for Bedrock)
# macOS: uses Keychain (security CLI)
# Linux: uses GNOME Keyring (secret-tool)
# Windows (Git Bash): uses ~/.claude-billing-credentials (chmod 600)

# --- Helpers ---

_cb_conf_get() {
  local conf="$1" key="$2" line val
  while IFS= read -r line; do
    if [[ "$line" == "${key}="* ]]; then
      val="${line#"${key}"=}"
      val="${val#\"}"
      val="${val%\"}"
      printf '%s' "$val"
      return
    fi
  done < "$conf"
}

# shellcheck disable=SC2162  # callers always pass -r via $@
_cb_read() {
  if [ -r /dev/tty ]; then
    read "$@" </dev/tty
  else
    read "$@"
  fi
}

# Cache platform detection — avoids a subshell + uname on every credential op
_CB_PLATFORM=""
_cb_platform() {
  if [[ -z "$_CB_PLATFORM" ]]; then
    case "$(uname -s)" in
      Darwin)               _CB_PLATFORM="macos" ;;
      Linux)                _CB_PLATFORM="linux" ;;
      MINGW*|MSYS*|CYGWIN*) _CB_PLATFORM="windows" ;;
      *)                    _CB_PLATFORM="unknown" ;;
    esac
  fi
  echo "$_CB_PLATFORM"
}

_cb_require_cmd() {
  local cmd="$1" msg="$2"
  command -v "$cmd" &>/dev/null || { echo "claude-billing: '$cmd' not found in PATH — $msg" >&2; return 1; }
}

# --- Credential storage abstraction ---

_cb_cred_store() {
  local service="$1" value="$2"
  case "$(_cb_platform)" in
    macos)
      # Note: -w passes the value as a CLI arg (visible in ps briefly);
      # the macOS security CLI has no stdin option for add-generic-password.
      security add-generic-password -s "$service" -a "$USER" -w "$value" 2>/dev/null || \
        security add-generic-password -U -s "$service" -a "$USER" -w "$value" 2>/dev/null
      ;;
    linux)
      printf '%s' "$value" | secret-tool store --label="$service" service "$service" account "$USER" 2>/dev/null
      ;;
    windows)
      _cb_cred_file_store "$service" "$value"
      ;;
  esac
}

_cb_cred_retrieve() {
  local service="$1"
  case "$(_cb_platform)" in
    macos)
      security find-generic-password -s "$service" -a "$USER" -w 2>/dev/null
      ;;
    linux)
      secret-tool lookup service "$service" account "$USER" 2>/dev/null
      ;;
    windows)
      _cb_cred_file_retrieve "$service"
      ;;
  esac
}

_cb_cred_delete() {
  local service="$1" rc
  case "$(_cb_platform)" in
    macos)
      if security delete-generic-password -s "$service" -a "$USER" 2>/dev/null; then
        return 0
      else
        rc=$?
        # security returns 44 when no matching item exists.
        [[ "$rc" -eq 44 ]]
      fi
      ;;
    linux)
      secret-tool clear service "$service" account "$USER" 2>/dev/null
      ;;
    windows)
      _cb_cred_file_delete "$service"
      ;;
    *)
      return 1
      ;;
  esac
}

# Windows: permission-restricted credential file fallback
_cb_cred_file_store() {
  local service="$1" value="$2"
  local cred_file="$HOME/.claude-billing-credentials"
  touch "$cred_file" && chmod 600 "$cred_file" || return 1
  local tmp
  tmp=$(mktemp "${cred_file}.XXXXXX") && chmod 600 "$tmp" || return 1
  if { awk -v svc="$service" 'substr($0,1,length(svc)+1) != svc "="' "$cred_file" 2>/dev/null || true
       printf '%s=%s\n' "$service" "$value"
     } > "$tmp" && mv "$tmp" "$cred_file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_cb_cred_file_retrieve() {
  local service="$1"
  local cred_file="$HOME/.claude-billing-credentials"
  awk -v svc="$service" \
    'substr($0,1,length(svc)+1) == svc "=" { print substr($0,length(svc)+2) }' \
    "$cred_file" 2>/dev/null
}

_cb_cred_file_delete() {
  local service="$1"
  local cred_file="$HOME/.claude-billing-credentials"
  [[ -f "$cred_file" ]] || return 0
  local tmp
  tmp=$(mktemp "${cred_file}.XXXXXX") && chmod 600 "$tmp" || return 1
  if awk -v svc="$service" 'substr($0,1,length(svc)+1) != svc "="' "$cred_file" > "$tmp" && \
     mv "$tmp" "$cred_file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- Subscription account registry ---
# Named claude.ai logins are stored in the credential store as
# "Claude Code-credentials-acct-<name>". The registry file tracks which names
# exist and which one owns the live "Claude Code-credentials" token. Slots for
# inactive accounts hold their stashed tokens; the active account's token is
# always the live one.

_cb_acct_service() {
  printf 'Claude Code-credentials-acct-%s' "$1"
}

# Claude Code also records the logged-in account's identity (account UUID,
# org UUID, subscription type) in ~/.claude.json under .oauthAccount. If that
# doesn't match the live OAuth token, Claude Code forces a re-login — so each
# account's metadata is stashed alongside its token and swapped on restore.
_cb_acct_meta_service() {
  printf 'Claude Code-oauthAccount-acct-%s' "$1"
}

_cb_acct_meta_backup() {
  local name="$1" meta
  meta=$(jq -c '.oauthAccount // empty' "$HOME/.claude.json" 2>/dev/null)
  [[ -z "$meta" ]] && return 0
  _cb_cred_store "$(_cb_acct_meta_service "$name")" "$meta" || \
    echo "claude-billing: warning: failed to stash account metadata for '$name'" >&2
}

_cb_acct_meta_restore() {
  local name="$1" meta
  meta=$(_cb_cred_retrieve "$(_cb_acct_meta_service "$name")")
  [[ -z "$meta" ]] && return 0
  [[ -f "$HOME/.claude.json" ]] || return 0
  # Only delete the stored copy after it has been written into ~/.claude.json
  if OAUTH_META="$meta" _cb_settings_update "$HOME/.claude.json" \
       '.oauthAccount = (env.OAUTH_META | fromjson)'; then
    _cb_cred_delete "$(_cb_acct_meta_service "$name")"
  else
    echo "claude-billing: warning: failed to apply account metadata for '$name' — Claude Code may prompt for login" >&2
  fi
}

_cb_accounts_list() {
  local f="$HOME/.claude-billing-accounts"
  [[ -f "$f" ]] && _cb_conf_get "$f" CLAUDE_BILLING_ACCOUNTS
  return 0
}

_cb_active_get() {
  local f="$HOME/.claude-billing-accounts"
  [[ -f "$f" ]] && _cb_conf_get "$f" CLAUDE_BILLING_ACTIVE
  return 0
}

_cb_accounts_write() {
  printf 'CLAUDE_BILLING_ACCOUNTS="%s"\nCLAUDE_BILLING_ACTIVE="%s"\n' "$1" "$2" \
    > "$HOME/.claude-billing-accounts"
}

_cb_active_set() {
  _cb_accounts_write "$(_cb_accounts_list)" "$1"
}

_cb_account_registered() {
  local name="$1" a
  for a in $(_cb_accounts_list); do
    [[ "$a" == "$name" ]] && return 0
  done
  return 1
}

_cb_account_register() {
  local list
  list=$(_cb_accounts_list)
  _cb_accounts_write "${list:+$list }$1" "$(_cb_active_get)"
}

_cb_account_unregister() {
  local name="$1" a list="" active
  for a in $(_cb_accounts_list); do
    [[ "$a" == "$name" ]] || list="${list:+$list }$a"
  done
  active=$(_cb_active_get)
  [[ "$active" == "$name" ]] && active=""
  _cb_accounts_write "$list" "$active"
}

# --- Billing mode state (for shell prompts) ---
# Each switch records the resulting mode ("sub", "sub:<account>", "api",
# "bedrock") in ~/.claude-billing-mode so prompts can show it without parsing
# settings.json. `claude-billing status` rewrites it from settings.json, which
# stays the source of truth.

_cb_mode_set() {
  printf '%s\n' "$1" > "$HOME/.claude-billing-mode"
}

# Print the current billing mode for embedding in a shell prompt (e.g. a
# Starship custom module or zsh precmd). Prints nothing until the first
# switch; run `claude-billing status` to seed or resync the state file.
claude_billing_prompt() {
  local mode="" f="$HOME/.claude-billing-mode"
  [[ -f "$f" ]] || return 0
  IFS= read -r mode < "$f" || true
  printf '%s' "$mode"
}

_cb_settings_update() {
  local settings="$1" filter="$2"
  shift 2
  _cb_require_cmd jq "install with: brew install jq / apt install jq / winget install jqlang.jq" || return 1
  cp "$settings" "${settings}.bak" 2>/dev/null || true
  local tmp
  tmp=$(mktemp "${settings}.XXXXXX")
  if jq "$@" "$filter" "$settings" > "$tmp" && mv "$tmp" "$settings"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_cb_settings_rollback() {
  local settings="$1"
  if [[ -f "${settings}.bak" ]] && cp "${settings}.bak" "$settings"; then
    return 0
  fi
  echo "claude-billing: warning: failed to restore ${settings}.bak" >&2
  return 1
}

# --- OAuth backup / restore ---

# Stash the live token into the active account's slot, or the legacy backup
# slot when no account owns it.
_claude_billing_backup_oauth() {
  local oauth active dest
  oauth=$(_cb_cred_retrieve "Claude Code-credentials")
  [[ -z "$oauth" ]] && return 0
  active=$(_cb_active_get)
  if [[ -n "$active" ]]; then
    dest=$(_cb_acct_service "$active")
  else
    dest="Claude Code-credentials-backup"
  fi
  # Only delete the live token after confirming the backup was written
  if _cb_cred_store "$dest" "$oauth"; then
    [[ -n "$active" ]] && _cb_acct_meta_backup "$active"
    _cb_cred_delete "Claude Code-credentials"
    if [[ -n "$active" ]]; then
      _cb_active_set ""
    fi
  else
    echo "claude-billing: failed to write OAuth backup — not removing live token" >&2
    return 1
  fi
}

_claude_billing_restore_oauth() {
  local backup
  backup=$(_cb_cred_retrieve "Claude Code-credentials-backup")
  if [[ -n "$backup" ]]; then
    # Only delete the backup after confirming the live token was restored
    if _cb_cred_store "Claude Code-credentials" "$backup"; then
      _cb_cred_delete "Claude Code-credentials-backup"
      echo "Restored claude.ai OAuth token"
    else
      echo "claude-billing: failed to restore OAuth token — backup preserved" >&2
      return 1
    fi
  else
    echo "No OAuth backup found — launching login..."
    _claude_billing_login
  fi
}

_claude_billing_restore_account() {
  local name="$1" backup
  backup=$(_cb_cred_retrieve "$(_cb_acct_service "$name")")
  if [[ -n "$backup" ]]; then
    # Only delete the stored copy after confirming the live token was restored
    if _cb_cred_store "Claude Code-credentials" "$backup"; then
      _cb_cred_delete "$(_cb_acct_service "$name")"
      _cb_active_set "$name"
      _cb_acct_meta_restore "$name"
      echo "Restored claude.ai OAuth token for account '$name'"
    else
      echo "claude-billing: failed to restore OAuth token for '$name' — stored copy preserved" >&2
      return 1
    fi
  elif [[ "$(_cb_active_get)" == "$name" && -n "$(_cb_cred_retrieve "Claude Code-credentials")" ]]; then
    echo "Already logged in as '$name'"
  else
    echo "No stored token for '$name' — launching login..."
    _claude_billing_login && _cb_active_set "$name"
  fi
}

# --- Desktop app (Claude.app) login switching ---
# The claude.ai desktop app keeps its login as Electron profile cookies
# (values encrypted with the per-machine "Claude Safe Storage" keychain key,
# so cookie files can be swapped between accounts on the same machine) plus
# OAuth token caches in its config.json. Swapping both moves the login.
# Stashes live in ~/.claude-billing/desktop/<name>/ (chmod 700/600); the
# sensitive values inside are already encrypted by Claude Safe Storage.
# .active in the stash root tracks which account owns the live desktop login —
# fully independent of CLAUDE_BILLING_ACTIVE: the desktop app only ever uses a
# claude.ai subscription login (no API/Bedrock mode), so it is switched only
# by the explicit `claude-billing desktop <name>` command, never as a side
# effect of a CLI billing switch.

_cb_desktop_app_dir() {
  printf '%s/Library/Application Support/Claude' "$HOME"
}

_cb_desktop_stash_root() {
  printf '%s/.claude-billing/desktop' "$HOME"
}

_cb_desktop_available() {
  [[ -d "$(_cb_desktop_app_dir)" ]]
}

_cb_desktop_owner_get() {
  cat "$(_cb_desktop_stash_root)/.active" 2>/dev/null
  return 0
}

_cb_desktop_owner_set() {
  mkdir -p "$(_cb_desktop_stash_root)" && chmod 700 "$(_cb_desktop_stash_root)" || return 1
  printf '%s\n' "$1" > "$(_cb_desktop_stash_root)/.active"
}

# Chromium rewrites the cookie DB on exit, so swapping while the app runs
# would be lost or corrupted — the app must quit first.
_cb_desktop_quit() {
  pgrep -xq Claude || return 0
  local confirm="" i=0
  printf "Claude.app must quit to switch its login. Quit it now? [Y/n]: "
  _cb_read -r confirm
  [[ "$confirm" =~ ^[Nn]$ ]] && return 1
  osascript -e 'quit app "Claude"' 2>/dev/null
  while pgrep -xq Claude; do
    i=$((i+1))
    if [[ "$i" -gt 20 ]]; then
      echo "claude-billing: Claude.app did not quit" >&2
      return 1
    fi
    sleep 0.5
  done
  return 0
}

_cb_desktop_launch() {
  if ! open -b com.anthropic.claudefordesktop >/dev/null 2>&1; then
    echo "claude-billing: account switched, but Claude.app could not be reopened" >&2
    return 1
  fi
}

# Copy the live desktop login into <name>'s stash. Copies are verified before
# being trusted; live files are never removed here.
_cb_desktop_backup() {
  local name="$1" app root dir stage old=""
  app=$(_cb_desktop_app_dir)
  root=$(_cb_desktop_stash_root)
  dir="$root/$name"
  mkdir -p "$root" && chmod 700 "$root" || return 1
  stage=$(mktemp -d "$root/.${name}.new.XXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf "$stage"; return 1; }
  if [[ -f "$app/Cookies" ]]; then
    if ! { cp "$app/Cookies" "$stage/Cookies" && cmp -s "$app/Cookies" "$stage/Cookies" && \
           chmod 600 "$stage/Cookies"; }; then
      rm -rf "$stage"
      return 1
    fi
  fi
  if [[ -f "$app/config.json" ]]; then
    if ! jq -c '{
         "oauth:tokenCache": .["oauth:tokenCache"],
         "oauth:tokenCacheV2": .["oauth:tokenCacheV2"],
         "lastKnownAccountUuid": .lastKnownAccountUuid
       } | with_entries(select(.value != null))' \
       "$app/config.json" > "$stage/config-oauth.json" 2>/dev/null || \
       ! chmod 600 "$stage/config-oauth.json"; then
      rm -rf "$stage"
      return 1
    fi
  fi

  # Rotate the complete directory only after every artifact is ready. An empty
  # stage deliberately replaces a stale logged-in stash after the user logs out.
  if [[ -e "$dir" ]]; then
    old="${stage}.old"
    mv "$dir" "$old" || { rm -rf "$stage"; return 1; }
  fi
  if ! mv "$stage" "$dir"; then
    [[ -n "$old" ]] && mv "$old" "$dir"
    rm -rf "$stage"
    return 1
  fi
  [[ -n "$old" ]] && rm -rf "$old"
  return 0
}

# Restore <name>'s stashed desktop login, or clear the live login when nothing
# is stashed (mirrors the CLI "launching login" path). Stale Cookies-journal is
# always removed so it can't replay against a swapped DB.
_cb_desktop_restore() {
  local name="$1" app dir cookie_tmp="" config_tmp="" cookie_rollback="" had_live_cookie=0
  app=$(_cb_desktop_app_dir)
  dir="$(_cb_desktop_stash_root)/$name"
  if [[ -f "$dir/Cookies" ]]; then
    cookie_tmp=$(mktemp "$app/.Cookies.new.XXXXXX") || return 1
    if ! { cp "$dir/Cookies" "$cookie_tmp" && cmp -s "$dir/Cookies" "$cookie_tmp" && \
           chmod 600 "$cookie_tmp"; }; then
      rm -f "$cookie_tmp"
      return 1
    fi

    # Prepare the metadata update before touching the live cookie DB. This
    # keeps a corrupt or unreadable stash from producing a partial login swap.
    if [[ -s "$dir/config-oauth.json" ]]; then
      config_tmp=$(mktemp "$app/.config.json.new.XXXXXX") || { rm -f "$cookie_tmp"; return 1; }
      # shellcheck disable=SC2016  # $meta is a jq variable, not shell
      if [[ -f "$app/config.json" ]]; then
        if ! jq --slurpfile meta "$dir/config-oauth.json" '. + $meta[0]' \
             "$app/config.json" > "$config_tmp" 2>/dev/null; then
          rm -f "$cookie_tmp" "$config_tmp"
          return 1
        fi
      else
        if ! jq -n --slurpfile meta "$dir/config-oauth.json" '$meta[0]' \
             > "$config_tmp" 2>/dev/null; then
          rm -f "$cookie_tmp" "$config_tmp"
          return 1
        fi
      fi
      if ! chmod 600 "$config_tmp"; then
        rm -f "$cookie_tmp" "$config_tmp"
        return 1
      fi
    fi

    # Keep a rollback copy until every prepared artifact is committed.
    if [[ -f "$app/Cookies" ]]; then
      had_live_cookie=1
      cookie_rollback=$(mktemp "$app/.Cookies.rollback.XXXXXX") || {
        rm -f "$cookie_tmp" "$config_tmp"
        return 1
      }
      cp "$app/Cookies" "$cookie_rollback" || {
        rm -f "$cookie_tmp" "$config_tmp" "$cookie_rollback"
        return 1
      }
    fi
    if ! mv "$cookie_tmp" "$app/Cookies"; then
      rm -f "$cookie_tmp" "$config_tmp" "$cookie_rollback"
      return 1
    fi
    if [[ -n "$config_tmp" ]]; then
      cp "$app/config.json" "$app/config.json.bak" 2>/dev/null || true
      if ! mv "$config_tmp" "$app/config.json"; then
        if [[ "$had_live_cookie" -eq 1 ]]; then
          mv "$cookie_rollback" "$app/Cookies"
        else
          rm -f "$app/Cookies"
        fi
        rm -f "$config_tmp" "$cookie_rollback"
        return 1
      fi
    fi
    rm -f "$cookie_rollback" "$app/Cookies-journal"
    rm -f "$dir/Cookies" "$dir/config-oauth.json"
    echo "Desktop app: restored Claude.app login for '$name'"
  else
    if [[ -f "$app/config.json" ]]; then
      config_tmp=$(mktemp "$app/.config.json.new.XXXXXX") || return 1
      if ! jq 'del(.["oauth:tokenCache"], .["oauth:tokenCacheV2"], .lastKnownAccountUuid)' \
           "$app/config.json" > "$config_tmp" || ! chmod 600 "$config_tmp"; then
        rm -f "$config_tmp"
        return 1
      fi
      cp "$app/config.json" "$app/config.json.bak" 2>/dev/null || true
      mv "$config_tmp" "$app/config.json" || { rm -f "$config_tmp"; return 1; }
    fi
    rm -f "$app/Cookies" "$app/Cookies-journal"
    echo "Desktop app: no saved login for '$name' — sign in when you next open Claude.app"
  fi
  return 0
}

# Move the desktop app login to <acct>. prev seeds ownership the first time,
# before the .active marker exists (the `desktop` command asks the user whose
# login it is). Swap failures leave the tracked owner unchanged. Relaunch is
# best-effort after a successful swap because ownership has already committed.
_cb_desktop_switch() {
  local acct="$1" prev="$2" owner was_running=0
  _cb_desktop_available || return 0
  owner=$(_cb_desktop_owner_get)
  [[ -z "$owner" ]] && owner="$prev"
  [[ "$owner" == "$acct" ]] && return 0
  pgrep -xq Claude && was_running=1
  if ! _cb_desktop_quit; then
    echo "Desktop app: Claude.app login left unchanged"
    return 0
  fi
  if [[ -n "$owner" ]]; then
    if ! _cb_desktop_backup "$owner"; then
      echo "claude-billing: failed to stash desktop login for '$owner' — Claude.app left unchanged" >&2
      return 0
    fi
  elif [[ -f "$(_cb_desktop_app_dir)/Cookies" ]]; then
    # Can't tell whose login this is — keep a safety copy before replacing it.
    # Dot-prefixed so it can never collide with a real account name.
    _cb_desktop_backup ".unclaimed" || return 0
    echo "claude-billing: couldn't tell which account owned the desktop login — copy kept in $(_cb_desktop_stash_root)/.unclaimed" >&2
  fi
  if _cb_desktop_restore "$acct"; then
    _cb_desktop_owner_set "$acct" || return 1
    if [[ "$was_running" -eq 1 ]]; then
      _cb_desktop_launch || true
    fi
  else
    echo "claude-billing: failed to restore desktop login for '$acct' — stash preserved" >&2
  fi
  return 0
}

# --- AWS SSO session expiry ---
# Bedrock mode authenticates through an AWS profile, and SSO profiles stop
# working the moment their cached access token expires. The AWS CLI records
# every token in ~/.aws/sso/cache/<sha1>.json with an `expiresAt` timestamp, so
# expiry can be reported without any network call. Read-only: claude-billing
# never writes to the cache, and `sso-login` just delegates to the AWS CLI.

# Seam for tests: current epoch seconds.
_cb_now() {
  if [[ -n "${CLAUDE_BILLING_TEST_NOW:-}" ]]; then
    printf '%s' "$CLAUDE_BILLING_TEST_NOW"
  else
    date +%s
  fi
}

# Emit the SSO logins declared in ~/.aws/config as tab-separated rows:
#   S<TAB><session name><TAB><start url>   an [sso-session <name>] block
#   L<TAB><profile name><TAB><start url>   a legacy profile with sso_start_url
#   P<TAB><profile name><TAB><session>     a profile that uses <session>
_cb_sso_config_rows() {
  local config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  [[ -f "$config" ]] || return 0
  awk '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    function flush() {
      if (kind == "sso-session") {
        if (start_url != "") printf "S\t%s\t%s\n", name, start_url
      } else if (kind == "profile") {
        if (session != "") printf "P\t%s\t%s\n", name, session
        else if (start_url != "") {
          printf "L\t%s\t%s\n", name, start_url
          printf "P\t%s\t%s\n", name, name
        }
      }
    }
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[/ {
      flush()
      header = $0
      sub(/^[ \t]*\[/, "", header)
      sub(/\].*$/, "", header)
      header = trim(header)
      kind = ""; name = ""; start_url = ""; session = ""
      if (header ~ /^sso-session[ \t]/) {
        kind = "sso-session"; name = header; sub(/^sso-session[ \t]+/, "", name)
      } else if (header ~ /^profile[ \t]/) {
        kind = "profile"; name = header; sub(/^profile[ \t]+/, "", name)
      } else if (header == "default") {
        kind = "profile"; name = "default"
      }
      next
    }
    /=/ {
      key = trim(substr($0, 1, index($0, "=") - 1))
      val = trim(substr($0, index($0, "=") + 1))
      if (key == "sso_start_url") start_url = val
      else if (key == "sso_session") session = val
    }
    END { flush() }
  ' "$config"
}

# The AWS CLI names each token cache file after the SHA-1 of its lookup key:
# the sso-session name for session-style logins, the start URL for legacy
# profiles. Matching on that key (not just the start URL) is what makes expiry
# agree with the AWS CLI — renaming a session orphans its old token, and only
# the key reveals that. Prints nothing when no SHA-1 tool is available.
_cb_sha1() {
  if command -v shasum &>/dev/null; then
    printf '%s' "$1" | shasum -a 1 2>/dev/null | awk '{print $1}'
  elif command -v sha1sum &>/dev/null; then
    printf '%s' "$1" | sha1sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl &>/dev/null; then
    printf '%s' "$1" | openssl dgst -sha1 2>/dev/null | awk '{print $NF}'
  fi
}

# Collect [{key, url, expiresAt}] from the AWS CLI token cache, where key is the
# file's basename (the SHA-1 above). Only access-token files carry startUrl and
# expiresAt; role-credential and client-registration files don't.
_cb_sso_cache_json() {
  local dir="${HOME}/.aws/sso/cache" out f
  local filter='[ .[] | select(type == "object" and .startUrl != null and .expiresAt != null)
                 | {key: input_filename | split("/") | last | sub("\\.json$"; ""),
                    url: (.startUrl | sub("/+$"; "")), expiresAt: .expiresAt} ]'
  [[ -d "$dir" ]] || { printf '[]'; return 0; }
  if out=$(jq -s -c "$filter" "$dir"/*.json 2>/dev/null) && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  # One unreadable or malformed file must not hide every other session.
  out=""
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    out="${out}$(jq -c "[.] | $filter" "$f" 2>/dev/null || printf '[]')"
  done
  printf '%s' "$out" | jq -s -c 'add // []' 2>/dev/null || printf '[]'
}

# Append the expected cache key to each declared-login row, so the join can
# prefer the exact file the AWS CLI would read.
_cb_sso_rows_with_keys() {
  local line kind name value
  while IFS=$'\t' read -r kind name value; do
    case "$kind" in
      S) printf 'S\t%s\t%s\t%s\n' "$name" "$value" "$(_cb_sha1 "$name")" ;;
      L) printf 'L\t%s\t%s\t%s\n' "$name" "$value" "$(_cb_sha1 "$value")" ;;
      *) printf '%s\t%s\t%s\t\n' "$kind" "$name" "$value" ;;
    esac
  done
}

# Build the SSO status array. $1 is the AWS profile Claude Code currently uses
# (may be empty), so the caller's session can be flagged in the output.
_cb_sso_status_json() {
  local active_profile="${1:-}" rows cache_json
  rows=$(_cb_sso_config_rows 2>/dev/null) || rows=""
  if [[ -z "$rows" ]]; then
    printf '[]'
    return 0
  fi
  rows=$(printf '%s\n' "$rows" | _cb_sso_rows_with_keys)
  cache_json=$(_cb_sso_cache_json)
  [[ -n "$cache_json" ]] || cache_json='[]'
  # Sessions are grouped by start URL: one login serves every profile pointing
  # at it, and an [sso-session] name is preferred over a legacy profile name.
  # Expiry comes from the cache file the AWS CLI itself would read (matched on
  # the SHA-1 key), falling back to the start URL when no SHA-1 tool exists.
  jq -n -c \
    --arg rows "$rows" \
    --argjson cache "$cache_json" \
    --argjson now "$(_cb_now)" \
    --arg active_profile "$active_profile" '
    ($rows | split("\n") | map(select(length > 0) | split("\t"))) as $r
    | ($r | map(select(.[0] == "P")) | map({profile: .[1], session: .[2]})) as $links
    | ($r | map(select(.[0] == "S" or .[0] == "L"))
          | map({kind: (if .[0] == "S" then "session" else "profile" end),
                 name: .[1], url: (.[2] | sub("/+$"; "")),
                 cacheKey: (.[3] // "")})) as $declared
    | $declared
    | group_by(.url)
    | map(
        (map(select(.kind == "session")) | first) as $preferred
        | (if $preferred != null then $preferred else first end) as $self
        | (map(.name) | unique) as $names
        | ($links | map(select(.session as $s | $names | index($s)) | .profile) | unique) as $profiles
        | (if $self.cacheKey != ""
           then ($cache | map(select(.key == $self.cacheKey) | .expiresAt))
           else ($cache | map(select(.url == $self.url) | .expiresAt)) end
           | sort | last) as $expires
        | ($expires
           | if . == null then null
             else (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) end) as $epoch
        | (if $epoch == null then null else ($epoch - $now) end) as $remaining
        | {
            name: $self.name,
            kind: $self.kind,
            startUrl: $self.url,
            profiles: $profiles,
            expiresAt: $expires,
            secondsRemaining: $remaining,
            status: (if $remaining == null then "signed-out"
                     elif $remaining <= 0 then "expired"
                     elif $remaining <= 1800 then "expiring"
                     else "valid" end),
            active: ($active_profile != "" and ($profiles | index($active_profile)) != null)
          }
      )
    | sort_by(.name)'
}

_cb_sso_status_lines() {
  printf '%s' "$1" | jq -r '
    def human:
      if . == null then "unknown"
      elif . >= 86400 then "\(. / 86400 | floor)d \((. % 86400) / 3600 | floor)h"
      elif . >= 3600 then "\(. / 3600 | floor)h \((. % 3600) / 60 | floor)m"
      elif . > 0 then "\(. / 60 | floor)m"
      else "0m" end;
    .[] |
    "  \(.name)\(if .active then " (in use)" else "" end): " +
    (if .status == "signed-out" then "signed out — run: claude-billing sso-login \(.name)"
     elif .status == "expired" then "expired — run: claude-billing sso-login \(.name)"
     elif .status == "expiring" then "expires in \(.secondsRemaining | human) — refresh soon"
     else "valid for \(.secondsRemaining | human)" end)'
}

# Refresh one SSO login through the AWS CLI. Session-style logins take
# --sso-session; legacy profiles that carry their own sso_start_url take
# --profile.
_claude_billing_sso_login() {
  local name="$1" kind
  _cb_require_cmd jq "install with: brew install jq / apt install jq / winget install jqlang.jq" || return 1
  _cb_require_cmd aws "install the AWS CLI first" || return 1
  kind=$(_cb_sso_status_json "" | jq -r --arg name "$name" '.[] | select(.name == $name) | .kind' 2>/dev/null)
  if [[ -z "$kind" ]]; then
    echo "claude-billing: no AWS SSO session named '$name' in ${AWS_CONFIG_FILE:-$HOME/.aws/config}" >&2
    return 1
  fi
  if [[ "$kind" == "session" ]]; then
    aws sso login --sso-session "$name"
  else
    aws sso login --profile "$name"
  fi
}

# --- Subscription plan usage ---
# Claude Code shows plan utilization (its /usage view) by calling
# api.anthropic.com/api/oauth/usage with the subscription OAuth token. That
# endpoint is NOT a documented, versioned API: it can change or disappear
# without notice, so every field is read defensively and any failure degrades to
# "unavailable" rather than breaking a switch. Only the normalized `limits`
# array and `spend` object are consumed; the sibling code-named keys in the
# response are internal and deliberately ignored.
#
# Credentials stay read-only here. An account's stashed access token is used as
# it is; nothing refreshes, rewrites, or deletes a token to read usage, so an
# expired one reports "token expired" instead (switching to that account makes
# Claude Code refresh it). Tokens are passed to curl on stdin, never in argv,
# because process arguments are visible to other users via ps.

_CB_USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"
# Built by concatenation, not pattern substitution: zsh parses `${var//%s/x}`
# as an end-anchored replacement of "s" and silently corrupts the URL.
_CB_CREDITS_ENDPOINT_PREFIX="https://api.anthropic.com/api/oauth/organizations/"
_CB_CREDITS_ENDPOINT_SUFFIX="/prepaid/credits"
_CB_USAGE_BETA="oauth-2025-04-20"
# The usage endpoint belongs to Claude Code, and it appears to be stricter with
# clients it doesn't recognise: claude-billing's own User-Agent drew HTTP 429s
# at a five-minute cadence, where Claude Code polls the same endpoint freely.
# We read the installed CLI's own version so this stays truthful about what is
# being asked and by which client's contract, rather than inventing a version.
_CB_USAGE_UA_FALLBACK="2.1.5"
_CB_USAGE_USER_AGENT=""
_cb_usage_user_agent() {
  local version=""
  if [[ -n "$_CB_USAGE_USER_AGENT" ]]; then
    printf '%s' "$_CB_USAGE_USER_AGENT"
    return 0
  fi
  if command -v claude >/dev/null 2>&1; then
    version=$(claude --version 2>/dev/null | tr -cd '0-9.\n' | head -n 1)
  fi
  [[ -n "$version" ]] || version="$_CB_USAGE_UA_FALLBACK"
  _CB_USAGE_USER_AGENT="claude-code/$version"
  printf '%s' "$_CB_USAGE_USER_AGENT"
}

_cb_usage_cache_file() {
  printf '%s' "$HOME/.claude-billing/usage-cache.json"
}

# Print the stored credential blob for an account: the live token when the
# account is active (or when no accounts are registered), its stash otherwise.
_cb_usage_credentials() {
  local name="${1:-}" active
  active=$(_cb_active_get)
  if [[ -z "$name" || "$name" == "$active" ]]; then
    _cb_cred_retrieve "Claude Code-credentials"
    return 0
  fi
  _cb_cred_retrieve "$(_cb_acct_service "$name")"
}

# The organization UUID needed for the prepaid-credits endpoint. Claude Code
# keeps the live account's identity in ~/.claude.json; inactive accounts have
# theirs stashed alongside their token.
_cb_usage_org_uuid() {
  local name="${1:-}" active
  active=$(_cb_active_get)
  if [[ -z "$name" || "$name" == "$active" ]]; then
    jq -r '.oauthAccount.organizationUuid // empty' "$HOME/.claude.json" 2>/dev/null
    return 0
  fi
  _cb_cred_retrieve "$(_cb_acct_meta_service "$name")" | jq -r '.organizationUuid // empty' 2>/dev/null
}

# A temp file in the usual place, or nothing if one can't be made. Used for
# response headers, which are not secret; tokens never go near it.
_cb_mktemp_file() {
  mktemp "${TMPDIR:-/tmp}/claude-billing-headers.XXXXXX" 2>/dev/null
}

# One header's value from a dumped header file, lowercased name, last wins
# (redirects can dump several response blocks).
_cb_header_value() {
  local file="$1" want="$2"
  [[ -f "$file" ]] || return 0
  tr -d '\r' < "$file" \
    | awk -v want="$want" 'BEGIN{IGNORECASE=1}
        index(tolower($0), want ":") == 1 {
          value = substr($0, length(want) + 2)
          gsub(/^[ \t]+|[ \t]+$/, "", value)
        }
        END { if (value != "") print value }'
}

# How long to wait before asking again. Honours Retry-After when the server
# sends one (seconds only — the HTTP-date form is not used here), and otherwise
# picks a default for a rate limit so a 429 is never retried on the next tick.
# Clamped: a server asking us to wait a week is not something to obey blindly,
# and a one-second wait defeats the point.
_cb_retry_seconds() {
  local code="$1" retry_after="$2" seconds=0
  if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
    seconds="$retry_after"
  elif [[ "$code" == "429" ]]; then
    seconds=900
  fi
  (( seconds <= 0 )) && { printf '0'; return 0; }
  (( seconds < 60 )) && seconds=60
  (( seconds > 3600 )) && seconds=3600
  printf '%s' "$seconds"
}

# Prepaid credit balance for one account, or nothing at all. Credits are a
# separate concern from plan limits and a separate request, so a failure here
# (not every account has credits, and the endpoint may refuse) leaves the usage
# figures intact rather than failing the whole read.
_cb_credits_fetch_one() {
  local token="$1" org="$2" response http_status body url
  [[ -n "$org" ]] || return 0
  url="${_CB_CREDITS_ENDPOINT_PREFIX}${org}${_CB_CREDITS_ENDPOINT_SUFFIX}"
  response=$(printf '%s\n' \
    "header = \"Authorization: Bearer $token\"" \
    "header = \"anthropic-beta: $_CB_USAGE_BETA\"" \
    "header = \"User-Agent: $(_cb_usage_user_agent)\"" \
    "silent" "show-error" "max-time = 20" "write-out = \"\\n%{http_code}\"" \
    "url = \"$url\"" | curl --config - 2>/dev/null)
  http_status=$(printf '%s' "$response" | tail -n 1)
  body=$(printf '%s' "$response" | sed '$d')
  [[ "$http_status" == "200" && -n "$body" ]] || return 0
  # Balances are minor units with an exponent; tranches carry their own expiry,
  # and the soonest one is what a holder needs to know about.
  printf '%s' "$body" | jq -c '
    ((.balance.credits.exponent // 2) | if type == "number" then . else 2 end) as $exp
    | (.balance.credits.amount_minor // .amount) as $minor
    | select($minor != null and ($minor | type) == "number")
    | ((.tranches // []) + (.promo_tranches // [])) as $tranches
    | (.next_expires_at // ($tranches | map(.expires_at) | map(select(. != null)) | sort | first)) as $next
    | {
        balance: ($minor / pow(10; $exp)),
        currency: (.currency // "USD"),
        nextExpiresAt: $next,
        expiringAmount: ($tranches
          | map(select(.expires_at == $next and .remaining_amount_minor_units != null))
          | map(.remaining_amount_minor_units) | add
          | if . == null then null else . / pow(10; $exp) end)
      }' 2>/dev/null || return 0
}

# Fetch usage for one account. Always prints one JSON object; status is ok,
# no-token, token-expired, or unavailable.
_cb_usage_fetch_one() {
  local name="${1:-}" creds token expires_ms now_ms body http_status response
  creds=$(_cb_usage_credentials "$name")
  if [[ -z "$creds" ]]; then
    jq -n --arg account "$name" '{account: $account, status: "no-token"}'
    return 0
  fi
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  expires_ms=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)
  if [[ -z "$token" ]]; then
    jq -n --arg account "$name" '{account: $account, status: "no-token"}'
    return 0
  fi
  now_ms=$(( $(_cb_now) * 1000 ))
  if [[ -n "$expires_ms" ]] && [[ "$expires_ms" =~ ^[0-9]+$ ]] && (( expires_ms <= now_ms )); then
    jq -n --arg account "$name" '{account: $account, status: "token-expired"}'
    return 0
  fi
  # Response headers go to a file so a rate limit can report its own retry
  # delay; the body still comes back on stdout with the status appended.
  local header_file retry_after
  header_file=$(_cb_mktemp_file) || header_file=""
  # curl reads the auth header from stdin so the token never reaches argv.
  response=$(printf '%s\n' \
    "header = \"Authorization: Bearer $token\"" \
    "header = \"anthropic-beta: $_CB_USAGE_BETA\"" \
    "header = \"User-Agent: $(_cb_usage_user_agent)\"" \
    ${header_file:+"dump-header = \"$header_file\""} \
    "silent" "show-error" "max-time = 20" "write-out = \"\\n%{http_code}\"" \
    "url = \"$_CB_USAGE_ENDPOINT\"" | curl --config - 2>/dev/null)
  http_status=$(printf '%s' "$response" | tail -n 1)
  body=$(printf '%s' "$response" | sed '$d')
  retry_after=""
  if [[ -n "$header_file" ]]; then
    retry_after=$(_cb_header_value "$header_file" "retry-after")
    rm -f "$header_file" 2>/dev/null
  fi
  if [[ "$http_status" != "200" ]] || [[ -z "$body" ]]; then
    jq -n --arg account "$name" --arg code "$http_status" \
      --argjson retry "$(_cb_retry_seconds "$http_status" "$retry_after")" \
      '{account: $account, status: "unavailable",
        detail: (if $code == "" or $code == "000" then "could not reach api.anthropic.com"
                 elif $code == "429" then "rate limited by api.anthropic.com \u2014 try again shortly"
                 elif $code == "401" or $code == "403" then "api.anthropic.com rejected the login (HTTP \($code))"
                 elif ($code | startswith("5")) then "api.anthropic.com is having trouble (HTTP \($code))"
                 else "api.anthropic.com returned HTTP \($code)" end)}
       + (if $retry > 0 then {retryAfter: $retry} else {} end)'
    return 0
  fi
  local credits
  credits=$(_cb_credits_fetch_one "$token" "$(_cb_usage_org_uuid "$name")")
  [[ -n "$credits" ]] || credits="null"
  printf '%s' "$body" | jq -c --arg account "$name" --argjson fetched "$(_cb_now)" \
    --argjson credits "$credits" '
    {
      account: $account,
      status: "ok",
      fetchedAt: $fetched,
      limits: [ (.limits // [])[]
                | select(type == "object" and .percent != null)
                | {kind: (.kind // "unknown"), group: (.group // ""),
                   percent: (.percent | if type == "number" then round else 0 end),
                   severity: (.severity // "normal"),
                   resetsAt: .resets_at, isActive: (.is_active // false)} ],
      credits: $credits,
      spend: (if (.spend | type) == "object" and (.spend.enabled // false)
              then {percent: (.spend.percent // 0),
                    used: ((.spend.used.amount_minor // 0) / (pow(10; .spend.used.exponent // 2))),
                    limit: ((.spend.limit.amount_minor // 0) / (pow(10; .spend.limit.exponent // 2))),
                    currency: (.spend.used.currency // ""),
                    severity: (.spend.severity // "normal")}
              else null end)
    }' 2>/dev/null || jq -n --arg account "$name" \
      '{account: $account, status: "unavailable", detail: "unexpected response from api.anthropic.com"}'
}

# Usage for every registered account (or the single legacy login), served from
# ~/.claude-billing/usage-cache.json unless an entry is older than the TTL.
# --refresh forces a fetch. Cached entries carry ageSeconds so callers can say
# how stale a figure is.
# Whether an account's stored access token has already expired. A local,
# read-only check: it lets the menu mark figures as unreliable even for an
# account it deliberately didn't poll, without spending a request to be told.
_cb_usage_token_expired() {
  local name="${1:-}" creds expires_ms now_ms
  creds=$(_cb_usage_credentials "$name")
  [[ -n "$creds" ]] || { printf 'false'; return 0; }
  expires_ms=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)
  [[ "$expires_ms" =~ ^[0-9]+$ ]] || { printf 'false'; return 0; }
  now_ms=$(( $(_cb_now) * 1000 ))
  if (( expires_ms <= now_ms )); then printf 'true'; else printf 'false'; fi
}

# _cb_usage_json [--refresh] [only-account]
#
# `only-account` restricts NETWORK calls to that one account; the others are
# served from cache, or reported as `not-polled` if nothing is cached. The
# endpoint rate-limits (HTTP 429), and an account you are not using is not
# spending its limits, so polling it buys nothing and costs the request budget
# of the account you actually care about. Pass "-" for the legacy, account-less
# entry.
_cb_usage_json() {
  local force="${1:-}" only="${2:-}" ttl="${CLAUDE_BILLING_USAGE_TTL:-300}" cache_file cache entry name now
  local names="" out="" fetched_at age skip key retry_at retry_in retry_note
  cache_file=$(_cb_usage_cache_file)
  now=$(_cb_now)
  cache='{}'
  [[ -f "$cache_file" ]] && cache=$(jq -c '. // {}' "$cache_file" 2>/dev/null || printf '{}')
  names=$(_cb_accounts_list)
  [[ -z "$names" ]] && names="-"
  for name in $(printf '%s' "$names"); do
    [[ "$name" == "-" ]] && name=""
    key="${name:-_legacy}"
    entry=$(printf '%s' "$cache" | jq -c --arg k "$key" '.[$k] // empty' 2>/dev/null)
    fetched_at=$(printf '%s' "$entry" | jq -r '.fetchedAt // empty' 2>/dev/null)
    age=""
    if [[ -n "$fetched_at" ]] && [[ "$fetched_at" =~ ^[0-9]+$ ]]; then
      age=$(( now - fetched_at ))
    fi
    if [[ "$force" != "--refresh" ]] && [[ -n "$age" ]] && (( age < ttl )); then
      out="${out}$(printf '%s' "$entry" | jq -c --argjson age "$age" \
        --argjson expired "$(_cb_usage_token_expired "$name")" \
        '. + {ageSeconds: $age, tokenExpired: $expired}')"
      continue
    fi
    # A rate limit is a request to stop asking, so it outranks --refresh: the
    # whole point is that clicking Refresh again is what got us throttled.
    # "retry:until" holds one epoch per account. A colon is rejected by
    # add-account's name check, so this key can never collide with an account.
    retry_at=$(printf '%s' "$cache" | jq -r --arg k "$key" '.["retry:until"][$k] // empty' 2>/dev/null)
    retry_in=0
    if [[ "$retry_at" =~ ^[0-9]+$ ]] && (( retry_at > now )); then
      retry_in=$(( retry_at - now ))
    fi
    if (( retry_in > 0 )); then
      retry_note="rate limited by api.anthropic.com — retrying in $(( (retry_in + 59) / 60 )) min"
      if [[ -n "$entry" ]]; then
        out="${out}$(printf '%s' "$entry" | jq -c --argjson age "${age:-0}" --arg why "$retry_note" \
          --argjson expired "$(_cb_usage_token_expired "$name")" \
          '. + {ageSeconds: $age, staleReason: $why, tokenExpired: $expired}')"
      else
        out="${out}$(jq -n --arg account "$name" --arg why "$retry_note" \
          '{account: $account, status: "unavailable", detail: $why}')"
      fi
      continue
    fi
    skip=""
    if [[ -n "$only" ]]; then
      # "-" stands for the legacy account-less entry, whose name is empty.
      [[ "$only" == "-" ]] && only=""
      [[ "$name" != "$only" ]] && skip="yes"
    fi
    if [[ -n "$skip" ]]; then
      if [[ -n "$entry" ]]; then
        out="${out}$(printf '%s' "$entry" | jq -c --argjson age "${age:-0}" \
          --argjson expired "$(_cb_usage_token_expired "$name")" \
          '. + {ageSeconds: $age, tokenExpired: $expired}')"
      else
        out="${out}$(jq -n --arg account "$name" '{account: $account, status: "not-polled"}')"
      fi
      continue
    fi
    entry=$(_cb_usage_fetch_one "$name")
    # A failed fetch keeps the last good numbers visible, marked with their age.
    if [[ "$(printf '%s' "$entry" | jq -r '.status')" != "ok" ]] && [[ -n "$age" ]]; then
      entry=$(jq -n --argjson old "$(printf '%s' "$cache" | jq -c --arg k "${name:-_legacy}" '.[$k]')" \
                    --argjson new "$entry" --argjson age "$age" \
        'if ($old | type) == "object" and $old.status == "ok"
         then $old + {ageSeconds: $age, staleReason: ($new.detail // $new.status)}
              # Keep the retry delay: it belongs to the failed request, and the
              # backoff is recorded from this entry a few lines below.
              + (if ($new.retryAfter // 0) > 0 then {retryAfter: $new.retryAfter} else {} end)
         else $new end')
    fi
    # Remember (or forget) how long to hold off, so the wait survives the next
    # tick, the next Refresh click, and the next shell.
    cache=$(printf '%s' "$cache" | jq -c --arg k "$key" --argjson now "$now" \
      --argjson retry "$(printf '%s' "$entry" | jq -r '.retryAfter // 0')" \
      'if $retry > 0 then .["retry:until"] = ((.["retry:until"] // {}) + {($k): ($now + $retry)})
       else .["retry:until"] = ((.["retry:until"] // {}) | del(.[$k])) end')
    # ageSeconds/staleReason describe this read, not the stored result, and
    # retryAfter is a property of the failed request rather than the figures.
    cache=$(printf '%s' "$cache" | jq -c --arg k "$key" \
      --argjson v "$(printf '%s' "$entry" | jq -c 'del(.ageSeconds, .staleReason, .retryAfter)')" '.[$k] = $v')
    out="${out}$(printf '%s' "$entry" | jq -c \
      --argjson expired "$(_cb_usage_token_expired "$name")" \
      '. + {ageSeconds: (.ageSeconds // 0), tokenExpired: $expired}')"
  done
  mkdir -p "$(dirname "$cache_file")" 2>/dev/null
  if printf '%s' "$cache" > "${cache_file}.tmp" 2>/dev/null; then
    chmod 600 "${cache_file}.tmp" 2>/dev/null
    mv "${cache_file}.tmp" "$cache_file" 2>/dev/null || rm -f "${cache_file}.tmp"
  fi
  printf '%s' "$out" | jq -s -c '.'
}

_cb_usage_lines() {
  printf '%s' "$1" | jq -r '
    def money: (. * 100 | round) as $c
      | "\($c / 100 | floor).\(if ($c % 100) < 10 then "0" else "" end)\($c % 100)";
    # Symbols for the currencies Claude bills in; anything else keeps its code.
    def symbol: {"USD": "$", "EUR": "\u20ac", "GBP": "\u00a3", "JPY": "\u00a5"}[. // ""] // "\(.) ";
    def limit_name:
      if . == "session" then "5-hour session"
      elif . == "weekly_all" then "Weekly (all models)"
      elif . == "weekly_opus" then "Weekly (Opus)"
      elif . == "weekly_sonnet" then "Weekly (Sonnet)"
      else (gsub("_"; " ")) end;
    # How old the figures are qualifies every line beneath them, so it sits with
    # the account name rather than trailing the group.
    def freshness:
      (.ageSeconds // 0) as $age
      | if $age < 60 then "updated just now"
        elif $age < 3600 then "updated \(($age / 60) | floor) min ago"
        else "updated \(($age / 3600) | floor)h ago" end;
    .[] |
    "  \(if .account == "" then "subscription" else .account end)" as $name |
    "\($name):" as $head |
    if .status == "ok" then
      "\($name) (\(freshness)):",
      ( .limits[] | "    \(.kind | limit_name): \(.percent)%" +
        (if .resetsAt != null then " — resets \(.resetsAt | sub("\\..*$"; "") | sub("T"; " ") + " UTC")"
         # A 5-hour window has no reset time until it starts.
         elif .kind == "session" and (.isActive | not) then " — not started"
         else "" end) ),
      ( if .credits != null then
          (.credits.currency | symbol) as $csym |
          "    Credit balance: \($csym)\(.credits.balance | money)" +
          (if .credits.expiringAmount != null and .credits.nextExpiresAt != null
           then " — \($csym)\(.credits.expiringAmount | money) expires \(.credits.nextExpiresAt | sub("T.*$"; ""))"
           else "" end)
        else empty end ),
      ( if .spend != null then
          (.spend.currency | symbol) as $sym |
          "    Usage credits: \(.spend.percent)% used — \($sym)\(.spend.used | money) of \($sym)\(.spend.limit | money)"
        else empty end ),
      ( if .tokenExpired == true then
          "    ! access token expired — switch to this account to refresh it"
        else empty end ),
      ( if .staleReason != null then "    (not refreshed: \(.staleReason))" else empty end )
    elif .status == "token-expired" then
      "\($head) access token expired — switch to this account to refresh it"
    elif .status == "no-token" then
      "\($head) no stored login"
    elif .status == "not-polled" then
      "\($head) not checked — only the account in use is polled"

    else
      "\($head) unavailable (\(.detail // "unknown error"))"
    end'
}

_claude_billing_login() {
  if ! command -v claude &>/dev/null; then
    echo "claude CLI not found in PATH — run 'claude auth login --claudeai' once it is installed"
    return 1
  fi
  claude auth login --claudeai
}

# --- Main function ---

claude_billing() {
  local settings="$HOME/.claude/settings.json"
  local conf="$HOME/.claude-billing.conf"

  case "${1:-}" in
    api)
      [[ ! -f "$settings" ]] && { echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"; return 1; }
      local key
      key=$(_cb_cred_retrieve "anthropic-api-key")
      if [[ -z "$key" ]]; then
        echo "No Anthropic API key found in credential store. Add it with:"
        case "$(_cb_platform)" in
          macos)   echo "  security add-generic-password -s anthropic-api-key -a \"\$USER\" -w" ;;
          linux)   echo "  secret-tool store --label=anthropic-api-key service anthropic-api-key account \$USER" ;;
          windows) echo "  claude-billing add-key" ;;
        esac
        return 1
      fi
      # Pass key via env var — avoids exposing it in the process list via jq --arg
      ANTHROPIC_API_KEY="$key" _cb_settings_update "$settings" '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL) |
          del(.ANTHROPIC_DEFAULT_FABLE_MODEL) |
          .ANTHROPIC_API_KEY = env.ANTHROPIC_API_KEY
        )' || return 1
      if ! _claude_billing_backup_oauth; then
        _cb_settings_rollback "$settings"
        return 1
      fi
      _cb_mode_set "api"
      echo "Switched to API usage billing — restart Claude Code to apply"
      ;;

    subscription|sub)
      [[ ! -f "$settings" ]] && { echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"; return 1; }
      local acct="${2:-}" accounts a
      accounts=$(_cb_accounts_list)
      if [[ -n "$accounts" ]]; then
        if [[ -z "$acct" ]]; then
          echo "claude-billing: account name required. Saved accounts:"
          for a in $(_cb_accounts_list); do echo "  $a"; done
          echo "Usage: claude-billing subscription <name>"
          return 1
        fi
        if ! _cb_account_registered "$acct"; then
          echo "claude-billing: unknown account '$acct'. Saved accounts:"
          for a in $(_cb_accounts_list); do echo "  $a"; done
          echo "Add it with: claude-billing add-account $acct"
          return 1
        fi
      elif [[ -n "$acct" ]]; then
        echo "claude-billing: no accounts registered yet — add one with: claude-billing add-account $acct"
        return 1
      fi
      _cb_settings_update "$settings" '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_API_KEY) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL) |
          del(.ANTHROPIC_DEFAULT_FABLE_MODEL)
        )' || return 1
      if [[ -n "$acct" ]]; then
        local prev_active
        prev_active=$(_cb_active_get)
        # Stash the current account's live token before restoring the target's
        if [[ "$prev_active" != "$acct" ]]; then
          _claude_billing_backup_oauth || return 1
        fi
        _claude_billing_restore_account "$acct" || return 1
        _cb_mode_set "sub:$acct"
        echo "Switched to claude.ai subscription (account: $acct) — restart Claude Code to apply"
        if _cb_desktop_available && [[ "$(_cb_desktop_owner_get)" != "$acct" ]]; then
          echo "Claude.app desktop login unchanged — move it with: claude-billing desktop $acct"
        fi
      else
        if ! _claude_billing_restore_oauth; then
          _cb_settings_rollback "$settings"
          return 1
        fi
        _cb_mode_set "sub"
        echo "Switched to claude.ai subscription — restart Claude Code to apply"
      fi
      ;;

    accounts)
      local accounts active a
      accounts=$(_cb_accounts_list)
      if [[ -z "$accounts" ]]; then
        echo "No subscription accounts registered."
        echo "Add one with: claude-billing add-account <name>"
        return 0
      fi
      active=$(_cb_active_get)
      local desk
      desk=$(_cb_desktop_owner_get)
      echo "Subscription accounts:"
      for a in $(_cb_accounts_list); do
        local marker=""
        [[ "$a" == "$desk" ]] && marker=" [desktop]"
        if [[ "$a" == "$active" ]]; then
          echo "* $a (live login)$marker"
        elif [[ -n "$(_cb_cred_retrieve "$(_cb_acct_service "$a")")" ]]; then
          echo "  $a (token stored)$marker"
        else
          echo "  $a (no stored token — will prompt login)$marker"
        fi
      done
      ;;

    add-account)
      local name="${2:-}"
      [[ -z "$name" ]] && { echo "Usage: claude-billing add-account <name>"; return 1; }
      if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "claude-billing: account names may only contain letters, digits, '-' and '_'"
        return 1
      fi
      if _cb_account_registered "$name"; then
        echo "claude-billing: account '$name' already exists"
        return 1
      fi
      local live legacy adopt=""
      live=$(_cb_cred_retrieve "Claude Code-credentials")
      legacy=$(_cb_cred_retrieve "Claude Code-credentials-backup")
      if [[ -n "$live" && -z "$(_cb_active_get)" ]]; then
        printf "You're currently logged in to claude.ai. Save that login as '%s'? [Y/n]: " "$name"
        _cb_read -r adopt
        if [[ ! "$adopt" =~ ^[Nn]$ ]]; then
          _cb_account_register "$name"
          _cb_active_set "$name"
          echo "Account '$name' added (current live login)."
          echo "Switch between accounts with: claude-billing subscription <name>"
          return 0
        fi
      elif [[ -z "$live" && -n "$legacy" && -z "$(_cb_accounts_list)" ]]; then
        printf "Found a stored claude.ai login backup. Save it as '%s'? [Y/n]: " "$name"
        _cb_read -r adopt
        if [[ ! "$adopt" =~ ^[Nn]$ ]]; then
          if _cb_cred_store "$(_cb_acct_service "$name")" "$legacy"; then
            _cb_cred_delete "Claude Code-credentials-backup"
            _cb_account_register "$name"
            echo "Account '$name' added. Switch to it with: claude-billing subscription $name"
            return 0
          fi
          echo "claude-billing: failed to store token for '$name'" >&2
          return 1
        fi
      fi
      # Fresh login: stash the current login (if any), then authenticate
      _claude_billing_backup_oauth || return 1
      echo "Launching claude.ai login for '$name'..."
      _claude_billing_login || return 1
      _cb_account_register "$name"
      _cb_active_set "$name"
      echo "Account '$name' added and is now the live login."
      echo "Switch between accounts with: claude-billing subscription <name>"
      ;;

    remove-account)
      local name="${2:-}" confirm="" assume_yes="${3:-}"
      [[ -z "$name" ]] && { echo "Usage: claude-billing remove-account <name> [--yes]"; return 1; }
      if [[ -n "$assume_yes" && "$assume_yes" != "--yes" ]]; then
        echo "Usage: claude-billing remove-account <name> [--yes]"
        return 1
      fi
      if ! _cb_account_registered "$name"; then
        echo "claude-billing: unknown account '$name'"
        return 1
      fi
      if [[ "$(_cb_active_get)" == "$name" && "$assume_yes" != "--yes" ]]; then
        printf "'%s' is the current live login. Remove it from claude-billing anyway? (You stay logged in.) [y/N]: " "$name"
        _cb_read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
      fi
      if ! _cb_cred_delete "$(_cb_acct_service "$name")" || \
         ! _cb_cred_delete "$(_cb_acct_meta_service "$name")"; then
        echo "claude-billing: failed to remove stored credentials for '$name' — account kept for retry" >&2
        return 1
      fi
      rm -rf "$(_cb_desktop_stash_root)/${name:?}"
      [[ "$(_cb_desktop_owner_get)" == "$name" ]] && rm -f "$(_cb_desktop_stash_root)/.active"
      _cb_account_unregister "$name"
      echo "Removed account '$name'"
      ;;

    desktop)
      if ! _cb_desktop_available; then
        echo "claude-billing: Claude.app not found — desktop login switching is macOS-only"
        return 1
      fi
      local name="${2:-}" owner a
      owner=$(_cb_desktop_owner_get)
      if [[ -z "$name" ]]; then
        echo "Claude.app login: ${owner:-unknown account}"
        if [[ -n "$(_cb_accounts_list)" ]]; then
          echo "Saved accounts:"
          for a in $(_cb_accounts_list); do echo "  $a"; done
        fi
        echo "Usage: claude-billing desktop <name>"
        return 0
      fi
      if ! _cb_account_registered "$name"; then
        echo "claude-billing: unknown account '$name'. Saved accounts:"
        for a in $(_cb_accounts_list); do echo "  $a"; done
        echo "Add it with: claude-billing add-account $name"
        return 1
      fi
      if [[ "$owner" == "$name" ]]; then
        echo "Claude.app is already logged in as '$name'"
        return 0
      fi
      # First switch: the live login predates ownership tracking — ask whose
      # it is so it gets stashed under that name instead of .unclaimed.
      if [[ -z "$owner" && -f "$(_cb_desktop_app_dir)/Cookies" ]]; then
        local claim=""
        printf "Which account is Claude.app currently logged in to? (Enter if unsure): "
        _cb_read -r claim
        if [[ -n "$claim" ]] && ! _cb_account_registered "$claim"; then
          echo "claude-billing: unknown account '$claim' — the current login will be kept in $(_cb_desktop_stash_root)/.unclaimed instead"
          claim=""
        fi
        if [[ "$claim" == "$name" ]]; then
          _cb_desktop_owner_set "$name"
          echo "Claude.app is already logged in as '$name'"
          return 0
        fi
        owner="$claim"
      fi
      _cb_desktop_switch "$name" "$owner" || return 1
      [[ "$(_cb_desktop_owner_get)" == "$name" ]] || return 1
      ;;

    bedrock)
      [[ ! -f "$conf" ]] && { echo "claude-billing: no config found. Run: claude-billing config"; return 1; }
      [[ ! -f "$settings" ]] && { echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"; return 1; }
      local region sonnet opus haiku fable profile_mode aws_profile mode_profile
      region=$(_cb_conf_get "$conf" CLAUDE_BILLING_REGION)
      sonnet=$(_cb_conf_get "$conf" CLAUDE_BILLING_SONNET)
      opus=$(_cb_conf_get "$conf"   CLAUDE_BILLING_OPUS)
      haiku=$(_cb_conf_get "$conf"  CLAUDE_BILLING_HAIKU)
      fable=$(_cb_conf_get "$conf"  CLAUDE_BILLING_FABLE)
      profile_mode=$(_cb_conf_get "$conf" CLAUDE_BILLING_AWS_PROFILE_MODE)
      aws_profile=$(_cb_conf_get "$conf"  CLAUDE_BILLING_AWS_PROFILE)
      if [[ -z "$region" || -z "$sonnet" || -z "$opus" || -z "$haiku" ]]; then
        echo "claude-billing: Bedrock config is incomplete — run: claude-billing config"
        return 1
      fi
      if [[ "$profile_mode" == "explicit" && -z "$aws_profile" ]]; then
        echo "claude-billing: explicit AWS profile is empty — run: claude-billing config"
        return 1
      fi
      # shellcheck disable=SC2016  # $region/$sonnet/etc. are jq variables, not shell
      _cb_settings_update "$settings" '
        .env |= (
          del(.ANTHROPIC_API_KEY) |
          .CLAUDE_CODE_USE_BEDROCK = "1" |
          .AWS_REGION = $region |
          .ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet |
          .ANTHROPIC_DEFAULT_OPUS_MODEL = $opus |
          .ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku |
          if $fable != "" then .ANTHROPIC_DEFAULT_FABLE_MODEL = $fable
          else del(.ANTHROPIC_DEFAULT_FABLE_MODEL) end |
          if $mode == "explicit" then .AWS_PROFILE = $profile
          else del(.AWS_PROFILE) end
        )' \
        --arg sonnet "$sonnet" \
        --arg opus "$opus" \
        --arg haiku "$haiku" \
        --arg fable "$fable" \
        --arg region "$region" \
        --arg mode "$profile_mode" \
        --arg profile "$aws_profile" || return 1
      if ! _claude_billing_backup_oauth; then
        _cb_settings_rollback "$settings"
        return 1
      fi
      if [[ "$profile_mode" == "explicit" ]]; then
        mode_profile="$aws_profile"
      else
        mode_profile="${AWS_PROFILE:-default}"
      fi
      _cb_mode_set "bedrock:$mode_profile"
      echo "Switched to AWS Bedrock (region: $region) — restart Claude Code to apply"
      ;;

    status)
      [[ ! -f "$settings" ]] && { echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"; return 1; }
      _cb_require_cmd jq "install with: brew install jq / apt install jq / winget install jqlang.jq" || return 1
      local inherited_profile="${AWS_PROFILE:-default}"
      local json_status mode desktop_available="false"
      _cb_desktop_available && desktop_available="true"
      local active_aws_profile sso_json
      active_aws_profile=$(jq -r --arg inherited "$inherited_profile" '
        .env as $e |
        if ($e.CLAUDE_CODE_USE_BEDROCK // "") != "" then
          (if ($e.AWS_PROFILE // "") != "" then $e.AWS_PROFILE else $inherited end)
        else "" end' "$settings" 2>/dev/null) || active_aws_profile=""
      sso_json=$(_cb_sso_status_json "$active_aws_profile") || sso_json='[]'
      # The profile Bedrock would use even when Bedrock isn't the current mode,
      # so callers can show what a switch would select. Only explicit settings
      # and explicit config are deterministic; an inherited profile depends on
      # the environment of whoever starts Claude Code.
      local bedrock_profile="" bedrock_source="inherited" conf_mode="" conf_profile=""
      if [[ -f "$conf" ]]; then
        conf_mode=$(_cb_conf_get "$conf" CLAUDE_BILLING_AWS_PROFILE_MODE)
        conf_profile=$(_cb_conf_get "$conf" CLAUDE_BILLING_AWS_PROFILE)
      fi
      if [[ -n "$active_aws_profile" ]]; then
        bedrock_profile="$active_aws_profile"
        bedrock_source="settings"
      elif [[ "$conf_mode" == "explicit" && -n "$conf_profile" ]]; then
        bedrock_profile="$conf_profile"
        bedrock_source="config"
      fi
      json_status=$(jq -c \
        --argjson aws_sso "$sso_json" \
        --arg bedrock_profile "$bedrock_profile" \
        --arg bedrock_source "$bedrock_source" \
        --arg accounts "$(_cb_accounts_list)" \
        --arg active "$(_cb_active_get)" \
        --arg desktop_account "$(_cb_desktop_owner_get)" \
        --arg desktop_available "$desktop_available" \
        --arg inherited_profile "$inherited_profile" '
        .env as $e |
        if ($e.CLAUDE_CODE_USE_BEDROCK // "") != "" then
          ($e.AWS_PROFILE // "") as $profile |
          {
            mode: "bedrock:\(if $profile != "" then $profile else $inherited_profile end)",
            kind: "bedrock",
            account: null,
            awsProfile: (if $profile != "" then $profile else $inherited_profile end)
          }
        elif ($e.ANTHROPIC_API_KEY // "") != "" then
          {mode: "api", kind: "api", account: null, awsProfile: null}
        else
          {
            mode: (if $active != "" then "sub:\($active)" else "sub" end),
            kind: "subscription",
            account: (if $active != "" then $active else null end),
            awsProfile: null
          }
        end |
        . + {
          accounts: ($accounts | split(" ") | map(select(length > 0))),
          awsSso: $aws_sso,
          bedrockProfile: (if $bedrock_profile != "" then $bedrock_profile else null end),
          bedrockProfileSource: $bedrock_source,
          desktop: {
            available: ($desktop_available == "true"),
            account: (if $desktop_account != "" then $desktop_account else null end)
          }
        }' \
        "$settings") || return 1
      mode=$(printf '%s' "$json_status" | jq -r '.mode')
      [[ -n "$mode" ]] && _cb_mode_set "$mode"
      if [[ "${2:-}" == "--json" ]]; then
        printf '%s\n' "$json_status"
        return 0
      fi
      jq -r --arg active "$(_cb_active_get)" --arg inherited_profile "$inherited_profile" '
        .env as $e |
        if ($e.CLAUDE_CODE_USE_BEDROCK // "") != "" then
          "Current: AWS Bedrock",
          "  Region:  \($e.AWS_REGION // "not set")",
          "  Profile: \(if ($e.AWS_PROFILE // "") != "" then $e.AWS_PROFILE else "inherited (\($inherited_profile))" end)",
          "  Sonnet:  \($e.ANTHROPIC_DEFAULT_SONNET_MODEL // "not set")",
          "  Opus:    \($e.ANTHROPIC_DEFAULT_OPUS_MODEL // "not set")",
          "  Haiku:   \($e.ANTHROPIC_DEFAULT_HAIKU_MODEL // "not set")",
          "  Fable:   \($e.ANTHROPIC_DEFAULT_FABLE_MODEL // "not set")"
        elif ($e.ANTHROPIC_API_KEY // "") != "" then
          "Current: API usage billing"
        else
          "Current: claude.ai subscription" +
            (if $active != "" then " (account: \($active))" else "" end)
        end' "$settings"
      if [[ "$sso_json" != "[]" ]]; then
        echo "AWS SSO sessions:"
        _cb_sso_status_lines "$sso_json"
      fi
      if _cb_desktop_available; then
        local desk_owner
        desk_owner=$(_cb_desktop_owner_get)
        echo "Desktop (Claude.app): ${desk_owner:-unknown account}"
      fi
      ;;

    usage)
      _cb_require_cmd jq "install with: brew install jq / apt install jq / winget install jqlang.jq" || return 1
      _cb_require_cmd curl "install curl first" || return 1
      local usage_json usage_force="" usage_only="" usage_as_json="" usage_arg
      shift
      for usage_arg in "$@"; do
        case "$usage_arg" in
          --refresh) usage_force="--refresh" ;;
          --json) usage_as_json="yes" ;;
          # Only the account in use is worth a request; see _cb_usage_json.
          --active) usage_only=$(_cb_active_get); [[ -n "$usage_only" ]] || usage_only="-" ;;
          *) echo "claude-billing usage: unknown option $usage_arg" >&2; return 1 ;;
        esac
      done
      usage_json=$(_cb_usage_json "$usage_force" "$usage_only") || return 1
      if [[ -n "$usage_as_json" ]]; then
        printf '%s\n' "$usage_json"
        return 0
      fi
      echo "Subscription plan usage:"
      _cb_usage_lines "$usage_json"
      echo "Source: Claude's unofficial OAuth usage endpoint — figures may lag /usage in Claude Code"
      ;;

    sso)
      _cb_require_cmd jq "install with: brew install jq / apt install jq / winget install jqlang.jq" || return 1
      local sso_only
      sso_only=$(_cb_sso_status_json "") || return 1
      if [[ "$sso_only" == "[]" ]]; then
        echo "No AWS SSO logins configured in ${AWS_CONFIG_FILE:-$HOME/.aws/config}"
        return 0
      fi
      if [[ "${2:-}" == "--json" ]]; then
        printf '%s\n' "$sso_only"
        return 0
      fi
      echo "AWS SSO sessions:"
      _cb_sso_status_lines "$sso_only"
      ;;

    sso-login)
      if [[ -z "${2:-}" ]]; then
        echo "Usage: claude-billing sso-login <session>"
        echo "Run 'claude-billing sso' to list AWS SSO sessions."
        return 1
      fi
      _claude_billing_sso_login "$2"
      ;;

    menubar)
      if [[ "$(_cb_platform)" != "macos" ]]; then
        echo "claude-billing: the menu bar app requires macOS" >&2
        return 1
      fi
      local menubar_action="${2:-}"
      local menubar_installer="$HOME/.claude-billing/install-menubar.sh"
      case "$menubar_action" in
        install|uninstall) ;;
        *)
          echo "Usage: claude-billing menubar <install|uninstall>"
          return 1
          ;;
      esac
      if [[ ! -f "$menubar_installer" ]]; then
        echo "claude-billing: menu bar installer not found — update claude-billing first" >&2
        return 1
      fi
      case "$menubar_action" in
        install)
          bash "$menubar_installer"
          ;;
        uninstall)
          bash "$menubar_installer" --uninstall
          ;;
      esac
      ;;

    add-key)
      local key=""
      printf "Enter your Anthropic API key: "
      _cb_read -rs key || { echo ""; echo "claude-billing: failed to read API key" >&2; return 1; }
      echo ""
      [[ -z "$key" ]] && { echo "claude-billing: API key cannot be empty" >&2; return 1; }
      if ! _cb_cred_store "anthropic-api-key" "$key"; then
        key=""
        echo "claude-billing: failed to save API key" >&2
        return 1
      fi
      key=""
      echo "API key saved"
      ;;

    config)
      _claude_billing_configure
      ;;

    login)
      _claude_billing_login
      ;;

    version)
      echo "claude-billing $_CB_VERSION"
      ;;

    uninstall)
      _claude_billing_uninstall
      ;;

    *)
      echo "Usage: claude-billing <command> [name]"
      echo ""
      echo "  subscription [name]    Use claude.ai subscription (alias: sub; name required"
      echo "                         once accounts are registered)"
      echo "  api                    Use Anthropic API key billing"
      echo "  bedrock                Use AWS Bedrock"
      echo "  status [--json]        Show current billing mode"
      echo "  accounts               List registered subscription accounts"
      echo "  add-account <name>     Register a claude.ai subscription account"
      echo "  remove-account <name>  Remove an account and its stored token"
      echo "  usage [--json]         Show subscription plan usage (add --refresh to force)"
      echo "  sso [--json]           Show AWS SSO session expiry for Bedrock profiles"
      echo "  sso-login <session>    Refresh an expired AWS SSO login"
      echo "  desktop [name]         Show or switch the Claude.app desktop login (macOS)"
      echo "  menubar <action>       Install or uninstall the menu bar app (macOS)"
      echo "  config                 Reconfigure Bedrock region, models, and AWS profile"
      echo "  add-key                Save or update your Anthropic API key"
      echo "  login                  Log in to claude.ai"
      echo "  version                Show version"
      echo "  uninstall              Remove claude-billing"
      ;;
  esac
}

_claude_billing_uninstall() {
  local accounts_list cleanup_failed=0
  local menubar_app="$HOME/Applications/Claude Billing.app"
  local menubar_agent="$HOME/Library/LaunchAgents/com.hschin.claude-billing-menubar.plist"
  accounts_list=$(_cb_accounts_list)
  echo "This will remove:"
  echo "  ~/.claude-billing/          (scripts and stashed desktop app logins)"
  echo "  ~/.claude-billing.conf      (config)"
  echo "  ~/.claude-billing-accounts  (account registry)"
  echo "  ~/.claude-billing-mode      (prompt state)"
  echo "  Claude Billing menu bar app (when installed)"
  echo "  source line from your shell RC file"
  echo ""
  printf "Continue? [y/N]: "
  confirm=""
  _cb_read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }

  local rc rctmp legacy_source
  legacy_source="source \"$HOME/.claude-billing/claude_billing.sh\""
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if grep -q ">>> claude-billing >>>" "$rc" 2>/dev/null; then
      if rctmp=$(mktemp "${rc}.XXXXXX") && \
         awk '/# >>> claude-billing >>>/{skip=1} !skip{print} /# <<< claude-billing <<</{skip=0}' \
           "$rc" > "$rctmp" && mv "$rctmp" "$rc"; then
        echo "Removed source block from $rc"
      else
        rm -f "${rctmp:-}"
        echo "claude-billing: failed to remove source block from $rc" >&2
        cleanup_failed=1
      fi
    elif grep -Fqx "$legacy_source" "$rc" 2>/dev/null; then
      # awk returns success even when removing the only line in the file.
      if rctmp=$(mktemp "${rc}.XXXXXX") && \
         awk -v target="$legacy_source" '$0 != target' "$rc" > "$rctmp" && mv "$rctmp" "$rc"; then
        echo "Removed source line from $rc"
      else
        rm -f "${rctmp:-}"
        echo "claude-billing: failed to remove source line from $rc" >&2
        cleanup_failed=1
      fi
    fi
  done

  if [[ -e "$menubar_agent" ]]; then
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/com.hschin.claude-billing-menubar" 2>/dev/null || true
    fi
    rm -f "$menubar_agent"
  fi
  rm -rf "$menubar_app"

  rm -f "$HOME/.claude-billing.conf" "$HOME/.claude-billing-accounts" "$HOME/.claude-billing-mode"
  rm -rf "$HOME/.claude-billing"

  echo ""
  printf "Remove stored Anthropic API key from credential store? [y/N]: "
  local remove_key=""
  _cb_read -r remove_key
  if [[ "$remove_key" =~ ^[Yy]$ ]]; then
    if _cb_cred_delete "anthropic-api-key"; then
      echo "Removed Anthropic API key"
    else
      echo "claude-billing: failed to remove Anthropic API key; it may remain in the credential store" >&2
      cleanup_failed=1
    fi
  fi

  printf "Remove claude.ai OAuth backup from credential store? [y/N]: "
  local remove_oauth=""
  _cb_read -r remove_oauth
  if [[ "$remove_oauth" =~ ^[Yy]$ ]]; then
    if _cb_cred_delete "Claude Code-credentials-backup"; then
      echo "Removed OAuth backup"
    else
      echo "claude-billing: failed to remove OAuth backup; it may remain in the credential store" >&2
      cleanup_failed=1
    fi
  fi

  if [[ -n "$accounts_list" ]]; then
    printf "Remove stored subscription account tokens (%s)? [y/N]: " "$accounts_list"
    local remove_accts="" a account_cleanup_failed=0
    _cb_read -r remove_accts
    if [[ "$remove_accts" =~ ^[Yy]$ ]]; then
      for a in $(printf '%s' "$accounts_list"); do
        if ! _cb_cred_delete "$(_cb_acct_service "$a")" || \
           ! _cb_cred_delete "$(_cb_acct_meta_service "$a")"; then
          echo "claude-billing: failed to remove all stored credentials for '$a'" >&2
          account_cleanup_failed=1
        fi
      done
      if [[ "$account_cleanup_failed" -eq 0 ]]; then
        echo "Removed stored account tokens"
      else
        cleanup_failed=1
      fi
    fi
  fi

  echo ""
  if [[ "$cleanup_failed" -ne 0 ]]; then
    echo "Uninstalled with warnings: some credentials may remain in the platform credential store." >&2
    return 1
  fi
  echo "Uninstalled. Open a new shell to complete removal."
}

_claude_billing_pick_model() {
  local label="$1"
  local default="$2"
  local model_list="$3"

  if [[ -n "$model_list" ]]; then
    printf "Select %s model number (or type an ID) [%s]: " "$label" "$default" >&2
  else
    printf "%s model ID [%s]: " "$label" "$default" >&2
  fi
  _cb_read -r input

  if [[ -z "$input" ]]; then
    echo "$default"
  elif [[ "$input" =~ ^[0-9]+$ ]] && [[ -n "$model_list" ]]; then
    echo "$model_list" | sed -n "${input}p"
  else
    echo "$input"
  fi
}

_claude_billing_configure() {
  echo "=== claude-billing configuration ==="
  echo ""

  local conf="$HOME/.claude-billing.conf"
  local saved_region saved_sonnet saved_opus saved_haiku saved_fable saved_mode saved_aws_profile
  if [[ -f "$conf" ]]; then
    saved_region=$(_cb_conf_get "$conf" CLAUDE_BILLING_REGION)
    saved_sonnet=$(_cb_conf_get "$conf" CLAUDE_BILLING_SONNET)
    saved_opus=$(_cb_conf_get "$conf"   CLAUDE_BILLING_OPUS)
    saved_haiku=$(_cb_conf_get "$conf"  CLAUDE_BILLING_HAIKU)
    saved_fable=$(_cb_conf_get "$conf"  CLAUDE_BILLING_FABLE)
    saved_mode=$(_cb_conf_get "$conf"   CLAUDE_BILLING_AWS_PROFILE_MODE)
    saved_aws_profile=$(_cb_conf_get "$conf" CLAUDE_BILLING_AWS_PROFILE)
  fi

  echo "How should Claude Code choose the AWS profile for Bedrock?"
  echo "  1) Inherit from shell / default AWS credential chain"
  echo "  2) Set a specific AWS_PROFILE in Claude settings"
  local default_mode_num="1"
  [[ "$saved_mode" == "explicit" ]] && default_mode_num="2"
  printf "Choose [%s]: " "$default_mode_num"
  local mode_choice=""
  _cb_read -r mode_choice
  mode_choice="${mode_choice:-$default_mode_num}"

  local profile_mode="inherit" aws_profile="" setup_creds=""
  if [[ "$mode_choice" == "2" ]]; then
    profile_mode="explicit"
    if [[ -n "$saved_aws_profile" ]]; then
      printf "AWS profile name for Claude Code Bedrock calls [%s]: " "$saved_aws_profile"
    else
      printf "AWS profile name for Claude Code Bedrock calls: "
    fi
    _cb_read -r aws_profile
    aws_profile="${aws_profile:-$saved_aws_profile}"
    if [[ -z "$aws_profile" ]]; then
      echo "claude-billing: AWS profile name is required in explicit mode" >&2
      return 1
    fi
    echo ""
    printf "Configure credentials for this profile now? [y/N]: "
    _cb_read -r setup_creds
    if [[ "$setup_creds" =~ ^[Yy]$ ]]; then
      _cb_require_cmd aws "see https://aws.amazon.com/cli/" || return 1
      aws configure --profile "$aws_profile"
      echo ""
    fi
  else
    printf "Configure default AWS credentials now? [y/N]: "
    _cb_read -r setup_creds
    if [[ "$setup_creds" =~ ^[Yy]$ ]]; then
      _cb_require_cmd aws "see https://aws.amazon.com/cli/" || return 1
      aws configure
      echo ""
    fi
  fi

  local default_region="${saved_region:-us-east-1}"
  printf "AWS region for Bedrock [%s]: " "$default_region"
  _cb_read -r region
  region="${region:-$default_region}"

  echo ""
  echo "Fetching available Claude models in $region..."
  local models
  # shellcheck disable=SC2016  # backticks in --query are JMESPath syntax, not shell
  models=$(aws bedrock list-foundation-models \
    --region "$region" \
    --by-provider Anthropic \
    --query 'modelSummaries[?contains(modelId, `claude`)].modelId' \
    --output text 2>/dev/null | tr '\t' '\n' | sort)

  if [[ -z "$models" ]]; then
    echo "Warning: could not fetch models from AWS (check your credentials and region)."
    echo "You can enter model IDs manually."
    models=""
  else
    echo ""
    echo "Available Claude models:"
    local i=1
    while IFS= read -r m; do
      echo "  $i) $m"
      ((i++))
    done <<< "$models"
    echo ""
  fi

  local sonnet opus haiku fable
  sonnet=$(_claude_billing_pick_model "Sonnet" "${saved_sonnet:-}" "$models")
  opus=$(_claude_billing_pick_model "Opus" "${saved_opus:-}" "$models")
  haiku=$(_claude_billing_pick_model "Haiku" "${saved_haiku:-}" "$models")
  fable=$(_claude_billing_pick_model "Fable" "${saved_fable:-}" "$models")

  cat > "$HOME/.claude-billing.conf" <<EOF
CLAUDE_BILLING_REGION="$region"
CLAUDE_BILLING_SONNET="$sonnet"
CLAUDE_BILLING_OPUS="$opus"
CLAUDE_BILLING_HAIKU="$haiku"
CLAUDE_BILLING_FABLE="$fable"
CLAUDE_BILLING_AWS_PROFILE_MODE="$profile_mode"
CLAUDE_BILLING_AWS_PROFILE="$aws_profile"
EOF

  echo ""
  echo "Config saved to ~/.claude-billing.conf"
  echo "  Region:  $region"
  if [[ "$profile_mode" == "explicit" ]]; then
    echo "  Profile: $aws_profile"
  else
    echo "  Profile: inherited/default"
  fi
  echo "  Sonnet:  $sonnet"
  echo "  Opus:    $opus"
  echo "  Haiku:   $haiku"
  echo "  Fable:   ${fable:-(not set)}"
  if [[ "$profile_mode" == "explicit" ]] && [[ ! "$setup_creds" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Note: run 'aws configure --profile $aws_profile' before switching to Bedrock if you haven't already."
  fi
}

alias claude-billing='claude_billing'
