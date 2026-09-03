#!/bin/bash
# Builds a release binary and bundles it as Tiled.app (menu bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Tiled.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/tiled "$APP/Contents/MacOS/tiled"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>tiled</string>
    <key>CFBundleIdentifier</key><string>dev.tiled.app</string>
    <key>CFBundleName</key><string>tiled</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP"
