#!/usr/bin/env bash
# payment-contract-tester self-tests: prove the contract-test patterns run green against the
# correct handler and red against each seeded trap, per supported stack. Skips a stack whose
# runtime is absent (never a false green). Plan 2 adds the xunit stack here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

echo "### pytest reference fixtures ###"
bash "$ROOT/reference/pytest/run.sh" || rc=1

# Plan 2: bash "$ROOT/reference/xunit/run.sh" || rc=1

if [ "$rc" -eq 0 ]; then echo "ALL SELF-TESTS PASSED"; else echo "SELF-TESTS FAILED"; fi
exit $rc
