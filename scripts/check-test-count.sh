#!/bin/bash
# README publishes the unit-test count; keep it true. scripts/test.sh owns
# the suite run and writes build/test.log, so this check reads that run
# instead of starting a second one. README is the only place that states a
# count.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/test.sh
log=build/test.log

actual=$(grep -oE 'Executed [0-9]+ tests' "$log" | tail -1 | grep -oE '[0-9]+' || true)
if [[ -z "$actual" ]]; then
    echo "test-count: could not read the suite's test count" >&2
    exit 1
fi

claims=$(grep -oE '\([1-9][0-9]* tests\)' README.md | grep -oE '[1-9][0-9]*' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)
if [[ -z "$claims" ]]; then
    echo "test-count: README publishes no count; nothing to check"
    exit 0
fi

if [[ "$claims" != "$actual" ]]; then
    echo "test-count: README claims '$claims'; the suite ran $actual" >&2
    exit 1
fi

echo "test-count: README's $actual matches the suite"
