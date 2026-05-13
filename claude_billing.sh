# claude-billing: switch Claude Code between billing modes (subscription, API, Bedrock)
# Config: ~/.claude-billing.conf
# Requires: jq, aws CLI (for Bedrock)
# macOS: uses Keychain (security CLI)
# Linux: uses GNOME Keyring (secret-tool)
# Windows (Git Bash): uses ~/.claude-billing-credentials (chmod 600)

# --- Helpers ---

_cb_conf_get() {
  local conf="$1" key="$2" line val
  while IFS= read -r line; do
    if [[ "$line" == "${key}="* ]]; then
      val="${line#${key}=}"
      val="${val#\"}"
      val="${val%\"}"
      printf '%s' "$val"
      return
    fi
  done < "$conf"
}

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
  touch "$cred_file" && chmod 600 "$cred_file"
  local tmp
  tmp=$(mktemp "${cred_file}.XXXXXX") && chmod 600 "$tmp"
  { awk -v svc="$service" 'substr($0,1,length(svc)+1) != svc "="' "$cred_file" 2>/dev/null || true
    printf '%s=%s\n' "$service" "$value"
  } > "$tmp" && mv "$tmp" "$cred_file" || rm -f "$tmp"
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
  awk -v svc="$service" 'substr($0,1,length(svc)+1) != svc "="' "$cred_file" > "$tmp" \
    && mv "$tmp" "$cred_file" || rm -f "$tmp"
}

# --- OAuth backup / restore ---

_claude_billing_backup_oauth() {
  local oauth
  oauth=$(_cb_cred_retrieve "Claude Code-credentials")
  if [[ -n "$oauth" ]]; then
    # Only overwrite backup if we have a live token — prevents clobbering a valid backup
    _cb_cred_store "Claude Code-credentials-backup" "$oauth"
    _cb_cred_delete "Claude Code-credentials"
  fi
}

_claude_billing_restore_oauth() {
  local backup
  backup=$(_cb_cred_retrieve "Claude Code-credentials-backup")
  if [[ -n "$backup" ]]; then
    _cb_cred_store "Claude Code-credentials" "$backup"
    _cb_cred_delete "Claude Code-credentials-backup"
    echo "Restored claude.ai OAuth token"
  else
    echo "No OAuth backup found — launching login..."
    _claude_billing_login
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
  local tmp

  if [[ ! -f "$conf" ]]; then
    echo "claude-billing: no config found. Run: claude-billing config"
    return 1
  fi

  if [[ ! -f "$settings" ]]; then
    echo "claude-billing: ~/.claude/settings.json not found — is Claude Code installed?"
    return 1
  fi

  CLAUDE_BILLING_REGION=$(_cb_conf_get "$conf" CLAUDE_BILLING_REGION)
  CLAUDE_BILLING_SONNET=$(_cb_conf_get "$conf" CLAUDE_BILLING_SONNET)
  CLAUDE_BILLING_OPUS=$(_cb_conf_get "$conf"   CLAUDE_BILLING_OPUS)
  CLAUDE_BILLING_HAIKU=$(_cb_conf_get "$conf"  CLAUDE_BILLING_HAIKU)

  case "$1" in
    api)
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
      tmp=$(mktemp "$HOME/.claude/settings.XXXXXX")
      ANTHROPIC_API_KEY="$key" jq '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL) |
          .ANTHROPIC_API_KEY = env.ANTHROPIC_API_KEY
        )' "$settings" > "$tmp" && mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
      _claude_billing_backup_oauth
      echo "Switched to API usage billing — restart Claude Code to apply"
      ;;

    subscription)
      tmp=$(mktemp "$HOME/.claude/settings.XXXXXX")
      jq '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_API_KEY) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL)
        )' "$settings" > "$tmp" && mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
      _claude_billing_restore_oauth
      echo "Switched to claude.ai subscription — restart Claude Code to apply"
      ;;

    bedrock)
      tmp=$(mktemp "$HOME/.claude/settings.XXXXXX")
      jq \
        --arg sonnet "$CLAUDE_BILLING_SONNET" \
        --arg opus "$CLAUDE_BILLING_OPUS" \
        --arg haiku "$CLAUDE_BILLING_HAIKU" \
        --arg region "$CLAUDE_BILLING_REGION" '
        .env |= (
          del(.ANTHROPIC_API_KEY) |
          .CLAUDE_CODE_USE_BEDROCK = "1" |
          .AWS_REGION = $region |
          .ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet |
          .ANTHROPIC_DEFAULT_OPUS_MODEL = $opus |
          .ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku
        )' "$settings" > "$tmp" && mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
      _claude_billing_backup_oauth
      echo "Switched to AWS Bedrock (region: $CLAUDE_BILLING_REGION) — restart Claude Code to apply"
      ;;

    status)
      local env
      env=$(jq -r '.env' "$settings")
      local bedrock api_key
      bedrock=$(echo "$env" | jq -r '.CLAUDE_CODE_USE_BEDROCK // empty')
      api_key=$(echo "$env" | jq -r '.ANTHROPIC_API_KEY // empty')
      if [[ -n "$bedrock" ]]; then
        echo "Current: AWS Bedrock"
        echo "  Region:  $(echo "$env" | jq -r '.AWS_REGION // "not set"')"
        echo "  Sonnet:  $(echo "$env" | jq -r '.ANTHROPIC_DEFAULT_SONNET_MODEL // "not set"')"
        echo "  Opus:    $(echo "$env" | jq -r '.ANTHROPIC_DEFAULT_OPUS_MODEL // "not set"')"
        echo "  Haiku:   $(echo "$env" | jq -r '.ANTHROPIC_DEFAULT_HAIKU_MODEL // "not set"')"
      elif [[ -n "$api_key" ]]; then
        echo "Current: API usage billing"
      else
        echo "Current: claude.ai subscription"
      fi
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

    uninstall)
      echo "This will remove:"
      echo "  ~/.claude-billing/       (scripts)"
      echo "  ~/.claude-billing.conf   (config)"
      echo "  source line from your shell RC file"
      echo ""
      printf "Continue? [y/N]: "
      _cb_read -r confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }

      # Remove source line from whichever RC file has it
      local rc rctmp
      for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        if grep -q "claude-billing" "$rc" 2>/dev/null; then
          rctmp=$(mktemp "${rc}.XXXXXX")
          grep -v "claude-billing" "$rc" > "$rctmp" && mv "$rctmp" "$rc" || rm -f "$rctmp"
          echo "Removed source line from $rc"
        fi
      done

      rm -f "$HOME/.claude-billing.conf"
      rm -rf "$HOME/.claude-billing"

      echo "Uninstalled. Open a new shell to complete removal."
      ;;

    *)
      echo "Usage: claude-billing [subscription|api|bedrock|status|config|add-key|login|uninstall]"
      echo ""
      echo "  subscription  Use claude.ai subscription (Pro, Max, Teams, Enterprise)"
      echo "  api           Use Anthropic API key billing"
      echo "  bedrock       Use AWS Bedrock"
      echo "  status        Show current billing mode"
      echo "  config        Reconfigure Bedrock region and model IDs"
      echo "  add-key       Save your Anthropic API key to the credential store"
      echo "  login         Log in to claude.ai"
      echo "  uninstall     Remove claude-billing"
      ;;
  esac
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

  printf "Configure AWS credentials now? [y/N]: "
  _cb_read -r setup_creds
  if [[ "$setup_creds" =~ ^[Yy]$ ]]; then
    printf "AWS profile name (leave blank for default): "
    _cb_read -r cred_profile
    if [[ -n "$cred_profile" ]]; then
      aws configure --profile "$cred_profile"
    else
      aws configure
    fi
    echo ""
  fi

  local default_region="${CLAUDE_BILLING_REGION:-us-east-1}"
  printf "AWS region for Bedrock [%s]: " "$default_region"
  _cb_read -r region
  region="${region:-$default_region}"

  echo ""
  echo "Fetching available Claude models in $region..."
  local models
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

  local sonnet opus haiku
  sonnet=$(_claude_billing_pick_model "Sonnet" "${CLAUDE_BILLING_SONNET:-}" "$models")
  opus=$(_claude_billing_pick_model "Opus" "${CLAUDE_BILLING_OPUS:-}" "$models")
  haiku=$(_claude_billing_pick_model "Haiku" "${CLAUDE_BILLING_HAIKU:-}" "$models")

  cat > "$HOME/.claude-billing.conf" <<EOF
CLAUDE_BILLING_REGION="$region"
CLAUDE_BILLING_SONNET="$sonnet"
CLAUDE_BILLING_OPUS="$opus"
CLAUDE_BILLING_HAIKU="$haiku"
EOF

  echo ""
  echo "Config saved to ~/.claude-billing.conf"
  echo "  Region:  $region"
  echo "  Sonnet:  $sonnet"
  echo "  Opus:    $opus"
  echo "  Haiku:   $haiku"
}

alias claude-billing='claude_billing'
