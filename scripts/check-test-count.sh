#!/bin/bash
# README publishes its unit-test counts; keep them true. The hermetic
# suite is the source of truth. Point-in-time docs (release notes,
# .scratch reports) are exempt by design.
set -euo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT

if ! swift test >"$log" 2>&1; then
    cat "$log" >&2
    echo "test-count: the suite is red; fix that first" >&2
    exit 1
fi

actual=$(grep -oE 'Executed [0-9]+ tests' "$log" | tail -1 | grep -oE '[0-9]+')
if [[ -z "$actual" ]]; then
    echo "test-count: could not read the suite's test count" >&2
    exit 1
fi

claims=$(grep -oE '\([0-9]+ tests\)' README.md | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')
if [[ -z "$claims" ]]; then
    echo "test-count: README publishes no count; nothing to check"
    exit 0
fi

if [[ "$claims" != "$actual" ]]; then
    echo "test-count: README claims '$claims'; the suite ran $actual" >&2
    exit 1
fi
echo "test-count: README's $actual matches the suite"
