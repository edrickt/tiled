# security, packaging, scripts, CI — audit findings

## Summary (≤3 sentences)
The four shell scripts are genuinely well built — `set -euo pipefail` everywhere, every expansion quoted, no temp files, no unquoted `rm -rf`, no sudo, and kill patterns scoped to processes the harness itself launched. The real issues are ordering and scope: `install-app.sh` destroys the installed app *before* it knows the replacement builds (F1), the "one window manager only" guards miss a dev instance launched outside the literal `.build/debug|release/tiled` path (F2), and one repro probe defaults to a destructive action on an arbitrary pid (F3). CI is minimal but real: it gates the debug unit suite only — the shipped release bundle path is never built, and the action/ permissions hygiene is loose (F4–F8).

## Findings

### F1 — install-app.sh removes the installed app before it knows the new one builds [Medium | High | design-risk]
- Location: `scripts/install-app.sh:22-30`
- Evidence:
```
    rm -rf "/Applications/Tiled.app"
fi

./scripts/make-app.sh

cp -R "build/Tiled.app" "/Applications/Tiled.app"
```
  (the header at `:2-4` presents this order as a feature: "removes the installed app first, then builds and installs a fresh copy — nothing is replaced in place.")
- Trigger: user has Tiled installed and running; run `./scripts/install-app.sh` while the working tree has any compile error (or the toolchain is missing) → `:10` pkills the running instance, `:25` deletes `/Applications/Tiled.app`, then `:28` runs `make-app.sh` whose `swift build -c release` (`make-app.sh:6`) fails and `set -e` (`:5`) aborts the script.
- Impact: the user is left with **no** installed app, no running manager, and their windows still tiled by the process that was just killed — no menu bar item exists to untile them until the build is fixed and reinstalled. `make-app.sh` itself gets this right (`swift build` at `:6` precedes `rm -rf "$APP"` at `:9`), so the safe order is already established in the sibling script.
- Fix: build first, then swap: `./scripts/make-app.sh` → `rm -rf "/Applications/Tiled.app"` → `cp -R "build/Tiled.app" "/Applications/Tiled.app"`. (Optionally `ditto`/`mv` from a temp path for an atomic swap.)

### F2 — the "second window manager" guard misses dev instances launched outside `.build/debug|release/tiled` [Medium | Medium | test-gap]
- Location: `scripts/run-repro.sh:36-39,56` and `scripts/run-focus-loop.sh:31-39`
- Evidence:
```
pkill -f '\.build/(debug|release)/tiled' 2>/dev/null || true      # run-repro.sh:56
```
```
if pgrep -x Tiled > /dev/null; then                              # run-focus-loop.sh:31
    echo "==> Stopping /Applications/Tiled.app (it owns the same hotkeys; its in-memory state is lost)"
    pkill -x Tiled 2>/dev/null || true
fi
pkill -f '\.build/(debug|release)/tiled' 2>/dev/null || true      # run-focus-loop.sh:35
```
- Trigger: a dev `tiled` is already running that was **not** launched as the literal relative path `.build/debug/tiled` — e.g. the README's recommended loop (`swift run`, `README.md:176`), which execs `.build/<triple>/debug/tiled` (`arm64-apple-macosx`/`x86_64-apple-macosx`), or a binary launched by absolute path. The regex requires `.build/` immediately followed by `debug/` or `release/`, so it cannot match `.build/arm64-apple-macosx/debug/tiled`; and `pgrep -x Tiled` is an exact, case-sensitive regex match on the process name, so it does not match a process named `tiled`. The pre-run verification at `run-focus-loop.sh:39` uses the same three patterns and therefore also passes.
- Impact: two managers answer the same global hotkeys while the live suite runs — the exact condition both scripts exist to prevent, and which `README.md:227-229` states makes "every case lie". The live suite is the pre-release gate for the AX adapter (`README.md:212-213`), so the failure mode is a green-looking run for the wrong reason. Confidence is Medium only because the `swift run` argv detail is inferred, not executed.
- Fix: add `pgrep -x tiled`/`pgrep -f '(^|/)tiled$'`-style checks for the dev binary name (process name `tiled`) alongside the `.build/...` path pattern, and abort with the same `exit 3` used at `run-repro.sh:39`; or match the pattern `\.build/[^/]*/?(debug|release)/tiled|\.build/(debug|release)/tiled`.

### F3 — destroy-notification-probe.swift defaults to closing a real window of any pid you hand it [Medium | High | security]
- Location: `tools/repro/destroy-notification-probe.swift:12-13,37,92-97`
- Evidence:
```
//   close (default): press the first window's AX close button, then wait
//   kill: SIGKILL the whole process, then wait
...
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "close"
...
} else if let close = attr(victim, kAXCloseButtonAttribute as CFString) {
    print("pressing close button")
    let err = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
```
  (`:94` is `kill(pid, SIGKILL)` in the other branch.) `README.md:234` documents `destroy-notification-probe.swift <pid> [close|kill]` and `README.md:247-248` advertises it "for any app (host app: ~3ms; Firefox: ~29ms)".
- Trigger: `swift tools/repro/destroy-notification-probe.swift <pid-of-a-real-app>` — the mode argument omitted, which is the default in the documented usage — followed by the tool pressing that app's first AX close button (`⌘W`-equivalent) or SIGKILLing the whole process.
- Impact: silent destruction of user state in an arbitrary app (a browser tab with a filled form, a Terminal window, an editor buffer) as the *default* behaviour of a measurement probe, and SIGKILL of any pid the operator names. Blast radius is set entirely by the caller with no confirmation, no echo of "I am about to close window X of app Y" before acting, and `README.md` actively encourages pointing it at a third-party app.
- Fix: require the mode argument (`guard CommandLine.arguments.count > 2 else { print("usage: … <pid> <close|kill>"); exit(1) }`), and print the victim app name + window title with an explicit "closing it now" line before the action; default to a read-only report of the target's windows.

### F4 — CI never builds the release configuration or the app bundle, so the shipped artifact path is ungated [Medium | High | test-gap]
- Location: `.github/workflows/tests.yml:21-25`
- Evidence:
```
      - name: Build
        run: swift build --build-tests
      - name: Unit tests
        run: swift test
```
  The only release build in the repo is `scripts/make-app.sh:6` (`swift build -c release`); the bundle's `Info.plist` (`:20-35`) and signature (`:38`) are produced only there.
- Trigger: any change that breaks only the release configuration or the packaging path (e.g. a release-only compile error, a mangled `Info.plist` heredoc, a `codesign` failure) — `swift build -c release` and `./scripts/make-app.sh` are never executed by CI.
- Impact: the workflow README calls "the gate for every change" (`README.md:261`) covers only the debug build of the library/tests; the artifact that users actually install (`install-app.sh` → `make-app.sh`) has no automated check at all, so a broken bundle is discovered only by hand at install time. The repo's stronger documented gates (the live suite, `README.md:212`, and `python3 tools/mutation/mutate.py`, which "can gate a release branch", `README.md:256-260`) are also local-only by design — `ls .github/workflows` shows `tests.yml` is the only workflow.
- Fix: add a step `swift build -c release` (cheap, catches `-O`/release-only failures) and, ideally, `./scripts/make-app.sh && codesign --verify --deep --strict build/Tiled.app && plutil -lint build/Tiled.app/Contents/Info.plist`.

### F5 — CI uses a mutable action tag and grants default workflow permissions [Low | High | security]
- Location: `.github/workflows/tests.yml:16` (and the absence of a `permissions:` key anywhere in the file, verified by reading all 40 lines)
- Evidence:
```
      - uses: actions/checkout@v4
```
- Trigger: the `actions/checkout` v4 tag is moved upstream, or the action is compromised; the job runs with the repository's default `GITHUB_TOKEN` scopes because no `permissions:` block narrows them.
- Impact: supply-chain exposure on every push/PR for a job that only needs `contents: read` and never writes to the repo.
- Fix: pin `actions/checkout` to a commit SHA and add `permissions: contents: read` at the job (or workflow) level; optionally add a `concurrency: {group: ${{ github.ref }}, cancel-in-progress: true}` group (none exists today, so rapid pushes each start a full macOS job — `timeout-minutes: 20` is already set at `:14`).

### F6 — the coverage step can never fail and hides a second full test run [Low | High | test-gap]
- Location: `.github/workflows/tests.yml:31-40`
- Evidence:
```
          swift test --enable-code-coverage >/dev/null 2>&1 || true
          BIN=.build/debug/tiledPackageTests.xctest/Contents/MacOS/tiledPackageTests
          PROF=.build/debug/codecov/default.profdata
          if [[ -f "$BIN" && -f "$PROF" ]]; then
            xcrun llvm-cov report "$BIN" -instr-profile="$PROF" \
              -ignore-filename-regex='(Tests|\.build)' | tail -30
          fi
```
- Trigger: the instrumented build path changes (SwiftPM layout/`.build` symlink change, package or product rename), or the instrumented `swift test` run fails while the plain run at `:25` passed (nondeterminism, coverage-only crash).
- Impact: the step stays green and prints nothing (a bash `if` with no `else` returns 0), so coverage silently stops being reported and the hidden second test run's output is sent to `/dev/null` — the failure is invisible in the log. `if: always()` (`:32`) is fine for report-only behaviour, but combined with `|| true` it means no signal at all when the instrumented run breaks.
- Fix: drop `>/dev/null 2>&1` (log the run), keep `|| true` if coverage must not gate, and add an explicit `else echo "::warning::coverage profile missing; check the test bundle path"` so a vanished report is visible.

### F7 — the runner image and toolchain are never asserted; only the declared minimum against a newer runner is exercised [Low | Medium | test-gap]
- Location: `.github/workflows/tests.yml:13,18-19` and `Package.swift:6`
- Evidence:
```
    runs-on: macos-14
...
      - name: Swift version
        run: swift --version
```
  with `platforms: [.macOS(.v13)],` (`Package.swift:6`) and `Requires a recent Swift toolchain (tested with Swift 6.2)` (`README.md:161`).
- Trigger: any reliance on the runner's default Xcode/Swift or on architecture-specific behaviour. The `macos-14` label is a mutable image (x86_64 for the standard, non-arm64 label), its default toolchain is not the Swift 6.2 the README claims was tested, and no step asserts the version it got — `swift --version` is printed and ignored.
- Impact: the shipped arm64 slice (the platform most users of a macOS window manager are on) is never built or tested in CI, and a toolchain-version-dependent failure can only appear as an unexplained red run. The compile-time side is mitigated — the deployment target from `Package.swift:6` forces availability checks, and the only macOS 14 API use is guarded (`Sources/tiled/NSApplication+Activate.swift:11` `if #available(macOS 14.0, *)`) — so this is a coverage gap, not a known defect.
- Fix: run a second matrix entry on an arm64 label (`macos-14-arm64`/`macos-15`) or `swift-actions/setup-swift` with an explicit version, and make the version step assert (`swift --version | grep -q '6\.2'`-style) rather than print.

### F8 — install-app.sh's pkill is unprotected under `set -e` [Low | High | code-defect]
- Location: `scripts/install-app.sh:8-12` (compare `:17`)
- Evidence:
```
if pgrep -fq "Tiled.app/Contents/MacOS/Tiled"; then
    echo "Quitting running Tiled…"
    pkill -f "Tiled.app/Contents/MacOS/Tiled"
    sleep 1
fi
```
  while the next block does carry the guard: `pkill -f "\.build/(debug|release)/tiled" || true` (`:17`).
- Trigger: the app exits between the `pgrep` at `:8` and the `pkill` at `:10` (user quits it, or the app crashes, in that microsecond window) → `pkill` returns 1.
- Impact: `set -e` (`:5`) aborts the script immediately after printing "Quitting running Tiled…"; no error is shown and the app is **not** installed or launched — a silent partial failure that reads like success.
- Fix: `pkill -f "Tiled.app/Contents/MacOS/Tiled" || true` (matching the sibling block at `:17`).

### F9 — the bundle is deleted without unregistering a Launch-at-Login registration [Low | Low | design-risk]
- Location: `scripts/install-app.sh:25` and `Sources/tiled/SettingsGeneralTab.swift:212`
- Evidence:
```
    rm -rf "/Applications/Tiled.app"            # install-app.sh:25
...
                try SMAppService.mainApp.register()      # SettingsGeneralTab.swift:212
```
- Trigger: user enables "Launch at login" (`SettingsGeneralTab.swift:212`), then runs `./scripts/install-app.sh`, which deletes the registered bundle without `SMAppService.mainApp.unregister()`.
- Impact: RISK — the login-item registration outlives the bundle it points at, leaving the user's Login Items entry to be reconciled by macOS (stale/not-found item, or a login-time complaint) after every reinstall. Same family as the ad-hoc signature note: `make-app.sh:38` re-signs ad-hoc on each build, so the TCC grant (and any identity-keyed registration) is invalidated every rebuild — the README documents the TCC half (`README.md:180-183`) but not the login-item half. I could not verify SMAppService's behaviour for a deleted bundle statically, hence Low confidence.
- Fix: in `install-app.sh`, `osascript -e 'tell application "System Events" to delete login item "Tiled"'`-equivalent or document/print the unregister step before `rm -rf`; or gate the install script on Launch-at-Login being off.

### F10 — cleanup is armed for EXIT only [Low | Low | design-risk]
- Location: `scripts/run-repro.sh:47-51`, `scripts/run-focus-loop.sh:24-27`
- Evidence:
```
cleanup() {
    [[ -n "${HOST_PID:-}" ]] && kill "$HOST_PID" 2>/dev/null || true
    [[ -n "${TILED_PID:-}" ]] && kill "$TILED_PID" 2>/dev/null || true
}
trap cleanup EXIT
```
- Trigger: the script is terminated by a signal whose path does not run the EXIT trap (SIGKILL, closed terminal, or SIGTERM if bash does not run the EXIT trap there — I could not verify bash's behaviour for this statically, hence Low confidence), leaving `.build/debug/tiled` and `build/host` alive.
- Impact: leaked processes hold the global hotkeys, which is exactly the two-manager condition the pre-run checks exist to prevent; the next run can then lie (see F2). No SIGINT/TERM/HUP trap is installed in either script.
- Fix: `trap cleanup EXIT INT TERM HUP` and use process-group kills (`set -m`/`kill -- -$PID`, or `pkill -P`) so children of the launcher die with it.

### F11 — README drift: bundle name case and CI trigger claim [Low | High | doc-gap]
- Location: `README.md:166`, `README.md:261` vs `scripts/make-app.sh:8`, `.github/workflows/tests.yml:4-5`
- Evidence:
```
./scripts/make-app.sh # release build bundled as build/tiled.app   # README.md:166
CI (`.github/workflows/tests.yml`) runs the unit suite on every push and PR.   # README.md:261
APP="build/Tiled.app"                                              # make-app.sh:8
  push:
    branches: [master]                                             # tests.yml:4-5
```
- Trigger: following the README on a case-sensitive volume (`build/tiled.app` does not exist), or relying on "every push" while pushing a non-master branch without a PR (CI never runs: only `master` pushes and PRs are triggered).
- Impact: small but exactly the kind of drift that costs a reader a debugging session; the shipped bundle is `Tiled.app`, and CI is master/PR only.
- Fix: correct both sentences (`build/Tiled.app`; "on every push to `master` and on every pull request").

### F12 — the committed icon is only regenerated when missing [Low | High | design-risk]
- Location: `scripts/make-app.sh:13-18`
- Evidence:
```
if [ ! -f Resources/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
```
- Trigger: edit `scripts/make-icon.swift` (or the logo it shares with `scripts/make-logo.swift`), then rebuild — the bundled icon is the stale tracked `Resources/AppIcon.icns`, since the guard only fires when the file is absent.
- Impact: the one committed binary in the repo (the only file matched by `find '**/*.{icns,png,…}'`) can silently diverge from the code that generates it, with no way to refresh except deleting the tracked file by hand; nothing in CI compares them.
- Fix: regenerate unconditionally (the render is a few hundred ms) or add a `--refresh-icon` flag plus a CI check that regenerating leaves the file unchanged.

## Verified-clean areas (what I checked and why it held)
- **Shell robustness of the four scripts.** `set -euo pipefail` in all four (`install-app.sh:5`, `make-app.sh:3`, `run-repro.sh:18`, `run-focus-loop.sh:11`) and a fatal-if-failed `cd "$(dirname "$0")/.."` (`:6`/`:4`/`:19`/`:12`). I read every expansion line: all are double-quoted (`"$SUITE"`, `"$LOG"`, `"$APP"`, `"$TERM_APP"`, `"$HOST_PID"`), so no word splitting or glob injection; `run-repro.sh:21-24` validates the suite path and exits 1; `run-focus-loop.sh:14` uses `${1:?usage…}`. `rm -rf` is used only on fixed literals (`make-app.sh:9` with `APP` set at `:8`; `install-app.sh:25`), never on a glob or unquoted variable.
- **No temp-file or TOCTOU surface.** No script creates a temp file, so `mktemp` vs predictable-name is moot; the only `/tmp` references are read-only log paths in manual probes (`evict-watch.swift:20,111`, `evict-drag-test.swift:14`, `probe-applevel.swift:8`) whose content the operator creates by redirection. No lockfiles, no PID files, no `flock`.
- **make-icon.swift / make-logo.swift are safe writers.** Their only writes are `createDirectory(atPath: outDir…)` and `data.write(to: "\(outDir)/\(entry.name)")` with fixed file names, into a caller-supplied directory (`make-icon.swift:14-15,163-167`; `make-logo.swift:15,154-158`). The path component comes only from `argv[1]`; no filename is attacker-controlled, so there is no traversal or overwrite of user data — the worst case is junk PNGs in a directory the caller chose.
- **The packaged app can run, and its Info.plist matches the code.** `CFBundleExecutable` `Tiled` (`make-app.sh:25`) names the copied binary (`:11`), `LSUIElement` true (`:31`) matches `app.setActivationPolicy(.accessory)` (`Sources/tiled/main.swift:4`), `CFBundleIconFile` `AppIcon` (`:33`) matches the copied `AppIcon.icns` (`:18`), bundle id/version are present (`:26,29-30`). No `Bundle.main`, `Bundle(...)`, or `NSImage(named:)` appears anywhere in `Sources`, so nothing depends on bundle resources and the plain `NSApplication` loop (`main.swift:3-7`) is enough. The missing `LSMinimumSystemVersion` is not a defect: the deployment target comes from `Package.swift:6` at compile time and the only macOS 14+ API is `#available`-guarded (`NSApplication+Activate.swift:11`).
- **Scoped killing in the live harnesses.** `run-repro.sh` refuses to run at all while the installed app is live (`:36-39`, `exit 3`), and `run-focus-loop.sh` passes the pid of the host *it* launched as `HOST_PID`; `window-lifecycle-repro.swift:73-78` requires `HOST_PID` (fatalError otherwise) and SIGKILLs only that pid (`:199`) after verifying it is the focused app. No script kills apps by friendly name, touches `killall`, or kills anything owned by another user.
- **CI does gate the unit suite.** `.git/HEAD` is `refs/heads/master`, matching `tests.yml:5`; the workflow is the only one under `.github/workflows`; the coverage step's `if: always()` cannot mask a test failure because the job status includes the failed `swift test` step; `timeout-minutes: 20` is present (`:14`); the bundle path at `:35` matches a package named `tiled` with a `tiledTests` target (`Package.swift:5,12-13`).
- **No secrets, no committed build products beyond the intended icon.** Case-insensitive repo-wide search for private-key headers, `ghp_`/`github_pat_`/`AKIA`, "api key", "secret", "password" returned nothing; `find` for `.env/.pem/.p12/.mobileprovision/.key` found none; the only binary is `Resources/AppIcon.icns` (deliberate, referenced by `make-app.sh:18`); `.build/` and `build/` are ignored (`.gitignore:2-3`), and `Package.swift` declares no third-party dependency, so no `Package.resolved` is needed.

## Residual uncertainty (what static reading cannot decide)
- **File modes.** I cannot read exec bits with the available tools; `README.md:166,179,217` and `install-app.sh` usage all assume `scripts/*.sh` are executable. Verify with `ls -l scripts` / `git ls-files -s scripts`.
- **F2's precondition** — that `swift run` execs `.build/<triple>/debug/tiled` rather than the `.build/debug` symlink — is inferred, not executed; the regex gap for an absolute triple path launch is certain, the `swift run` case follows from it.
- **F9** — SMAppService semantics for a deleted bundle, and whether an ad-hoc signature (`make-app.sh:38`) is sufficient for `SMAppService.mainApp.register()` to succeed at all, need a live check; the graceful in-app failure path (`SettingsGeneralTab.swift:217-223`) means a failure would be visible to the user, not silent.
- **F10** — whether bash runs an EXIT trap for SIGTERM is not something static reading decides; the SIGKILL/closed-terminal cases leak regardless.
- **F7** — GitHub-hosted image details (x86_64 for the standard `macos-14` label, its current default Xcode/Swift, and its retirement schedule) change over time and could not be verified from the repo.
- **Branch protection** — whether a green CI run is *required* to merge is a GitHub setting, not repo content; the workflow itself gates only pushes to `master` and PRs.
- **`Resources/AppIcon.icns`** — it is a binary; I could not determine its size or whether it is currently consistent with `scripts/make-icon.swift` (finding F12 assumes drift is possible, not that it has occurred).
- **Cross-slice note (not my target):** `tools/mutation/mutate.py:74-85` rewrites `Sources/**` in place and restores from memory in a `finally`; per the audit rules I ran no build, test, or git command, and nothing in this report depends on the worktree being clean.