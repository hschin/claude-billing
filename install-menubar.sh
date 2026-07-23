#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/hschin/claude-billing/main"
APP_DIR="$HOME/Applications/Claude Billing.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/ClaudeBillingMenuBar"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.hschin.claude-billing-menubar.plist"
LAUNCH_LABEL="com.hschin.claude-billing-menubar"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "claude-billing: the menu bar app requires macOS" >&2
  exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  rm -rf "$APP_DIR"
  echo "Removed Claude Billing from the menu bar and login items."
  exit 0
fi

if [[ ! -f "$HOME/.claude-billing/claude_billing.sh" ]]; then
  echo "claude-billing: install the command-line utility before the menu bar app" >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "claude-billing: Swift compiler not found; install Xcode Command Line Tools" >&2
  exit 1
fi

script_dir=""
if script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); then
  :
fi
local_source="$script_dir/menubar/Sources/ClaudeBillingMenuBar/main.swift"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-billing-menubar.XXXXXX")
temporary_app="$temporary_dir/Claude Billing.app"
source_file="$local_source"

cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

if [[ ! -f "$source_file" ]]; then
  source_file="$temporary_dir/ClaudeBillingMenuBar.swift"
  echo "Downloading menu bar app source..."
  curl -fsSL "$REPO_URL/menubar/Sources/ClaudeBillingMenuBar/main.swift" -o "$source_file"
fi

mkdir -p "$temporary_app/Contents/MacOS"
echo "Building Claude Billing menu bar app..."
swiftc -O -target "$(uname -m)-apple-macosx13.0" -framework AppKit "$source_file" \
  -o "$temporary_app/Contents/MacOS/ClaudeBillingMenuBar"

cat > "$temporary_app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ClaudeBillingMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.hschin.claude-billing-menubar</string>
  <key>CFBundleName</key>
  <string>Claude Billing</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$temporary_app" >/dev/null
fi

mkdir -p "$(dirname "$APP_DIR")" "$(dirname "$LAUNCH_AGENT")"
rm -rf "$APP_DIR"
mv "$temporary_app" "$APP_DIR"

xml_executable=$(printf '%s' "$APP_EXECUTABLE" | sed \
  -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
  -e 's/"/\&quot;/g' -e "s/'/\&apos;/g")
cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$xml_executable</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"

echo "Installed Claude Billing in the menu bar. It will start automatically when you log in."
echo "Uninstall only the menu bar app with:"
echo "  claude-billing menubar uninstall"
