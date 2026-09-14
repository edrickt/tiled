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

# The host app only becomes frontmost if the app launching it is
# frontmost (macOS refuses programmatic activation from background
# processes). A probe earlier in the session can leave Finder or a
# browser frontmost; put the terminal back so the host activates
# naturally, exactly as it does when a human runs this script.
TERM_APP="${TERM_PROGRAM:-Terminal}"
[[ "$TERM_APP" == "Apple_Terminal" ]] && TERM_APP="Terminal"
[[ "$TERM_APP" == "iTerm.app" ]] && TERM_APP="iTerm"
open -a "$TERM_APP" 2>/dev/null || true
sleep 1

echo "==> Launching host windows"
build/host &
HOST_PID=$!
sleep 3

echo "==> Running $SUITE"
status=0
HOST_PID="$HOST_PID" build/focus-suite || status=$?

echo
echo "==> tiled log (prune/liveness/place lines)"
grep -aE 'DEBUG-lv|prune win|push win|applyLayout|drag-untile|dragend|ESCAPE|reflow' "$LOG" | tr -d '\r' \
    || echo "(no matching lines)"

exit $status
