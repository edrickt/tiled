#!/usr/bin/env python3
"""Mutation testing for tiled's core engine.

The unit suite answers "does the code still work?". This answers the
harder question the suite cannot answer about itself: "would the suite
notice if the code stopped working?".

Each mutant in `mutants.json` is a small, semantically plausible bug
injected into `Sources/tiled`. A mutant is CAUGHT when the suite fails,
SURVIVED when the suite still passes. Survivors are test gaps: real
regressions that would ship green.

Usage:
    python3 tools/mutation/mutate.py              # all mutants
    python3 tools/mutation/mutate.py reflow       # only labels/paths matching
    python3 tools/mutation/mutate.py --since HEAD~2  # only files changed since a ref
    python3 tools/mutation/mutate.py --resume     # only mutants the last run did not catch
    python3 tools/mutation/mutate.py --list       # show the mutant table
    python3 tools/mutation/mutate.py --workers 2  # fewer workers (default 4-6 by core count)
    python3 tools/mutation/test_mutate.py         # the tool's own tests

The table runs in parallel copy-sandboxes under build/mutation-workers:
the master refreshes Sources, Tests, and Package.swift into one directory
per worker, hands out mutants as workers free up, and never touches the
real tree, so uncommitted edits are safe. The directories persist across
runs, so each worker's .build cache stays warm and only files changed
since the last run recompile. Before fanning out it runs the unmutated
suite once; a red baseline aborts the run rather than scoring mutants.
Each worker rebuilds the mutated module (`swift build --build-tests`,
with `--jobs` scaled down so workers don't oversubscribe the machine)
and then judges in two tiers: first the focused tests for the mutated
file (`swift test --skip-build --filter <FOCUSED_TESTS[file]>`), then
the full suite (`swift test --skip-build`) only when the focused run
does not catch. A focused failure implies a full-suite failure, so the
fast path never flips a verdict; it only skips redundant confirmations.

While a stage is in flight, `--since <its base commit>` (optionally with a
positional filter) keeps the run to the mutants the stage can affect. A
source change selects that file's mutants; a test or Package.swift change
puts every mutant in scope, because the suite itself moved. Add --resume
to recheck only the mutants the last run did not catch, which makes the
add-tests-to-kill-survivors loop skip the already-caught table. Resume
trusts a prior CAUGHT verdict unless its source file is in the `--since`
scope, so it is for adding tests: after changing or deleting an existing
test, run the full table so a weakened assertion cannot hide. Run the
full table once before committing.

Exits non-zero if any mutant survives or is unresolved, so it can gate
a release branch. This is a development tool, not part of CI: a warm run
of the full table takes a few minutes (roughly half the old wall time;
the first run after this tool or the sources change pays for cold
per-worker builds).
"""
import argparse
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MUTANTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutants.json")
RESULTS_FILE = os.path.join(ROOT, "build", "mutation-results.json")

SOURCE_PREFIX = "Sources/tiled/"
SUITE_PREFIX = "Tests/"
SUITE_FILES = ("Package.swift",)

# Measured on the 8 GB M1 Air: 4-6 workers run the table in the same wall
# time, while 8 workers are markedly slower (memory contention between
# parallel swiftc/test processes outweighs the extra parallelism).
DEFAULT_WORKERS = max(4, min(6, os.cpu_count() or 4))
STEP_TIMEOUT = 900
BUILD_COMMAND = ["swift", "build", "--build-tests"]
TEST_COMMAND = ["swift", "test", "--skip-build"]
PREFLIGHT_COMMAND = ["swift", "test"]
WORKER_BASE = os.path.join(ROOT, "build", "mutation-workers")

# Tier-1 `swift test --filter` regex per mutated source file: the test
# classes likely to catch its mutants. Anything tier-1 does not catch
# falls back to the full suite, so a missing class only costs speed,
# never a wrong verdict. Files not listed here default to their own
# basename stem (e.g. DragTracker.swift -> DragTrackerTests).
FOCUSED_TESTS = {
    "TilingSpace.swift": (
        "TilingSpace|TilingState|Reflow|Swap|Undo|Evict|Expand|"
        "SpaceIndependence|Minimum|Untiled|Mirror|Splitter|"
        "ScreenOwnership|Matrix|Reassert|WindowBirth|HideIcon|"
        "PerMonitor|Neighbour|ActionReceipt|ExpectedWrite|FakeGateway"
    ),
    "Layout.swift": (
        "Layout|Reflow|Swap|TilingSpace|TilingState|MenuModel|MenuText|"
        "Matrix|SpaceIndependence|Undo"
    ),
    "TilingController.swift": (
        "Controller|LidSleep|AXLiveness|Reassert|TilingState|GridLayout|"
        "Reflow|Swap|Evict|Minimum|Undo|StatusIcon|MenuReads|ActionReceipt"
    ),
    "LiveWindowGateway.swift": (
        "LiveGateway|AXConversion|AXFocus|AXLiveness|AXWrite|"
        "HandleIdentity|ObservationRegistry"
    ),
    "DragTracker.swift": "DragTracker|SplitterBackup",
    "FrameWriter.swift": "FrameWriter",
    "HotkeyService.swift": "HotkeyService|HotkeyRegistration|HotkeyBinding",
    "AppLaunchPlan.swift": "AppLaunchPlan|AppSettings",
    "CanvasDirectory.swift": "Canvas|ScreenOwnership",
    "HotkeyActionRouter.swift": "HotkeyActionRouter",
    "MenuBarPresenter.swift": "MenuBar|StatusIcon|AppDelegateMenu",
    "SettingsShortcutsTab.swift": "Shortcuts",
    "DisplaySpace.swift": "Display|PerMonitor|Screen",
    "StatusIcon.swift": "StatusIcon|MenuBar|AppDelegateMenu",
    "WindowRegister.swift": "WindowRegister",
    "MenuReads.swift": "MenuReads|AppDelegateMenu",
}
JUDGED_STATUSES = ("CAUGHT", "SURVIVED")


def run_command(command, cwd):
    return subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, timeout=STEP_TIMEOUT,
    )


def error_status(error):
    return f"ERROR({type(error).__name__})"


def classify_changes(paths):
    """Split git-reported paths into mutation sources and suite changes.

    A source change selects that file's mutants. A test or Package.swift
    change can move every verdict, so the caller puts the whole table in
    scope (resume may narrow it back to the mutants not yet caught).
    """
    sources = set()
    suite_changed = False
    for path in paths:
        if path.startswith(SOURCE_PREFIX):
            sources.add(path[len(SOURCE_PREFIX):])
        elif path.startswith(SUITE_PREFIX) or path in SUITE_FILES:
            suite_changed = True
    return sources, suite_changed


def changed_since(ref):
    """Changed mutation sources, plus whether the test suite moved.

    Covers tracked edits (staged or not) plus untracked files, because the
    tool runs mid-work, before the stage's commit exists.
    """
    def git(*argv):
        return subprocess.run(
            ["git", *argv], cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout

    paths = git("diff", "--name-only", ref)
    paths += git("ls-files", "--others", "--exclude-standard")
    return classify_changes(paths.splitlines())


def select_mutants(mutants, changed=None, filter=""):
    if changed is not None:
        mutants = [m for m in mutants if m[0] in changed]
    if filter:
        mutants = [m for m in mutants if filter in m[0] or filter in m[1]]
    return mutants


def resume_selection(mutants, previous, changed=()):
    """Drop mutants the previous run caught, unless their file changed."""
    caught = {(result.get("path"), result.get("label"))
              for result in previous
              if result.get("status") == "CAUGHT"}
    changed = set(changed)
    return [mutant for mutant in mutants
            if (mutant[0], mutant[1]) not in caught or mutant[0] in changed]


def select_for_run(mutants, filter="", changed=None, suite_changed=False,
                   resume=False, previous=()):
    """The mutants this invocation should judge.

    `changed` is the set of mutation source files changed since the caller's
    ref, or None when there is no ref. A suite change puts every mutant in
    scope because the tests themselves moved. Resume then drops the mutants
    the last run already caught, except those whose source file changed.
    """
    selected = select_mutants(mutants, filter=filter)
    if changed is not None and not suite_changed and not resume:
        selected = select_mutants(selected, changed=changed)
    if resume:
        selected = resume_selection(selected, previous, changed or set())
    return selected


def load_results(path=RESULTS_FILE):
    """Read the last run's verdicts; anything malformed is no cache at all."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    required = ("path", "label", "status")
    return [result for result in data
            if isinstance(result, dict)
            and all(key in result for key in required)]


def merge_results(previous, current, table):
    """Keep prior verdicts for mutants this run did not judge.

    `table` is the full mutant table, so removed entrants drop out and the
    merged file stays in table order.
    """
    merged = {(result["path"], result["label"]): result
              for result in previous}
    for result in current:
        merged[(result["path"], result["label"])] = result
    return [merged[(mutant[0], mutant[1])]
            for mutant in table
            if (mutant[0], mutant[1]) in merged]


def classify(test):
    """Turn the test run's result into a mutant verdict.

    A run the suite never reported on is not a verdict at all: a killed or
    crashed runner must fail the gate, never score as CAUGHT.
    """
    output = test.stdout + test.stderr
    if "Executed" not in output:
        return "INVALID(no-summary)"
    return "CAUGHT" if test.returncode != 0 else "SURVIVED"


def summarize(results):
    """The end-of-run report and exit code for a list of result dicts."""
    lines = ["\n===== SUMMARY ====="]
    for result in results:
        lines.append(f"{result['status']:16} {result['path']:24} {result['label']}")
    scored = [r for r in results if r["status"] in JUDGED_STATUSES]
    caught = sum(1 for r in scored if r["status"] == "CAUGHT")
    survivors = [r for r in scored if r["status"] == "SURVIVED"]
    unresolved = [r for r in results if r["status"] not in JUDGED_STATUSES]
    lines.append(f"\nMutation score: {caught}/{len(scored)} valid mutants caught")
    for survivor in survivors:
        lines.append(f"  SURVIVED: {survivor['path']} - {survivor['label']}")
    # An unrun mutant is not a survivor: a drifted target line, a compile
    # error, or a hang means the suite was never asked the question. That
    # must fail the gate, or the tool green-lights its own blindness.
    if unresolved:
        lines.append(f"\nUNRESOLVED ({len(unresolved)}): every mutant must run and be judged")
        for result in unresolved:
            lines.append(f"  {result['status']}: {result['path']} - {result['label']}")
    return "\n".join(lines), 1 if survivors or unresolved else 0


def reset_sandbox(sandbox, root=ROOT):
    """Bring the sandbox's sources back to the working tree's copies.

    A sandbox is reused across mutants; each verdict must be judged against
    an otherwise-pristine tree, or an earlier mutant's edits leak into it.
    `copytree` preserves mtimes, so the rebuild stays incremental.
    """
    shutil.copytree(
        os.path.join(root, "Sources"), os.path.join(sandbox, "Sources"),
        dirs_exist_ok=True,
    )


def patch_sandbox(sandbox, mutant):
    """Put one mutant into the sandbox's freshly reset copy of its file.

    Returns a status string when the target text cannot be applied, else None.
    """
    path, label, old, new = mutant
    target = os.path.join(sandbox, "Sources", "tiled", path)
    with open(target, encoding="utf-8") as handle:
        source = handle.read()
    count = source.count(old)
    if count != 1:
        return f"STALE(find x{count})"
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(source.replace(old, new, 1))
    return None


def focused_filter_for(path):
    """The tier-1 `swift test --filter` regex for a mutant's source file."""
    if path in FOCUSED_TESTS:
        return FOCUSED_TESTS[path]
    return re.escape(os.path.splitext(os.path.basename(path))[0])


def focused_test_command(path):
    """The tier-1 screen: only the mutated file's likely tests."""
    return [*TEST_COMMAND, "--filter", focused_filter_for(path)]


def create_sandbox(base, index, root=ROOT):
    """One worker's scratch copy of the build inputs.

    The directory persists across runs, so the worker's .build cache stays
    warm: only files changed since the last run recompile. Sources, Tests,
    and Package.swift are refreshed from the working tree every run (a
    stale file from another branch must never leak in); anything else the
    worker owns, notably .build, is left alone.
    """
    sandbox = os.path.join(base, f"worker-{index + 1}")
    if os.path.isdir(sandbox):
        for name in ("Sources", "Tests", "Package.swift"):
            target = os.path.join(sandbox, name)
            if os.path.isdir(target) and not os.path.islink(target):
                shutil.rmtree(target, ignore_errors=True)
            elif os.path.lexists(target):
                os.remove(target)
    else:
        os.makedirs(sandbox)
    shutil.copytree(os.path.join(root, "Sources"), os.path.join(sandbox, "Sources"))
    shutil.copytree(os.path.join(root, "Tests"), os.path.join(sandbox, "Tests"))
    shutil.copy2(os.path.join(root, "Package.swift"), sandbox)
    return sandbox


def process_mutant(mutant, sandbox, build_command=BUILD_COMMAND):
    """Judge one mutant in its sandbox; never raises.

    Each verdict comes from a pristine tree with exactly this mutant
    applied: the sandbox is reset first, then the mutant patched, then the
    module rebuilt and the suite run. The rebuild is as load-bearing as the
    reset — skipping it would silently run the previous mutant's binary.

    The suite runs in two tiers: the focused tests first, then the full
    suite only when the focused run does not catch. Returns (status,
    ran_full_suite); a build failure or stale target never reaches either
    tier, and a timeout reports TIMEOUT without a second tier (a hung
    focused run would hang the full one too).
    """
    ran_full_suite = False
    try:
        reset_sandbox(sandbox)
        status = patch_sandbox(sandbox, mutant)
        if status is None:
            build = run_command(build_command, sandbox)
            if build.returncode == 0:
                status = classify(run_command(focused_test_command(mutant[0]), sandbox))
                if status != "CAUGHT":
                    ran_full_suite = True
                    status = classify(run_command(TEST_COMMAND, sandbox))
            else:
                status = "INVALID(compile)"
    except subprocess.TimeoutExpired:
        status = "TIMEOUT"
    except Exception as error:
        status = error_status(error)
    return status, ran_full_suite


def preflight():
    """Run the unmutated suite once; returns (ok, detail)."""
    try:
        outcome = run_command(PREFLIGHT_COMMAND, ROOT)
    except subprocess.TimeoutExpired:
        return False, "the pre-flight suite timed out"
    if outcome.returncode == 0:
        return True, ""
    tail = (outcome.stdout + outcome.stderr).strip().splitlines()[-15:]
    return False, "\n".join(tail)


def report_line(completed, total, status, path, label):
    print(f"[{completed}/{total}] {status}: {path} - {label}", flush=True)


def run_parallel(mutants, workers, judge, report=report_line):
    """Hand mutants to `workers` slots as they free up.

    Returns the verdicts in table order, one result dict per mutant.
    """
    total = len(mutants)
    worker_count = min(workers, total)
    work = queue.Queue()
    for index, mutant in enumerate(mutants):
        work.put((index, mutant))
    results = {}
    lock = threading.Lock()
    completed = 0

    def run_slot(slot):
        nonlocal completed
        while True:
            try:
                index, mutant = work.get_nowait()
            except queue.Empty:
                return
            try:
                status = judge(mutant, slot)
            except Exception as error:  # a slot must never lose a mutant
                status = error_status(error)
            with lock:
                completed += 1
                results[index] = dict(path=mutant[0], label=mutant[1], status=status)
                report(completed, total, status, mutant[0], mutant[1])

    threads = [threading.Thread(target=run_slot, args=(slot,), daemon=True)
               for slot in range(worker_count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return [results[index] for index in range(total)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("filter", nargs="?", default="",
                        help="only run mutants whose path or label contains this")
    parser.add_argument("--since", metavar="REF", default="",
                        help="only run mutants whose source file changed since this git ref; "
                             "test or Package.swift changes put every mutant in scope")
    parser.add_argument("--resume", action="store_true",
                        help="only rerun mutants the last run did not catch; pair with "
                             "--since for changed sources, and run the full table after "
                             "weakening tests")
    parser.add_argument("--list", action="store_true", help="list mutants and exit")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"parallel worker count (default {DEFAULT_WORKERS})")
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be at least 1")

    with open(MUTANTS_FILE) as handle:
        table = [tuple(m) for m in json.load(handle)]
    previous = load_results()
    changed = None
    suite_changed = False
    if args.since:
        try:
            changed, suite_changed = changed_since(args.since)
        except subprocess.CalledProcessError as error:
            print(error.stderr.strip() or f"git could not diff {args.since}", file=sys.stderr)
            return 1
    candidates = select_mutants(table, filter=args.filter)
    mutants = select_for_run(
        table, filter=args.filter, changed=changed,
        suite_changed=suite_changed, resume=args.resume, previous=previous,
    )
    if args.list:
        for path, label, _old, _new in mutants:
            print(f"{path:24} {label}")
        return 0
    if not mutants:
        if not candidates:
            print("no mutants matched", file=sys.stderr)
            return 1
        if args.resume:
            print("nothing to resume: every mutant in scope was already caught")
            return 0
        if args.since:
            print(f"no mutants to run: no mutation-table source or test changed "
                  f"since {args.since}")
            return 0
        print("no mutants matched", file=sys.stderr)
        return 1
    if suite_changed:
        print(f"tests or Package.swift changed since {args.since}: "
              "every mutant is in scope", flush=True)
    if args.resume:
        skipped = len(candidates) - len(mutants)
        if previous:
            print(f"resume: {skipped} previously caught mutant(s) skipped", flush=True)
        else:
            print("resume: no previous results; nothing skipped", flush=True)

    ok, detail = preflight()
    if not ok:
        print("pre-flight: the unmutated suite is not green; "
              "aborting instead of scoring mutants", file=sys.stderr)
        if detail:
            print(detail, file=sys.stderr)
        return 1

    worker_count = min(args.workers, len(mutants))
    print(f"pre-flight: suite green; scoring {len(mutants)} mutants "
          f"with {worker_count} workers", flush=True)
    # Cap jobs per build so parallel cold builds fit in memory, but never
    # --jobs 1: a single job drops SwiftPM out of batch mode and turns a
    # one-file incremental rebuild from ~1s into a ~20s near-full rebuild.
    jobs = max(2, (os.cpu_count() or 4) // worker_count)
    build_command = [*BUILD_COMMAND, "--jobs", str(jobs)]
    os.makedirs(WORKER_BASE, exist_ok=True)
    sandboxes = [create_sandbox(WORKER_BASE, slot) for slot in range(worker_count)]
    full_suite_runs = [0]
    full_lock = threading.Lock()

    def judge(mutant, slot):
        status, ran_full_suite = process_mutant(mutant, sandboxes[slot], build_command)
        if ran_full_suite:
            with full_lock:
                full_suite_runs[0] += 1
        return status

    results = run_parallel(mutants, worker_count, judge)
    print(f"tiers: focused suite decided "
          f"{len(mutants) - full_suite_runs[0]}/{len(mutants)} mutants; "
          f"{full_suite_runs[0]} needed the full suite", flush=True)

    text, exit_code = summarize(results)
    print(text)
    partial = bool(args.resume or args.since or args.filter)
    stored = merge_results(previous, results, table) if partial else results
    if partial:
        caught = sum(1 for result in stored if result["status"] == "CAUGHT")
        unresolved = sum(1 for result in stored
                         if result["status"] not in JUDGED_STATUSES)
        line = f"Overall (last known): {caught}/{len(stored)} mutants caught"
        if unresolved:
            line += f", {unresolved} unresolved"
        print(line)
    os.makedirs(os.path.dirname(RESULTS_FILE), exist_ok=True)
    with open(RESULTS_FILE, "w") as handle:
        json.dump(stored, handle, indent=2)
    print(f"Results: {os.path.relpath(RESULTS_FILE, ROOT)}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
