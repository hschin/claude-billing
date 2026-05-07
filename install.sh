#!/usr/bin/env bash
set -e

REPO_URL="https://raw.githubusercontent.com/hschin/claude-billing/main"
INSTALL_DIR="$HOME/.claude-billing"
FUNC_FILE="$INSTALL_DIR/claude_billing.sh"

# Detect shell rc file
detect_shell_rc() {
  local shell_name
  shell_name=$(basename "$SHELL")
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

# Check dependencies
check_deps() {
  local missing=()
  command -v jq &>/dev/null      || missing+=("jq")
  command -v security &>/dev/null || missing+=("security (macOS only)")
  command -v aws &>/dev/null      || missing+=("aws CLI (required for Bedrock)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Warning: the following dependencies are missing:"
    for dep in "${missing[@]}"; do
      echo "  - $dep"
    done
    echo ""
    echo "Install jq with: brew install jq"
    echo "Install AWS CLI: https://aws.amazon.com/cli/"
    echo ""
  fi
}

echo "=== claude-billing installer ==="
echo ""

# macOS only
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: claude-billing currently requires macOS (uses Keychain for credential storage)."
  exit 1
fi

check_deps

# Download function file
mkdir -p "$INSTALL_DIR"
echo "Downloading claude_billing.sh..."
curl -fsSL "$REPO_URL/claude_billing.sh" -o "$FUNC_FILE"
chmod 644 "$FUNC_FILE"

# Add source line to shell rc
RC_FILE=$(detect_shell_rc)
SOURCE_LINE="source \"$FUNC_FILE\"  # claude-billing"

if grep -q "claude-billing" "$RC_FILE" 2>/dev/null; then
  echo "claude-billing already present in $RC_FILE — skipping."
else
  echo "" >> "$RC_FILE"
  echo "$SOURCE_LINE" >> "$RC_FILE"
  echo "Added to $RC_FILE"
fi

# Run initial configuration
echo ""
echo "Now let's configure your Bedrock models."
echo "(Press Enter to skip Bedrock setup — you can run 'claude-billing config' later.)"
echo ""
echo -n "Set up Bedrock models now? [y/N]: "
read -r setup_bedrock

# Source the function so we can call configure
# shellcheck source=/dev/null
source "$FUNC_FILE"

if [[ "$setup_bedrock" =~ ^[Yy]$ ]]; then
  _claude_billing_configure
else
  # Write a minimal config with empty values so the function doesn't error
  cat > "$HOME/.claude-billing.conf" <<EOF
CLAUDE_BILLING_REGION=""
CLAUDE_BILLING_SONNET=""
CLAUDE_BILLING_OPUS=""
CLAUDE_BILLING_HAIKU=""
EOF
  echo "Skipped. Run 'claude-billing config' whenever you're ready."
fi

echo ""
echo "Installation complete!"
echo ""
echo "Reload your shell:"
echo "  source $RC_FILE"
echo ""
echo "Usage:"
echo "  claude-billing pro      # Claude Pro / Max subscription"
echo "  claude-billing api      # Anthropic API key billing"
echo "  claude-billing bedrock  # AWS Bedrock"
echo "  claude-billing status   # Show current mode"
echo "  claude-billing config   # Reconfigure Bedrock models"
