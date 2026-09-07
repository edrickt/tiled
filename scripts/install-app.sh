#!/bin/bash
# Builds Tiled.app (release) and installs it into /Applications,
# replacing any previous copy. Quits a running instance first so the
# bundle isn't replaced out from under it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

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

rm -rf "/Applications/Tiled.app"
cp -R "build/Tiled.app" "/Applications/Tiled.app"
echo "Installed /Applications/Tiled.app"

open "/Applications/Tiled.app"
echo "Launched. Grant Accessibility permission on first run when prompted."
