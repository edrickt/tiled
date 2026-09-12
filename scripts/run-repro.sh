#!/bin/bash
# Runs the live end-to-end repro suite against the real Accessibility API.
#
# The unit suite (swift test) runs everywhere and exercises the pure engine
# through the fake gateway. This script runs the other half: the real
# adapter, real windows, real global hotkeys. It needs what that implies:
#
#   * a logged-in GUI session (window server reachable, no ssh-only shell)
#   * Accessibility permission for the terminal that runs this script
#     (tiled cannot tile what it cannot see; System Settings → Privacy &
#     Security → Accessibility)
#   * a quiet desktop: the suite clicks and drags real windows, so your
#     own windows will move while it runs
#
# Usage: scripts/run-repro.sh [suite.swift]
#        defaults to tools/repro/suite.swift (the full suite);
#        tools/repro/driver.swift is the smaller focused driver.
set -euo pipefail
cd "$(dirname "$0")/.."

SUITE="${1:-tools/repro/suite.swift}"
if [[ ! -f "$SUITE" ]]; then
    echo "No such suite: $SUITE" >&2
    exit 1
fi

if [[ ! -t 0 && -z "${CI:-}" ]]; then
    echo "warning: no tty; the repro suite drives the real cursor and windows" >&2
fi

echo "==> Building tiled and the throwaway host windows"
swift build
mkdir -p build
swiftc -o build/host tools/repro/host-app.swift -framework AppKit

cleanup() {
    [[ -n "${HOST_PID:-}" ]] && kill "$HOST_PID" 2>/dev/null || true
    [[ -n "${TILED_PID:-}" ]] && kill "$TILED_PID" 2>/dev/null || true
}
trap cleanup EXIT

# A second instance would fight over the global hotkeys, and a stale host
# app would hand the suite the wrong windows: it drives the host whose pid
# it was given, while the window manager tiles whatever is focused.
pkill -f '\.build/(debug|release)/tiled' 2>/dev/null || true
pkill -f 'build/host' 2>/dev/null || true
sleep 1

echo "==> Launching tiled (grant Accessibility permission when prompted)"
.build/debug/tiled &
TILED_PID=$!
sleep 3

echo "==> Launching host windows"
build/host &
HOST_PID=$!
sleep 3

echo "==> Running $SUITE"
status=0
# HOST_PID lets the suite find exactly the host it launched, never a
# leftover instance with the same window titles.
HOST_PID="$HOST_PID" swift "$SUITE" || status=$?

if [[ $status -ne 0 ]]; then
    echo
    echo "Repro suite failed. If every case failed, check Accessibility"
    echo "permission for this terminal before suspecting the engine."
fi
exit $status
