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
    python3 tools/mutation/mutate.py --list       # show the mutant table

Sources are patched in place and restored from memory after each run,
so uncommitted edits in the worktree are safe. Exits non-zero if any
mutant survives, so it can gate a release branch.

This is a development tool, not part of CI: it rebuilds and re-runs the
suite once per mutant (~10s each).
"""
import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MUTANTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutants.json")
RESULTS_FILE = os.path.join(ROOT, "build", "mutation-results.json")


def run_suite(timeout=900):
    return subprocess.run(
        "swift test 2>&1", cwd=ROOT, shell=True, capture_output=True,
        text=True, timeout=timeout,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("filter", nargs="?", default="",
                        help="only run mutants whose path or label contains this")
    parser.add_argument("--list", action="store_true", help="list mutants and exit")
    args = parser.parse_args()

    mutants = [tuple(m) for m in json.load(open(MUTANTS_FILE))]
    if args.filter:
        mutants = [m for m in mutants
                   if args.filter in m[0] or args.filter in m[1]]
    if args.list:
        for path, label, _old, _new in mutants:
            print(f"{path:24} {label}")
        return 0
    if not mutants:
        print("no mutants matched", file=sys.stderr)
        return 1

    results = []
    for index, (path, label, old, new) in enumerate(mutants, 1):
        full = os.path.join(ROOT, "Sources", "tiled", path)
        source = open(full).read()
        if source.count(old) != 1:
            status = f"STALE(find x{source.count(old)})"
            print(f"[{index}/{len(mutants)}] {status}: {path} - {label}", flush=True)
            results.append(dict(path=path, label=label, status=status))
            continue

        # The original is restored from memory, not git: the tool works on a
        # dirty worktree and cannot clobber uncommitted edits to other files.
        open(full, "w").write(source.replace(old, new, 1))
        try:
            outcome = run_suite()
            output = outcome.stdout + outcome.stderr
            if "error:" in output and "Executed" not in output:
                status = "INVALID(compile)"
            else:
                status = "CAUGHT" if outcome.returncode != 0 else "SURVIVED"
        except subprocess.TimeoutExpired:
            status = "TIMEOUT"
        finally:
            open(full, "w").write(source)
        results.append(dict(path=path, label=label, status=status))
        print(f"[{index}/{len(mutants)}] {status}: {path} - {label}", flush=True)

    print("\n===== SUMMARY =====")
    for result in results:
        print(f"{result['status']:16} {result['path']:24} {result['label']}")
    scored = [r for r in results if r["status"] in ("CAUGHT", "SURVIVED")]
    caught = sum(1 for r in scored if r["status"] == "CAUGHT")
    survivors = [r for r in scored if r["status"] == "SURVIVED"]
    print(f"\nMutation score: {caught}/{len(scored)} valid mutants caught")
    for survivor in survivors:
        print(f"  SURVIVED: {survivor['path']} - {survivor['label']}")

    os.makedirs(os.path.dirname(RESULTS_FILE), exist_ok=True)
    json.dump(results, open(RESULTS_FILE, "w"), indent=2)
    print(f"Results: {os.path.relpath(RESULTS_FILE, ROOT)}")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
