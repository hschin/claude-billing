# claude-billing: switch Claude Code between billing modes (subscription, API, Bedrock)
# Config: ~/.claude-billing.conf
# Requires: jq, aws CLI (for Bedrock)
# macOS: uses Keychain (security CLI)
# Linux: uses GNOME Keyring (secret-tool)
# Windows (Git Bash): uses ~/.claude-billing-credentials (chmod 600)

# --- Platform detection ---

_cb_platform() {
  case "$(uname -s)" in
    Darwin)             echo "macos" ;;
    Linux)              echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)                  echo "unknown" ;;
  esac
}

# --- Credential storage abstraction ---

_cb_cred_store() {
  local service="$1" value="$2"
  case "$(_cb_platform)" in
    macos)
      security add-generic-password -s "$service" -a "$USER" -w "$value" 2>/dev/null || \
        security add-generic-password -U -s "$service" -a "$USER" -w "$value" 2>/dev/null
      ;;
    linux)
      echo -n "$value" | secret-tool store --label="$service" service "$service" account "$USER" 2>/dev/null
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
  local existing
  existing=$(grep -v "^${service}=" "$cred_file" 2>/dev/null)
  printf '%s\n' "$existing" > "$cred_file"
  echo "${service}=${value}" >> "$cred_file"
}

_cb_cred_file_retrieve() {
  local service="$1"
  local cred_file="$HOME/.claude-billing-credentials"
  grep "^${service}=" "$cred_file" 2>/dev/null | cut -d= -f2-
}

_cb_cred_file_delete() {
  local service="$1"
  local cred_file="$HOME/.claude-billing-credentials"
  [[ -f "$cred_file" ]] || return
  local existing
  existing=$(grep -v "^${service}=" "$cred_file")
  printf '%s\n' "$existing" > "$cred_file"
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
    echo "No OAuth backup found — run 'claude /login' after launching Claude Code to authenticate with your subscription"
  fi
}

# --- Main function ---

claude_billing() {
  local settings="$HOME/.claude/settings.json"
  local conf="$HOME/.claude-billing.conf"

  if [[ ! -f "$conf" ]]; then
    echo "claude-billing: no config found. Run: claude-billing config"
    return 1
  fi

  # shellcheck source=/dev/null
  source "$conf"

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
      jq --arg key "$key" '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL) |
          .ANTHROPIC_API_KEY = $key
        )' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
      _claude_billing_backup_oauth
      echo "Switched to API usage billing — restart Claude Code to apply"
      ;;

    subscription)
      jq '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_API_KEY) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL)
        )' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
      _claude_billing_restore_oauth
      echo "Switched to claude.ai subscription — restart Claude Code to apply"
      ;;

    bedrock)
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
        )' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
      _claude_billing_backup_oauth
      echo "Switched to AWS Bedrock (region: $CLAUDE_BILLING_REGION) — restart Claude Code to apply"
      ;;

    status)
      local bedrock api_key
      bedrock=$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // empty' "$settings")
      api_key=$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$settings")
      if [[ -n "$bedrock" ]]; then
        echo "Current: AWS Bedrock"
        echo "  Region:  $(jq -r '.env.AWS_REGION // "not set"' "$settings")"
        echo "  Sonnet:  $(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "not set"' "$settings")"
        echo "  Opus:    $(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "not set"' "$settings")"
        echo "  Haiku:   $(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "not set"' "$settings")"
      elif [[ -n "$api_key" ]]; then
        echo "Current: API usage billing"
      else
        echo "Current: claude.ai subscription"
      fi
      ;;

    add-key)
      printf "Enter your Anthropic API key: "
      read -rs key </dev/tty
      echo ""
      _cb_cred_store "anthropic-api-key" "$key"
      echo "API key saved"
      ;;

    config)
      _claude_billing_configure
      ;;

    *)
      echo "Usage: claude-billing [subscription|api|bedrock|status|config|add-key]"
      echo ""
      echo "  subscription  Use claude.ai subscription (Pro, Max, Teams, Enterprise)"
      echo "  api           Use Anthropic API key billing"
      echo "  bedrock       Use AWS Bedrock"
      echo "  status        Show current billing mode"
      echo "  config        Reconfigure Bedrock region and model IDs"
      echo "  add-key       Save your Anthropic API key to the credential store"
      ;;
  esac
}

_claude_billing_configure() {
  echo "=== claude-billing configuration ==="
  echo ""

  local default_region="${CLAUDE_BILLING_REGION:-us-east-1}"
  printf "AWS region for Bedrock [%s]: " "$default_region"
  read -r region </dev/tty
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

  _claude_billing_pick_model() {
    local label="$1"
    local default="$2"
    local model_list="$3"

    if [[ -n "$model_list" ]]; then
      printf "Select %s model number (or type an ID) [%s]: " "$label" "$default"
    else
      printf "%s model ID [%s]: " "$label" "$default"
    fi
    read -r input </dev/tty

    if [[ -z "$input" ]]; then
      echo "$default"
    elif [[ "$input" =~ ^[0-9]+$ ]] && [[ -n "$model_list" ]]; then
      echo "$model_list" | sed -n "${input}p"
    else
      echo "$input"
    fi
  }

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
