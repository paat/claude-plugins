#!/usr/bin/env bash
# Runs the xUnit reference suite: GREEN against the correct handler, then asserts each seeded trap
# reddens its mapped test AND (for non-foundational traps) leaves the OTHER tests green. Exit 0 only
# if all hold. SKIPs cleanly if the .NET SDK is absent (no false green) — mirrors the pytest guard.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "SKIP: dotnet SDK not available"; exit 0
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

# Build once; the handler-under-test is chosen at runtime via PCT_HANDLER, so one build serves all.
if ! dotnet build -v quiet >/tmp/pct_xunit_build.log 2>&1; then
  echo "FAIL: xunit project did not build"; cat /tmp/pct_xunit_build.log; exit 1
fi

run() {  # run <PCT_HANDLER> [extra dotnet test args...]
  local handler="$1"; shift
  PCT_HANDLER="$handler" dotnet test --no-build "$@"
}

fail=0

echo "== correct handler (expect all green) =="
if run correct >/tmp/pct_xunit_green.log 2>&1; then
  echo "OK: correct handler all green"
else
  echo "FAIL: correct handler was not all green"; cat /tmp/pct_xunit_green.log; fail=1
fi

# module : mapped_test : also-red allowlist (|-separated, may be empty; EXEMPT = skip others-green).
# Mirrors reference/pytest/run.sh exactly. trap_01 is EXEMPT (a malformed token key reddens every
# effect-driving test — no clean isolation). trap_05's allowlist is the concurrency test.
traps="
trap_01_claim_shape:Paid_marks_order:EXEMPT
trap_02_missing_claim_guard:Required_claim_missing_rejected:
trap_03_reference_reuse:Duplicate_reference_rejected:
trap_04_float_money:Money_decimal_boundary_no_float:
trap_05_no_dedupe:Replayed_webhook_idempotent:Concurrent_duplicate_applies_once
trap_06_skip_signature:Forged_signature_rejected:
trap_07_trust_body_status:Status_taken_from_token_not_body:
trap_08_no_recency:Stale_timestamp_rejected:
trap_09_downgrade:Terminal_state_not_downgraded:
trap_10_concurrency:Concurrent_duplicate_applies_once:
"

echo "== seeded traps (expect each to redden its mapped test) =="
for spec in $traps; do
  mod=${spec%%:*}; rest=${spec#*:}; tst=${rest%%:*}; allow=${rest#*:}

  # 1) the mapped test MUST go red
  if run "$mod" --filter "FullyQualifiedName~$tst" >/dev/null 2>&1; then
    echo "FAIL: $mod stayed green for $tst"; fail=1
  else
    echo "OK: $mod reddened $tst"
  fi

  # 2) non-foundational traps must leave the OTHER tests green (minus the documented allowlist)
  if [ "$allow" = "EXEMPT" ]; then
    echo "   (exempt from others-green: foundational claim trap)"; continue
  fi
  filter="FullyQualifiedName!~$tst"
  if [ -n "$allow" ]; then
    IFS='|' read -ra extra <<< "$allow"
    for e in "${extra[@]}"; do filter="$filter&FullyQualifiedName!~$e"; done
  fi
  if run "$mod" --filter "$filter" >/dev/null 2>&1; then
    echo "OK: $mod left the other tests green"
  else
    echo "FAIL: $mod reddened an unrelated test"; fail=1
  fi
done

exit $fail
