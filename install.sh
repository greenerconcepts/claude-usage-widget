#!/bin/zsh
# Build from source and install Claude Usage to /Applications
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools first:"
  echo "  xcode-select --install"
  exit 1
fi

./build.sh

osascript -e 'tell application "Claude Usage" to quit' 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
sleep 1
rm -rf "/Applications/Claude Usage.app"
cp -R build/ClaudeUsage.app "/Applications/Claude Usage.app"
open "/Applications/Claude Usage.app"

echo ""
echo "✳ Claude Usage installed and running."
echo "  • Panel is docked bottom-left; drag it anywhere, stretch its edges."
echo "  • Menu bar sparkle → Start at Login to keep it around."
echo "  • For the per-model gauge: sign in once with the Claude Code CLI"
echo "    (run: claude), then menu bar sparkle → Refresh Now and click"
echo "    'Always Allow' on the Keychain prompt."
