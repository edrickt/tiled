#!/bin/bash
# Runs one focus-loop repro suite against the dev build of Tiled.
#
# The installed /Applications/Tiled.app registers the same global hotkeys
# and manages the same windows, so it MUST be stopped: otherwise two
# window managers fight over every keystroke and every write, and the
# repro reads the wrong manager's state. This script kills it (and says
# so); nothing else about the user's windows changes.
#
# Usage: scripts/run-focus-loop.sh tools/repro/window-lifecycle-repro.swift
set -euo pipefail
cd "$(dirname "$0")/.."

SUITE="${1:?usage: scripts/run-focus-loop.sh <suite.swift>}"
LOG="build/focus-loop-tiled.log"

echo "==> Building tiled, host, and $SUITE"
swift build
mkdir -p build
swiftc -o build/host tools/repro/host-app.swift -framework AppKit
swiftc -o build/focus-suite -framework AppKit -framework ApplicationServices "$SUITE"

cleanup() {
    pkill -f '\.build/(debug|release)/tiled' 2>/dev/null || true
    pkill -x host 2>/dev/null || true
}
trap cleanup EXIT

# Exact process names only: a -f pattern can match this shell's own
# command line and kill the runner mid-flight.
if pgrep -x Tiled > /dev/null; then
    echo "==> Stopping /Applications/Tiled.app (it owns the same hotkeys; its in-memory state is lost)"
    pkill -x Tiled 2>/dev/null || true
fi
pkill -f '\.build/(debug|release)/tiled' 2>/dev/null || true
pkill -x host 2>/dev/null || true
rm -f "$LOG"
sleep 1
if pgrep -x Tiled > /dev/null || pgrep -x host > /dev/null || pgrep -f '\.build/(debug|release)/tiled' > /dev/null; then
    echo "FATAL: a window manager or host survived the pre-run kill" >&2
    exit 3
fi

# `script` gives tiled a pty so NSLog's stderr is line-buffered and a
# killed process cannot swallow the end of its debug output.
echo "==> Launching dev tiled (TILED_DEBUG log: $LOG)"
script -q /dev/null env TILED_DEBUG=1 NSUnbufferedIO=YES .build/debug/tiled > "$LOG" 2>&1 &
sleep 3

# The host launches as a minimal bundle via `open`: a plain CLI cannot
# make itself frontmost on modern macOS (NSRunningApplication.activate
# and the AX frontmost attribute are both refused), and an overlapped
# host window swallows the suite's focus clicks — the suite then clicks
# the covering window and the tile hotkey targets that instead. `open`
# is a LaunchServices user-intent request, so the host's windows come up
# above whatever else is on screen.
echo "==> Launching host windows"
HOST_APP=build/Host.app
rm -rf "$HOST_APP"
mkdir -p "$HOST_APP/Contents/MacOS"
cat > "$HOST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>host</string>
	<key>CFBundleDisplayName</key>
	<string>host</string>
	<key>CFBundleExecutable</key>
	<string>host</string>
	<key>CFBundleIdentifier</key>
	<string>dev.tiled.repro.host</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
cp build/host "$HOST_APP/Contents/MacOS/host"
open "$HOST_APP"
sleep 3
HOST_PID=$(pgrep -x host | head -1)

echo "==> Running $SUITE"
status=0
HOST_PID="$HOST_PID" build/focus-suite || status=$?

echo
echo "==> tiled log (prune/liveness/place lines)"
grep -aE 'DEBUG-lv|prune win|push win|applyLayout|drag-untile|dragend|ESCAPE|reflow' "$LOG" | tr -d '\r' \
    || echo "(no matching lines)"

exit $status
