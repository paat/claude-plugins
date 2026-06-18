#!/usr/bin/env bash
# Runs the pytest reference suite: GREEN against the correct handler, then asserts each
# seeded trap reddens exactly its mapped test. Exit 0 only if all expectations hold.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v python3 >/dev/null || ! python3 -c 'import pytest' 2>/dev/null; then
  echo "SKIP: python3 + pytest not available"; exit 0
fi

fail=0

echo "== correct handler (expect all green) =="
if PCT_HANDLER=handler python3 -m pytest -q >/tmp/pct_green.log 2>&1; then
  echo "OK: correct handler all green"
else
  echo "FAIL: correct handler was not all green"; cat /tmp/pct_green.log; fail=1
fi

# trap_module : test_that_must_fail
traps="
trap_01_claim_shape:test_paid_marks_order
trap_02_missing_claim_guard:test_required_claim_missing_rejected
trap_03_reference_reuse:test_duplicate_reference_rejected
trap_04_float_money:test_money_decimal_boundary_no_float
trap_05_no_dedupe:test_replayed_webhook_idempotent
trap_06_skip_signature:test_forged_signature_rejected
trap_07_trust_body_status:test_status_taken_from_token_not_body
trap_08_no_recency:test_stale_timestamp_rejected
trap_09_downgrade:test_terminal_state_not_downgraded
trap_10_concurrency:test_concurrent_duplicate_applies_once
"

echo "== seeded traps (expect each to redden its mapped test) =="
for pair in $traps; do
  mod=${pair%%:*}; tst=${pair##*:}
  if PCT_HANDLER=$mod python3 -m pytest -q -k "$tst" >/dev/null 2>&1; then
    echo "FAIL: $mod stayed green for $tst"; fail=1
  else
    echo "OK: $mod reddened $tst"
  fi
done

exit $fail
