#!/usr/bin/env bash
set -e

REPO_URL="https://raw.githubusercontent.com/hschin/claude-billing/main"
INSTALL_DIR="$HOME/.claude-billing"
FUNC_FILE="$INSTALL_DIR/claude_billing.sh"

detect_platform() {
  case "$(uname -s)" in
    Darwin)               echo "macos" ;;
    Linux)                echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)                    echo "unknown" ;;
  esac
}

detect_shell_rc() {
  local shell_name
  shell_name=$(basename "$SHELL")
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

check_deps() {
  local platform="$1"
  local missing=()

  command -v jq &>/dev/null || missing+=("jq")
  command -v aws &>/dev/null || missing+=("aws CLI (required for Bedrock)")

  case "$platform" in
    linux)
      command -v secret-tool &>/dev/null || missing+=("secret-tool (install: apt install libsecret-tools / dnf install libsecret)")
      ;;
    windows)
      echo "Note: on Git Bash, credentials are stored in ~/.claude-billing-credentials (chmod 600)"
      ;;
  esac

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Warning: the following dependencies are missing:"
    for dep in "${missing[@]}"; do
      echo "  - $dep"
    done
    echo ""
    case "$platform" in
      macos)   echo "Install jq with: brew install jq" ;;
      linux)   echo "Install jq with: apt install jq / dnf install jq / brew install jq" ;;
      windows) echo "Install jq with: winget install jqlang.jq (or via scoop/choco)" ;;
    esac
    echo "Install AWS CLI: https://aws.amazon.com/cli/"
    echo ""
  fi
}

PLATFORM=$(detect_platform)

echo "=== claude-billing installer ==="
echo "Platform: $PLATFORM"
echo ""

if [[ "$PLATFORM" == "unknown" ]]; then
  echo "Error: unsupported platform."
  exit 1
fi

check_deps "$PLATFORM"

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

# Source the function so we can call configure
# shellcheck source=/dev/null
source "$FUNC_FILE"

# Platform-specific API key setup
echo ""
echo -n "Do you want to save your Anthropic API key now? [y/N]: "
read -r save_key
if [[ "$save_key" =~ ^[Yy]$ ]]; then
  echo -n "Enter your Anthropic API key: "
  read -rs key
  echo ""
  _cb_cred_store "anthropic-api-key" "$key"
  echo "API key saved"
fi

# Bedrock setup
echo ""
echo -n "Set up Bedrock models now? [y/N]: "
read -r setup_bedrock

if [[ "$setup_bedrock" =~ ^[Yy]$ ]]; then
  _claude_billing_configure
else
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
echo "  claude-billing subscription  # claude.ai subscription (Pro, Max, Teams, Enterprise)"
echo "  claude-billing api           # Anthropic API key billing"
echo "  claude-billing bedrock       # AWS Bedrock"
echo "  claude-billing status        # show current mode"
echo "  claude-billing config        # reconfigure Bedrock models"
echo "  claude-billing add-key       # save or update your Anthropic API key"
