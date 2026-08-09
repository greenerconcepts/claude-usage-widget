#!/bin/zsh
# Remove Claude Usage completely
osascript -e 'tell application "Claude Usage" to quit' 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
sleep 1
rm -rf "/Applications/Claude Usage.app"
defaults delete com.max.claudeusage 2>/dev/null || true
echo "Claude Usage removed."
