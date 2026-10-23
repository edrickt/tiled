#!/bin/bash
# Run the hermetic suite without the passing-case transcript. A green run
# prints one summary line; a red run prints the failures and the summary.
# The full log stays at build/test.log for the caller that needs it.
set -uo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
log=build/test.log

swift test >"$log" 2>&1
status=$?

if [[ $status -eq 0 ]]; then
    summary=$(grep -oE 'Executed [0-9]+ tests.*' "$log" | tail -1)
    echo "${summary:-tests passed (no summary line)}"
    exit 0
fi

failures=$(grep -E 'error:|Test (Case|Suite) .* failed|Fatal error|Undefined symbols|Segmentation fault' "$log" || true)
if [[ -n "$failures" ]]; then
    echo "$failures"
else
    tail -40 "$log"
fi
grep -oE 'Executed [0-9]+ tests.*' "$log" | tail -1
echo "full log: $log"
exit "$status"
