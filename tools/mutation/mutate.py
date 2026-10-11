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
    python3 tools/mutation/mutate.py --list       # show the mutant table
    python3 tools/mutation/mutate.py --workers 2  # fewer workers (default 4)
    python3 tools/mutation/test_mutate.py         # the tool's own tests

The table runs in parallel copy-sandboxes: the master copies Sources,
Tests, and Package.swift into one scratch copy per worker, hands out
mutants as workers free up, and never touches the real tree, so
uncommitted edits are safe. Before fanning out it runs the unmutated
suite once; a red baseline aborts the run rather than scoring mutants.
Each worker rebuilds the mutated module (`swift build --build-tests`)
and then runs the suite (`swift test --skip-build`).

While a stage is in flight, `--since <its base commit>` (optionally with a
positional filter) keeps the run to the mutants the stage can affect; run
the full table once before committing.

Exits non-zero if any mutant survives or is unresolved, so it can gate
a release branch. This is a development tool, not part of CI: a full
84-mutant table takes ~3-4 minutes on the 8 GB M1 Air.
"""
import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MUTANTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutants.json")
RESULTS_FILE = os.path.join(ROOT, "build", "mutation-results.json")

DEFAULT_WORKERS = 4
STEP_TIMEOUT = 900
BUILD_COMMAND = ["swift", "build", "--build-tests"]
TEST_COMMAND = ["swift", "test", "--skip-build"]
PREFLIGHT_COMMAND = ["swift", "test"]
JUDGED_STATUSES = ("CAUGHT", "SURVIVED")


def run_command(command, cwd):
    return subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, timeout=STEP_TIMEOUT,
    )


def error_status(error):
    return f"ERROR({type(error).__name__})"


def changed_since(ref):
    """Mutation-table paths (relative to Sources/tiled) changed since ref.

    Covers tracked edits (staged or not) plus untracked files, because the
    tool runs mid-work, before the stage's commit exists.
    """
    def git(*argv):
        return subprocess.run(
            ["git", *argv], cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout

    paths = git("diff", "--name-only", ref)
    paths += git("ls-files", "--others", "--exclude-standard")
    prefix = os.path.join("Sources", "tiled") + "/"
    return {path[len(prefix):] for path in paths.splitlines()
            if path.startswith(prefix)}


def select_mutants(mutants, changed=None, filter=""):
    if changed is not None:
        mutants = [m for m in mutants if m[0] in changed]
    if filter:
        mutants = [m for m in mutants if filter in m[0] or filter in m[1]]
    return mutants


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
    source = open(target, encoding="utf-8").read()
    count = source.count(old)
    if count != 1:
        return f"STALE(find x{count})"
    open(target, "w", encoding="utf-8").write(source.replace(old, new, 1))
    return None


def create_sandbox(base, index, root=ROOT):
    """One worker's scratch copy of the build inputs."""
    sandbox = os.path.join(base, f"worker-{index + 1}")
    os.makedirs(sandbox)
    shutil.copytree(os.path.join(root, "Sources"), os.path.join(sandbox, "Sources"))
    shutil.copytree(os.path.join(root, "Tests"), os.path.join(sandbox, "Tests"))
    shutil.copy2(os.path.join(root, "Package.swift"), sandbox)
    return sandbox


def process_mutant(mutant, sandbox):
    """Judge one mutant in its sandbox; never raises.

    Each verdict comes from a pristine tree with exactly this mutant
    applied: the sandbox is reset first, then the mutant patched, then the
    module rebuilt and the suite run. The rebuild is as load-bearing as the
    reset — skipping it would silently run the previous mutant's binary.
    """
    try:
        reset_sandbox(sandbox)
        status = patch_sandbox(sandbox, mutant)
        if status is None:
            build = run_command(BUILD_COMMAND, sandbox)
            if build.returncode == 0:
                status = classify(run_command(TEST_COMMAND, sandbox))
            else:
                status = "INVALID(compile)"
    except subprocess.TimeoutExpired:
        status = "TIMEOUT"
    except Exception as error:
        status = error_status(error)
    return status


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
                        help="only run mutants whose source file changed since this git ref")
    parser.add_argument("--list", action="store_true", help="list mutants and exit")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"parallel worker count (default {DEFAULT_WORKERS})")
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be at least 1")

    with open(MUTANTS_FILE) as handle:
        mutants = [tuple(m) for m in json.load(handle)]
    changed = None
    if args.since:
        try:
            changed = changed_since(args.since)
        except subprocess.CalledProcessError as error:
            print(error.stderr.strip() or f"git could not diff {args.since}", file=sys.stderr)
            return 1
    mutants = select_mutants(mutants, changed, args.filter)
    if args.since and not mutants and not args.filter:
        print(f"no mutants to run: no mutation-table source changed since {args.since}")
        return 0
    if args.list:
        for path, label, _old, _new in mutants:
            print(f"{path:24} {label}")
        return 0
    if not mutants:
        print("no mutants matched", file=sys.stderr)
        return 1

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
    sandbox_base = tempfile.mkdtemp(prefix="tiled-mutants-")
    try:
        sandboxes = [create_sandbox(sandbox_base, slot) for slot in range(worker_count)]
        results = run_parallel(
            mutants, worker_count,
            lambda mutant, slot: process_mutant(mutant, sandboxes[slot]),
        )
    finally:
        shutil.rmtree(sandbox_base, ignore_errors=True)

    text, exit_code = summarize(results)
    print(text)
    os.makedirs(os.path.dirname(RESULTS_FILE), exist_ok=True)
    with open(RESULTS_FILE, "w") as handle:
        json.dump(results, handle, indent=2)
    print(f"Results: {os.path.relpath(RESULTS_FILE, ROOT)}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
