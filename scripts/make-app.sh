#!/bin/bash
# Builds a release binary and bundles it as Tiled.app (menu bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

# VERSION is the single source of truth for the bundle version; a release
# tag is cut from it, so the app and the changelog cannot drift apart.
VERSION=$(tr -d '[:space:]' < VERSION)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must be MAJOR.MINOR.PATCH, got '$VERSION'" >&2
    exit 1
fi
# CFBundleVersion wants a monotonically increasing build number; derive one
# from the version so every release has a distinct value.
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }')

# UNIVERSAL=1 builds a fat binary for Apple Silicon and Intel, which is what
# a release ships. Local builds stay single-architecture because they are
# twice as fast and nobody is distributing them.
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=".build/apple/Products/Release/tiled"
else
    swift build -c release
    BINARY=".build/release/tiled"
fi

APP="build/Tiled.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Tiled"

# App icon: regenerate with scripts/make-icon.swift + iconutil if missing.
if [ ! -f Resources/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Tiled</string>
    <key>CFBundleIdentifier</key><string>dev.tiled.app</string>
    <key>CFBundleName</key><string>Tiled</string>
    <key>CFBundleDisplayName</key><string>Tiled</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed. https://github.com/edrickt/tiled</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
lipo -archs "$APP/Contents/MacOS/Tiled"
