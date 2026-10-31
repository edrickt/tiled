#!/usr/bin/env python3
"""Tests for the mutation gate's bookkeeping and scheduling logic.

Run: python3 tools/mutation/test_mutate.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mutate


MUTANTS = [
    ("TilingSpace.swift", "swap write-home deleted", "a", "b"),
    ("Layout.swift", "grid rounds down", "c", "d"),
    ("DragTracker.swift", "escape tolerance widened", "e", "f"),
]


class SelectMutantsTests(unittest.TestCase):
    def test_no_filters_returns_the_whole_table(self):
        self.assertEqual(mutate.select_mutants(MUTANTS), MUTANTS)

    def test_filter_matches_label(self):
        self.assertEqual(
            mutate.select_mutants(MUTANTS, filter="grid rounds"),
            [MUTANTS[1]],
        )

    def test_filter_matches_path(self):
        self.assertEqual(
            mutate.select_mutants(MUTANTS, filter="DragTracker"),
            [MUTANTS[2]],
        )

    def test_changed_limits_to_files_changed_since_ref(self):
        self.assertEqual(
            mutate.select_mutants(MUTANTS, changed={"Layout.swift"}),
            [MUTANTS[1]],
        )


class ClassifyChangesTests(unittest.TestCase):
    def test_a_source_change_selects_that_file(self):
        sources, suite_changed = mutate.classify_changes([
            "Sources/tiled/TilingSpace.swift",
            "README.md",
        ])
        self.assertEqual(sources, {"TilingSpace.swift"})
        self.assertFalse(suite_changed)

    def test_a_test_change_puts_every_mutant_in_scope(self):
        sources, suite_changed = mutate.classify_changes([
            "Tests/tiledTests/LayoutTests.swift",
        ])
        self.assertEqual(sources, set())
        self.assertTrue(suite_changed)

    def test_a_package_change_puts_every_mutant_in_scope(self):
        _sources, suite_changed = mutate.classify_changes(["Package.swift"])
        self.assertTrue(suite_changed)

    def test_nested_source_paths_are_kept_relative_to_the_module(self):
        sources, _suite_changed = mutate.classify_changes([
            "Sources/tiled/Sub/Thing.swift",
            "Sources/tiled/Other.swift",
        ])
        self.assertEqual(sources, {"Sub/Thing.swift", "Other.swift"})


def mutant(path, label, status):
    return dict(path=path, label=label, status=status)


PREVIOUS = [
    mutant("TilingSpace.swift", "swap write-home deleted", "CAUGHT"),
    mutant("Layout.swift", "grid rounds down", "SURVIVED"),
]


class SelectForRunTests(unittest.TestCase):
    def test_a_source_change_selects_only_that_file(self):
        self.assertEqual(
            mutate.select_for_run(MUTANTS, changed={"Layout.swift"}),
            [MUTANTS[1]],
        )

    def test_a_test_change_puts_every_mutant_in_scope(self):
        self.assertEqual(
            mutate.select_for_run(MUTANTS, changed=set(), suite_changed=True),
            MUTANTS,
        )

    def test_resume_skips_mutants_the_last_run_caught(self):
        self.assertEqual(
            mutate.select_for_run(MUTANTS, resume=True, previous=PREVIOUS),
            [MUTANTS[1], MUTANTS[2]],
        )

    def test_resume_reruns_a_caught_mutant_in_a_changed_file(self):
        self.assertEqual(
            mutate.select_for_run(
                MUTANTS, changed={"TilingSpace.swift"}, resume=True,
                previous=PREVIOUS,
            ),
            MUTANTS,
        )

    def test_resume_after_a_test_change_rechecks_only_the_uncaught(self):
        self.assertEqual(
            mutate.select_for_run(
                MUTANTS, changed=set(), suite_changed=True, resume=True,
                previous=PREVIOUS,
            ),
            [MUTANTS[1], MUTANTS[2]],
        )

    def test_a_filter_still_applies_before_resume(self):
        self.assertEqual(
            mutate.select_for_run(
                MUTANTS, filter="TilingSpace", resume=True,
                previous=PREVIOUS,
            ),
            [],
        )


class MergeResultsTests(unittest.TestCase):
    def test_skipped_mutants_keep_their_previous_verdicts(self):
        current = [mutant("Layout.swift", "grid rounds down", "CAUGHT")]
        merged = mutate.merge_results(PREVIOUS, current, MUTANTS)
        self.assertEqual(
            [(result["path"], result["status"]) for result in merged],
            [("TilingSpace.swift", "CAUGHT"), ("Layout.swift", "CAUGHT")],
        )

    def test_a_new_verdict_replaces_the_previous_one(self):
        current = [mutant("Layout.swift", "grid rounds down", "CAUGHT")]
        merged = mutate.merge_results(PREVIOUS, current, MUTANTS)
        self.assertEqual(
            [result["status"] for result in merged if result["path"] == "Layout.swift"],
            ["CAUGHT"],
        )

    def test_entries_no_longer_in_the_table_are_dropped(self):
        previous = [mutant("Gone.swift", "removed", "CAUGHT")]
        self.assertEqual(mutate.merge_results(previous, [], MUTANTS), [])


class LoadResultsTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="mutate-test-")
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)

    def test_a_missing_file_is_empty(self):
        self.assertEqual(
            mutate.load_results(os.path.join(self.base, "missing.json")),
            [],
        )

    def test_a_malformed_file_is_empty(self):
        path = os.path.join(self.base, "bad.json")
        with open(path, "w") as handle:
            handle.write("{not json")
        self.assertEqual(mutate.load_results(path), [])

    def test_a_verdict_without_its_fields_is_dropped(self):
        path = os.path.join(self.base, "partial.json")
        with open(path, "w") as handle:
            handle.write('[{"path": "A.swift"}, {"path": "B.swift", '
                         '"label": "two", "status": "CAUGHT"}]')
        self.assertEqual(
            mutate.load_results(path),
            [mutant("B.swift", "two", "CAUGHT")],
        )


def completed(returncode=0, output=""):
    return subprocess.CompletedProcess([], returncode, output, "")


class ClassifyTests(unittest.TestCase):
    def test_failing_suite_is_caught(self):
        self.assertEqual(
            mutate.classify(completed(1, "Executed 655 tests, with 3 failures")),
            "CAUGHT",
        )

    def test_passing_suite_survives(self):
        self.assertEqual(
            mutate.classify(completed(0, "Executed 655 tests, with 0 failures")),
            "SURVIVED",
        )

    def test_a_suite_that_never_reported_is_invalid(self):
        # a killed or crashed runner must never score as CAUGHT
        for output in ("signal: killed", "error: test bundle missing"):
            self.assertEqual(
                mutate.classify(completed(1, output)),
                "INVALID(no-summary)",
            )


class SummarizeTests(unittest.TestCase):
    def test_all_caught_exits_zero(self):
        text, code = mutate.summarize([
            mutant("A.swift", "one", "CAUGHT"),
            mutant("B.swift", "two", "CAUGHT"),
        ])
        self.assertEqual(code, 0)
        self.assertIn("Mutation score: 2/2 valid mutants caught", text)

    def test_survivor_fails_and_is_listed(self):
        text, code = mutate.summarize([
            mutant("A.swift", "one", "CAUGHT"),
            mutant("B.swift", "two", "SURVIVED"),
        ])
        self.assertEqual(code, 1)
        self.assertIn("  SURVIVED: B.swift - two", text)

    def test_unresolved_fails_and_is_listed(self):
        text, code = mutate.summarize([
            mutant("A.swift", "one", "STALE(find x0)"),
        ])
        self.assertEqual(code, 1)
        self.assertIn("UNRESOLVED (1): every mutant must run and be judged", text)
        self.assertIn("STALE(find x0): A.swift - one", text)


class RunParallelTests(unittest.TestCase):
    def test_every_mutant_is_processed_once_and_results_keep_table_order(self):
        processed = []
        reports = []

        def process(mutant, slot):
            processed.append(mutant)
            return "CAUGHT"

        results = mutate.run_parallel(
            MUTANTS, 3, process, report=lambda *args: reports.append(args))
        self.assertEqual(sorted(processed), sorted(MUTANTS))
        self.assertEqual([r["path"] for r in results], [m[0] for m in MUTANTS])
        self.assertEqual(len(reports), len(MUTANTS))

    def test_never_opens_more_slots_than_there_are_mutants(self):
        slots = set()

        def process(mutant, slot):
            slots.add(slot)
            return "CAUGHT"

        mutate.run_parallel(MUTANTS, 8, process, report=lambda *args: None)
        self.assertTrue(slots)
        self.assertTrue(slots <= {0, 1, 2})

    def test_a_slot_exception_becomes_an_error_status(self):
        def process(mutant, slot):
            raise RuntimeError("boom")

        results = mutate.run_parallel(
            MUTANTS, 2, process, report=lambda *args: None)
        self.assertTrue(all(r["status"] == "ERROR(RuntimeError)" for r in results))


class PatchSandboxTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="mutate-test-")
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.root = os.path.join(self.base, "root")
        self.sandbox = os.path.join(self.base, "sandbox")
        for base in (self.root, self.sandbox):
            os.makedirs(os.path.join(base, "Sources", "tiled"))
        self.write(self.root, "Thing.swift", "let value = 1")
        self.write(self.root, "Other.swift", "let other = 7")
        self.write(self.sandbox, "Thing.swift", "let value = 1")
        self.write(self.sandbox, "Other.swift", "let other = 7")

    def write(self, base, name, text):
        path = os.path.join(base, "Sources", "tiled", name)
        with open(path, "w") as handle:
            handle.write(text)

    def read(self, base, name):
        path = os.path.join(base, "Sources", "tiled", name)
        with open(path) as handle:
            return handle.read()

    def test_applies_the_mutation_to_the_sandbox_only(self):
        status = mutate.patch_sandbox(
            self.sandbox,
            ("Thing.swift", "value bumped", "let value = 1", "let value = 2"),
        )
        self.assertIsNone(status)
        self.assertEqual(self.read(self.sandbox, "Thing.swift"), "let value = 2")
        self.assertEqual(self.read(self.root, "Thing.swift"), "let value = 1")

    def test_stale_target_text_reports_the_count(self):
        status = mutate.patch_sandbox(
            self.sandbox,
            ("Thing.swift", "value bumped", "let value = 9", "let value = 2"),
        )
        self.assertEqual(status, "STALE(find x0)")

    def test_a_previous_mutants_file_does_not_leak_into_the_next_verdict(self):
        # regression: a sandbox is reused across mutants, so the next mutant
        # must be judged against the working tree, not the last mutant's tree
        mutate.patch_sandbox(
            self.sandbox,
            ("Thing.swift", "value bumped", "let value = 1", "let value = 2"),
        )
        mutate.reset_sandbox(self.sandbox, root=self.root)
        mutate.patch_sandbox(
            self.sandbox,
            ("Other.swift", "offset bumped", "let other = 7", "let other = 9"),
        )
        self.assertEqual(self.read(self.sandbox, "Thing.swift"), "let value = 1")
        self.assertEqual(self.read(self.sandbox, "Other.swift"), "let other = 9")


class FocusedFilterTests(unittest.TestCase):
    def test_listed_files_use_their_table_entry(self):
        self.assertIn("Reflow", mutate.focused_filter_for("TilingSpace.swift"))

    def test_unlisted_files_default_to_their_basename_stem(self):
        self.assertEqual(mutate.focused_filter_for("Sub/Thing.swift"), "Thing")

    def test_default_stem_escapes_regex_characters(self):
        self.assertEqual(mutate.focused_filter_for("Foo+Bar.swift"), r"Foo\+Bar")

    def test_focused_command_appends_the_filter_to_the_test_command(self):
        self.assertEqual(
            mutate.focused_test_command("DragTracker.swift"),
            ["swift", "test", "--skip-build", "--filter",
             mutate.focused_filter_for("DragTracker.swift")],
        )


class CreateSandboxTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="mutate-test-")
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.root = os.path.join(self.base, "root")
        os.makedirs(os.path.join(self.root, "Sources"))
        os.makedirs(os.path.join(self.root, "Tests"))
        self.write_root(os.path.join("Sources", "A.swift"), "a")
        self.write_root(os.path.join("Tests", "B.swift"), "b")
        self.write_root("Package.swift", "p")
        self.workers = os.path.join(self.base, "workers")

    def write_root(self, name, text):
        path = os.path.join(self.root, name)
        with open(path, "w") as handle:
            handle.write(text)

    def test_first_run_populates_the_inputs(self):
        sandbox = mutate.create_sandbox(self.workers, 0, root=self.root)
        for name in (os.path.join("Sources", "A.swift"),
                      os.path.join("Tests", "B.swift"), "Package.swift"):
            self.assertTrue(os.path.isfile(os.path.join(sandbox, name)))

    def test_second_run_refreshes_inputs_but_keeps_the_build_cache(self):
        sandbox = mutate.create_sandbox(self.workers, 0, root=self.root)
        os.makedirs(os.path.join(sandbox, ".build"))
        with open(os.path.join(sandbox, ".build", "cache"), "w") as handle:
            handle.write("warm")
        with open(os.path.join(sandbox, "Sources", "stale.swift"), "w") as handle:
            handle.write("stale")
        os.remove(os.path.join(self.root, "Sources", "A.swift"))
        self.write_root(os.path.join("Sources", "C.swift"), "c")
        self.assertEqual(
            mutate.create_sandbox(self.workers, 0, root=self.root), sandbox)
        self.assertFalse(
            os.path.exists(os.path.join(sandbox, "Sources", "stale.swift")))
        self.assertFalse(
            os.path.exists(os.path.join(sandbox, "Sources", "A.swift")))
        self.assertTrue(
            os.path.isfile(os.path.join(sandbox, "Sources", "C.swift")))
        self.assertTrue(
            os.path.isfile(os.path.join(sandbox, ".build", "cache")))


class ProcessMutantTiersTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="mutate-test-")
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.sandbox = os.path.join(self.base, "sandbox")
        os.makedirs(os.path.join(self.sandbox, "Sources", "tiled"))
        self.write_sandbox("let value = 1")
        self.commands = []
        self.plan = {}
        # reset copies the real tree; these tests only need the patch step
        self._reset = mutate.reset_sandbox
        mutate.reset_sandbox = lambda sandbox, root=mutate.ROOT: None
        self.addCleanup(setattr, mutate, "reset_sandbox", self._reset)
        self._run = mutate.run_command
        mutate.run_command = self.fake_run_command
        self.addCleanup(setattr, mutate, "run_command", self._run)

    def write_sandbox(self, text):
        path = os.path.join(self.sandbox, "Sources", "tiled", "Thing.swift")
        with open(path, "w") as handle:
            handle.write(text)

    def fake_run_command(self, command, cwd):
        self.commands.append(command)
        if command[1] == "build":
            return self.plan["build"]
        if "--filter" in command:
            return self.plan["focused"]
        return self.plan["full"]

    def mutant(self):
        return ("Thing.swift", "value bumped", "let value = 1", "let value = 2")

    def caught(self):
        return completed(1, "Executed 10 tests, with 1 failure")

    def survived(self):
        return completed(0, "Executed 10 tests, with 0 failures")

    def built(self):
        return completed(0, "Build complete!")

    def test_focused_catch_never_runs_the_full_suite(self):
        self.plan = {"build": self.built(), "focused": self.caught(),
                     "full": self.survived()}
        self.assertEqual(
            mutate.process_mutant(self.mutant(), self.sandbox), ("CAUGHT", False))
        self.assertEqual(len(self.commands), 2)
        self.assertIn("--filter", self.commands[1])

    def test_focused_miss_falls_back_to_the_full_suite(self):
        self.plan = {"build": self.built(), "focused": self.survived(),
                     "full": self.caught()}
        self.assertEqual(
            mutate.process_mutant(self.mutant(), self.sandbox), ("CAUGHT", True))
        self.assertEqual(len(self.commands), 3)
        self.assertNotIn("--filter", self.commands[2])

    def test_full_suite_decides_when_focused_misses(self):
        self.plan = {"build": self.built(), "focused": self.survived(),
                     "full": self.survived()}
        self.assertEqual(
            mutate.process_mutant(self.mutant(), self.sandbox),
            ("SURVIVED", True))

    def test_build_failure_never_reaches_either_tier(self):
        self.plan = {"build": completed(1, "error: build failed")}
        self.assertEqual(
            mutate.process_mutant(self.mutant(), self.sandbox),
            ("INVALID(compile)", False))
        self.assertEqual(len(self.commands), 1)

    def test_stale_target_runs_nothing(self):
        self.write_sandbox("let value = 9")
        self.plan = {"build": self.built(), "focused": self.caught(),
                     "full": self.caught()}
        self.assertEqual(
            mutate.process_mutant(self.mutant(), self.sandbox),
            ("STALE(find x0)", False))
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
