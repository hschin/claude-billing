# claude-billing: switch Claude Code between billing modes (Pro, API, Bedrock)
# Config: ~/.claude-billing.conf
# Requires: jq, macOS Keychain (security), aws CLI (for Bedrock)

claude-billing() {
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
      key=$(security find-generic-password -s "anthropic-api-key" -a "$USER" -w 2>/dev/null)
      if [[ -z "$key" ]]; then
        echo "No Anthropic API key found in Keychain. Add it with:"
        echo "  security add-generic-password -s anthropic-api-key -a \"\$USER\" -w"
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

    pro)
      jq '
        .env |= (
          del(.CLAUDE_CODE_USE_BEDROCK) |
          del(.ANTHROPIC_API_KEY) |
          del(.ANTHROPIC_DEFAULT_SONNET_MODEL) |
          del(.ANTHROPIC_DEFAULT_OPUS_MODEL) |
          del(.ANTHROPIC_DEFAULT_HAIKU_MODEL)
        )' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
      _claude_billing_restore_oauth
      echo "Switched to Claude Pro plan — restart Claude Code to apply"
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
        echo "Current: Claude Pro plan"
      fi
      ;;

    config)
      _claude_billing_configure
      ;;

    *)
      echo "Usage: claude-billing [api|pro|bedrock|status|config]"
      echo ""
      echo "  api      Use Anthropic API key billing"
      echo "  pro      Use Claude Pro / Max subscription"
      echo "  bedrock  Use AWS Bedrock"
      echo "  status   Show current billing mode"
      echo "  config   Reconfigure Bedrock region and model IDs"
      ;;
  esac
}

_claude_billing_backup_oauth() {
  local oauth
  oauth=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null)
  if [[ -n "$oauth" ]]; then
    # Only overwrite backup if we have a live token to save — prevents clobbering a valid backup
    security add-generic-password -s "Claude Code-credentials-backup" -a "$USER" -w "$oauth" 2>/dev/null || \
      security add-generic-password -U -s "Claude Code-credentials-backup" -a "$USER" -w "$oauth" 2>/dev/null
    security delete-generic-password -s "Claude Code-credentials" -a "$USER" 2>/dev/null
  fi
}

_claude_billing_restore_oauth() {
  local backup
  backup=$(security find-generic-password -s "Claude Code-credentials-backup" -a "$USER" -w 2>/dev/null)
  if [[ -n "$backup" ]]; then
    security add-generic-password -s "Claude Code-credentials" -a "$USER" -w "$backup" 2>/dev/null || \
      security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$backup" 2>/dev/null
    security delete-generic-password -s "Claude Code-credentials-backup" -a "$USER" 2>/dev/null
    echo "Restored claude.ai OAuth token"
  else
    echo "No OAuth backup found — run 'claude /login' after launching Claude Code to authenticate with your Pro plan"
  fi
}

_claude_billing_configure() {
  echo "=== claude-billing configuration ==="
  echo ""

  # Region
  local default_region="${CLAUDE_BILLING_REGION:-us-east-1}"
  echo -n "AWS region for Bedrock [$default_region]: "
  read -r region
  region="${region:-$default_region}"

  # Fetch available Claude models from Bedrock
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
      echo -n "Select $label model number (or type an ID) [$default]: "
    else
      echo -n "$label model ID [$default]: "
    fi
    read -r input

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

  # Write config
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
