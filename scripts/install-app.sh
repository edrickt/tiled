#!/bin/bash
# Builds Tiled.app (release) and installs it into /Applications.
# Quits any running instance, builds first, and only then replaces the
# installed copy: a failed build must never leave the user without the
# app that is currently tiling their windows.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -fq "Tiled.app/Contents/MacOS/Tiled"; then
    echo "Quitting running Tiled…"
    pkill -f "Tiled.app/Contents/MacOS/Tiled" || true
    sleep 1
fi

# A running instance also holds the debug binary's menu slot; clear it too.
if pgrep -fq "\.build/(debug|release)/tiled"; then
    echo "Quitting dev-build Tiled…"
    pkill -f "\.build/(debug|release)/tiled" || true
    sleep 1
fi

# Build first. The old app stays installed until the replacement exists,
# so a compile error aborts with the user's window manager untouched.
./scripts/make-app.sh

if [ -d "/Applications/Tiled.app" ]; then
    echo "Removing /Applications/Tiled.app…"
    rm -rf "/Applications/Tiled.app"
fi

cp -R "build/Tiled.app" "/Applications/Tiled.app"
echo "Installed /Applications/Tiled.app"

open "/Applications/Tiled.app"
echo "Launched. Grant Accessibility permission on first run when prompted."
