#!/bin/bash
# Builds Tiled.app (release) and installs it into /Applications.
# Quits any running instance, removes the installed app first, then
# builds and installs a fresh copy — nothing is replaced in place.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -fq "Tiled.app/Contents/MacOS/Tiled"; then
    echo "Quitting running Tiled…"
    pkill -f "Tiled.app/Contents/MacOS/Tiled"
    sleep 1
fi

# A running instance also holds the debug binary's menu slot; clear it too.
if pgrep -fq "\.build/(debug|release)/tiled"; then
    echo "Quitting dev-build Tiled…"
    pkill -f "\.build/(debug|release)/tiled" || true
    sleep 1
fi

# Remove the installed app up front: the install is always from
# scratch, never an in-place bundle replacement.
if [ -d "/Applications/Tiled.app" ]; then
    echo "Removing /Applications/Tiled.app…"
    rm -rf "/Applications/Tiled.app"
fi

./scripts/make-app.sh

cp -R "build/Tiled.app" "/Applications/Tiled.app"
echo "Installed /Applications/Tiled.app"

open "/Applications/Tiled.app"
echo "Launched. Grant Accessibility permission on first run when prompted."
