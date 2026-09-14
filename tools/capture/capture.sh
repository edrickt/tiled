#!/bin/bash
# Captures the README's screenshots and GIFs from the real app.
#
# Every asset is scripted: scene-driver.swift presses the same global
# hotkeys and drags the same edges a person would, screencapture records
# the display, and mov2gif turns the recording into a GIF trimmed to the
# scene. Re-run this after UI changes and the assets update themselves.
#
# Needs: a logged-in GUI session, Accessibility permission for the
# terminal (System Settings → Privacy & Security → Accessibility), and a
# quiet desktop: the script hides other apps, relaunches Tiled between
# scenes, and moves the real cursor. Your apps are unhidden at the end.
#
# Usage: tools/capture/capture.sh [scene ...]     (default: every scene)

set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/assets
WORK=build/capture
mkdir -p "$OUT" "$WORK"

if pgrep -x Tiled > /dev/null; then
    echo "Quitting the installed Tiled: it owns the same global hotkeys." >&2
    pkill -x Tiled || true
    sleep 1
fi

echo "==> Building the capture tools"
swift build
swiftc -O -o build/demo-host tools/capture/demo-host.swift -framework AppKit
swiftc -O -o build/scene-driver tools/capture/scene-driver.swift -framework AppKit
swiftc -O -o build/veil tools/capture/veil.swift -framework AppKit
swiftc -O -o build/mov2gif tools/capture/mov2gif/main.swift
swiftc -O -o build/desktop tools/capture/desktop/main.swift

cleanup() {
    pkill -f '\.build/.*/tiled' 2>/dev/null || true
    pkill -f build/demo-host 2>/dev/null || true
    pkill -f 'build/cast/' 2>/dev/null || true
    build/veil restore "$WORK/veiled.json" || true
    if [[ -f "$WORK/wallpaper-original.png" ]]; then
        osascript -e "tell application \"System Events\" to set picture of every desktop to POSIX file \"$(cd "$WORK" && pwd)/wallpaper-original.png\"" > /dev/null 2>&1 || true
    fi
    echo "==> Restored your desktop and apps. The installed Tiled was quit for the run."
}
trap cleanup EXIT

echo "==> Hiding other apps for clean frames"
build/veil hide "$WORK/veiled.json"
sleep 1

# The captures must not carry whatever photo is on this machine's desktop.
# With every app hidden the screen is nothing but the wallpaper, so a
# screenshot of it is a faithful backup of the picture in use — even when
# the original file behind it has since been deleted. Restoring sets the
# backup, so this can never leave the desktop changed.
screencapture -x "$WORK/wallpaper-original.png"
build/desktop "$WORK/desktop.png" 2560 1600 > /dev/null
osascript -e "tell application \"System Events\" to set picture of every desktop to POSIX file \"$(cd "$WORK" && pwd)/desktop.png\"" > /dev/null 2>&1 || true
echo "==> Neutral desktop backdrop set (yours is restored at the end)"

# A fresh Tiled per scene: empty canvas, no history from the last take.
launch_tiled() {
    pkill -f '\.build/.*/tiled' 2>/dev/null || true
    sleep 0.8
    .build/debug/tiled > "$WORK/tiled.log" 2>&1 &
    sleep 3
}

launch_host() {
    local kind name
    pkill -f 'build/cast/' 2>/dev/null || true
    sleep 0.6
    mkdir -p build/cast
    # One process per mock app: Tiled's menu then lists "Editor",
    # "Terminal", … exactly as it lists real apps.
    for kind in $1; do
        case "$kind" in
        editor) name=Editor ;; terminal) name=Terminal ;; notes) name=Notes ;;
        files) name=Files ;; browser) name=Browser ;; music) name=Music ;;
        *) echo "unknown demo window: $kind" >&2; exit 2 ;;
        esac
        cp build/demo-host "build/cast/$name"
        "build/cast/$name" "$kind" > /dev/null 2>&1 &
        sleep 0.35
    done
    sleep 1.4
}

# scene <name> <host windows> <gif|png|both|none>
scene() {
    local name="$1" windows="$2" kind="$3"
    echo
    echo "==> Scene: $name"
    launch_tiled
    launch_host "$windows"

    if [[ "$kind" == "png" ]]; then
        # No recording: the driver leaves a surface (menu, Settings) open.
        build/scene-driver "$name" | tee "$WORK/$name.log"
        local frame
        frame=$(sed -n 's/^crop //p' "$WORK/$name.log" | tail -1)
        if [[ -z "$frame" ]]; then
            echo "no crop frame for $name; skipping" >&2
            return
        fi
        local label x y w h pad
        read -r label x y w h <<< "$frame"
        pad=22
        screencapture -x -R "$((x-pad)),$((y-pad)),$((w+2*pad)),$((h+2*pad))" "$OUT/$name.png"
        echo "wrote $OUT/$name.png ($(du -h "$OUT/$name.png" | cut -f1))"
        return
    fi

    build/scene-driver "$name" --out "$WORK/$name.mov" | tee "$WORK/$name.log"
    local start end
    start=$(sed -n 's/^start=//p' "$WORK/$name.mov.timeline")
    end=$(sed -n 's/^end=//p' "$WORK/$name.mov.timeline")

    if [[ "$kind" == "gif" || "$kind" == "both" ]]; then
        # Trim the lead-in and tail the recorder needed, and keep the
        # frame count modest: a README should stay light.
        build/mov2gif "$WORK/$name.mov" "$OUT/$name.gif" \
            --start "$(awk -v s="$start" 'BEGIN { printf "%.2f", s - 0.45 }')" \
            --end "$(awk -v e="$end" 'BEGIN { printf "%.2f", e - 0.45 }')" \
            --width 1024 --fps 10
        echo "wrote $OUT/$name.gif ($(du -h "$OUT/$name.gif" | cut -f1))"
    fi
    if [[ "$kind" == "png" || "$kind" == "both" ]]; then
        # The scene's final state, minus the menu bar: the same region the
        # recorder used, so stills and GIFs frame the desktop identically.
        local geometry
        geometry=$(swift -e 'import AppKit
let s = NSScreen.main!
print("\(Int(s.frame.width)) \(Int(s.frame.height)) \(Int(s.frame.maxY - s.visibleFrame.maxY))")')
        local screenWidth screenHeight menuBar
        read -r screenWidth screenHeight menuBar <<< "$geometry"
        screencapture -x -R "0,$menuBar,$screenWidth,$((screenHeight - menuBar))" "$WORK/$name-final.png"
        sips --resampleWidth 1600 "$WORK/$name-final.png" --out "$OUT/$name.png" > /dev/null
        echo "wrote $OUT/$name.png ($(du -h "$OUT/$name.png" | cut -f1))"
    fi
}

ALL=(quarters sixths resize expand evict undo menu guide shortcuts)
SCENES=("$@")
if [[ ${#SCENES[@]} -eq 0 ]]; then SCENES=("${ALL[@]}"); fi

for name in "${SCENES[@]}"; do
    case "$name" in
    quarters) scene quarters "editor terminal notes files" gif ;;
    sixths)   scene sixths "editor terminal browser notes music files" gif ;;
    thirds)   scene thirds "editor terminal notes" gif ;;
    resize)   scene resize "editor terminal" gif ;;
    expand)   scene expand "editor terminal notes files" gif ;;
    evict)    scene evict "editor notes terminal" gif ;;
    undo)     scene undo "editor terminal notes files browser" gif ;;
    menu)     scene menu "editor terminal notes files" png ;;
    guide)    scene guide "editor" png ;;
    shortcuts) scene shortcuts "editor" png ;;
    *) echo "unknown scene: $name" >&2; exit 2 ;;
    esac
done

echo
echo "==> Assets in $OUT"
ls -lh "$OUT" | tail -n +2
