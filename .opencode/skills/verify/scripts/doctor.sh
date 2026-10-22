#!/bin/bash
# Read-only preflight for a live Tiled verification run.
# Usage: ./.opencode/skills/verify/scripts/doctor.sh
set -uo pipefail
cd "$(dirname "$0")/../../../.."

failures=0
warnings=0
ok() { printf 'OK   %s\n' "$*"; }
note() { printf 'WARN %s\n' "$*"; warnings=$((warnings + 1)); }
bad() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

if [ -x scripts/run-repro.sh ] && [ -f tools/repro/host-app.swift ]; then
    ok "Tiled checkout at $(pwd)"
else
    bad "not the Tiled checkout: $(pwd) has no scripts/run-repro.sh"
fi

if command -v swift >/dev/null 2>&1; then
    ok "Swift toolchain: $(swift --version 2>&1 | head -1)"
else
    bad "no swift on PATH; install a Swift toolchain"
fi

# Live suites drive the real cursor and need a desktop session.
manager=$(launchctl managername 2>/dev/null || echo unknown)
console_user=$(stat -f%Su /dev/console 2>/dev/null || echo unknown)
if [ "$manager" = "Aqua" ] && [ "$console_user" != "root" ]; then
    ok "GUI session (Aqua, console user $console_user)"
else
    bad "no GUI session (launchctl managername=$manager, console user=$console_user); live suites need a logged-in desktop"
fi

# Accessibility permission is attributed to the terminal that runs opencode.
probe=build/verification/ax-trust
if [ ! -x "$probe" ]; then
    mkdir -p build/verification
    printf 'import ApplicationServices\nprint(AXIsProcessTrusted())\n' > "$probe.swift"
    if ! swiftc -o "$probe" "$probe.swift" -framework ApplicationServices >/dev/null 2>&1; then
        bad "could not build the AX trust probe"
    fi
fi
if [ -x "$probe" ]; then
    if [ "$("$probe" 2>/dev/null)" = "true" ]; then
        ok "Accessibility trust for this terminal"
    else
        bad "Accessibility trust missing: System Settings -> Privacy & Security -> Accessibility, add the app running opencode, then retry"
    fi
fi

if pgrep -x Tiled >/dev/null 2>&1; then
    note "/Applications/Tiled.app is running (pid $(pgrep -x Tiled | tr '\n' ' ')); quit it before run-repro.sh, or let run-focus-loop.sh stop it (in-memory layout state is lost)"
else
    ok "installed Tiled.app is not running"
fi

if pgrep -f '\.build/(debug|release)/tiled' >/dev/null 2>&1; then
    note "a dev tiled is already running: $(pgrep -fl '\.build/(debug|release)/tiled' | tr '\n' ' ')"
else
    ok "no dev tiled process"
fi

if pgrep -x host >/dev/null 2>&1; then
    note "a host window app is already running (pid $(pgrep -x host | tr '\n' ' ')); a second one hands the suite the wrong windows"
else
    ok "no stale host app"
fi

echo
echo "Space table (read-only):"
if ! swift tools/repro/probe-spaces.swift 2>&1; then
    note "probe-spaces.swift failed; treat Space-dependent results as unverified"
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "NOT DRIVABLE: $failures failure(s), $warnings warning(s)"
    exit 1
fi
echo "DRIVABLE: 0 failures, $warnings warning(s)"
