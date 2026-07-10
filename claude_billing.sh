# shellcheck shell=bash
# claude-billing: switch Claude Code between billing modes (subscription, API, Bedrock)
_CB_VERSION="1.1.0"
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
  local service="$1"
  case "$(_cb_platform)" in
    macos)
      security delete-generic-password -s "$service" -a "$USER" 2>/dev/null
      ;;
    linux)
      secret-tool clear service "$service" account "$USER" 2>/dev/null
      ;;
    windows)
      _cb_cred_file_delete "$service"
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
  tmp=$(mktemp "${cred_file}.XXXXXX") && chmod 600 "$tmp"
  # shellcheck disable=SC2015  # || rm is intentional cleanup, not an else branch
  awk -v svc="$service" 'substr($0,1,length(svc)+1) != svc "="' "$cred_file" > "$tmp" \
    && mv "$tmp" "$cred_file" || rm -f "$tmp"
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

  case "$1" in
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
      _claude_billing_backup_oauth
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
        # Stash the current account's live token before restoring the target's
        if [[ "$(_cb_active_get)" != "$acct" ]]; then
          _claude_billing_backup_oauth || return 1
        fi
        _claude_billing_restore_account "$acct" || return 1
        echo "Switched to claude.ai subscription (account: $acct) — restart Claude Code to apply"
      else
        _claude_billing_restore_oauth
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
      echo "Subscription accounts:"
      for a in $(_cb_accounts_list); do
        if [[ "$a" == "$active" ]]; then
          echo "* $a (live login)"
        elif [[ -n "$(_cb_cred_retrieve "$(_cb_acct_service "$a")")" ]]; then
          echo "  $a (token stored)"
        else
          echo "  $a (no stored token — will prompt login)"
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
      local name="${2:-}" confirm=""
      [[ -z "$name" ]] && { echo "Usage: claude-billing remove-account <name>"; return 1; }
      if ! _cb_account_registered "$name"; then
        echo "claude-billing: unknown account '$name'"
        return 1
      fi
      if [[ "$(_cb_active_get)" == "$name" ]]; then
        printf "'%s' is the current live login. Remove it from claude-billing anyway? (You stay logged in.) [y/N]: " "$name"
        _cb_read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
      fi
      _cb_cred_delete "$(_cb_acct_service "$name")"
      _cb_account_unregister "$name"
      echo "Removed account '$name'"
      ;;

    bedrock)
      [[ ! -f "$conf" ]] && { echo "claude-billing: no config found. Run: claude-billing config"; return 1; }
      [[ ! -f "$settings" ]] && { echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"; return 1; }
      local region sonnet opus haiku fable profile_mode aws_profile
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
      _claude_billing_backup_oauth
      echo "Switched to AWS Bedrock (region: $region) — restart Claude Code to apply"
      ;;

    status)
      [[ ! -f "$settings" ]] && { echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"; return 1; }
      _cb_require_cmd jq "install with: brew install jq / apt install jq / winget install jqlang.jq" || return 1
      jq -r --arg active "$(_cb_active_get)" '
        .env as $e |
        if ($e.CLAUDE_CODE_USE_BEDROCK // "") != "" then
          "Current: AWS Bedrock",
          "  Region:  \($e.AWS_REGION // "not set")",
          "  Profile: \(if ($e.AWS_PROFILE // "") != "" then $e.AWS_PROFILE else "inherited/default" end)",
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
      ;;

    add-key)
      printf "Enter your Anthropic API key: "
      _cb_read -rs key
      echo ""
      _cb_cred_store "anthropic-api-key" "$key"
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
      echo "  status                 Show current billing mode"
      echo "  accounts               List registered subscription accounts"
      echo "  add-account <name>     Register a claude.ai subscription account"
      echo "  remove-account <name>  Remove an account and its stored token"
      echo "  config                 Reconfigure Bedrock region, models, and AWS profile"
      echo "  add-key                Save or update your Anthropic API key"
      echo "  login                  Log in to claude.ai"
      echo "  version                Show version"
      echo "  uninstall              Remove claude-billing"
      ;;
  esac
}

_claude_billing_uninstall() {
  local accounts_list
  accounts_list=$(_cb_accounts_list)
  echo "This will remove:"
  echo "  ~/.claude-billing/          (scripts)"
  echo "  ~/.claude-billing.conf      (config)"
  echo "  ~/.claude-billing-accounts  (account registry)"
  echo "  source line from your shell RC file"
  echo ""
  printf "Continue? [y/N]: "
  confirm=""
  _cb_read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }

  local rc rctmp
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if grep -q ">>> claude-billing >>>" "$rc" 2>/dev/null; then
      rctmp=$(mktemp "${rc}.XXXXXX")
      # shellcheck disable=SC2015
      awk '/# >>> claude-billing >>>/{skip=1} !skip{print} /# <<< claude-billing <<</{skip=0}' \
        "$rc" > "$rctmp" && mv "$rctmp" "$rc" || rm -f "$rctmp"
      echo "Removed source block from $rc"
    elif grep -q "claude-billing" "$rc" 2>/dev/null; then
      rctmp=$(mktemp "${rc}.XXXXXX")
      # shellcheck disable=SC2015
      grep -v "claude-billing" "$rc" > "$rctmp" && mv "$rctmp" "$rc" || rm -f "$rctmp"
      echo "Removed source line from $rc"
    fi
  done

  rm -f "$HOME/.claude-billing.conf" "$HOME/.claude-billing-accounts"
  rm -rf "$HOME/.claude-billing"

  echo ""
  printf "Remove stored Anthropic API key from credential store? [y/N]: "
  local remove_key=""
  _cb_read -r remove_key
  if [[ "$remove_key" =~ ^[Yy]$ ]]; then
    _cb_cred_delete "anthropic-api-key"
    echo "Removed Anthropic API key"
  fi

  printf "Remove claude.ai OAuth backup from credential store? [y/N]: "
  local remove_oauth=""
  _cb_read -r remove_oauth
  if [[ "$remove_oauth" =~ ^[Yy]$ ]]; then
    _cb_cred_delete "Claude Code-credentials-backup"
    echo "Removed OAuth backup"
  fi

  if [[ -n "$accounts_list" ]]; then
    printf "Remove stored subscription account tokens (%s)? [y/N]: " "$accounts_list"
    local remove_accts="" a
    _cb_read -r remove_accts
    if [[ "$remove_accts" =~ ^[Yy]$ ]]; then
      for a in $(printf '%s' "$accounts_list"); do
        _cb_cred_delete "$(_cb_acct_service "$a")"
      done
      echo "Removed stored account tokens"
    fi
  fi

  echo ""
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
