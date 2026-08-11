#!/bin/zsh
# Builds ClaudeUsage.app — a tiny native menu bar + floating panel widget
set -e
cd "$(dirname "$0")"

APP=build/ClaudeUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.max.claudeusage</string>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O Sources/main.swift \
    -o "$APP/Contents/MacOS/ClaudeUsage" \
    -framework AppKit -framework CoreServices -framework ServiceManagement

codesign --force --sign - "$APP"
echo "Built $APP"
