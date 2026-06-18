#!/usr/bin/env bash
# Test runner for silent-failure-scanner (scan.sh / scan.awk)
# Self-contained: bash 4+, awk, and jq only.
# Usage: bash plugins/silent-failure-scanner/tests/run-tests.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$PLUGIN_ROOT/scripts/scan.sh"
FIX="$PLUGIN_ROOT/tests/fixtures"
PASS=0
FAIL=0

# scan a fixture and return the JSON report on stdout
scan_json() { bash "$SCAN" --format json -f "$FIX/$1" 2>/dev/null; }

# assert_codes NAME FIXTURE CODE...
#   passes if the JSON report contains every listed finding code
assert_codes() {
  local name="$1" fixture="$2"; shift 2
  local json codes missing=""
  json="$(scan_json "$fixture")"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: $name — invalid JSON output: $json"; FAIL=$((FAIL+1)); return
  fi
  codes="$(printf '%s' "$json" | jq -r '.findings[].code' 2>/dev/null)"
  for want in "$@"; do
    printf '%s\n' "$codes" | grep -qx "$want" || missing="$missing $want"
  done
  if [[ -z "$missing" ]]; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — missing code(s):$missing (got: $(printf '%s' "$codes" | tr '\n' ',' ))"; FAIL=$((FAIL+1))
  fi
}

# assert_clean NAME FIXTURE  — passes only if zero findings
assert_clean() {
  local name="$1" fixture="$2" json total
  json="$(scan_json "$fixture")"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: $name — invalid JSON output: $json"; FAIL=$((FAIL+1)); return
  fi
  total="$(printf '%s' "$json" | jq -r '.summary.total' 2>/dev/null)"
  if [[ "$total" == "0" ]]; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected 0 findings, got $total: $(printf '%s' "$json" | jq -c '.findings')"; FAIL=$((FAIL+1))
  fi
}

echo "== Acceptance: empty-catch + unawaited promise per language =="
assert_codes "ts  flags both"  ts-bad.diff  swallowed-exception unawaited-promise
assert_codes "py  flags both"  py-bad.diff  swallowed-exception unawaited-promise
assert_codes "cs  flags both"  cs-bad.diff  swallowed-exception unawaited-promise
assert_codes "php flags both"  php-bad.diff swallowed-exception unawaited-promise

echo "== Acceptance: zero false positives on clean diffs =="
assert_clean "ts  clean"  ts-clean.diff
assert_clean "py  clean"  py-clean.diff
assert_clean "cs  clean"  cs-clean.diff
assert_clean "php clean"  php-clean.diff

echo "== Heuristic detectors =="
assert_codes "dropped non-2xx response" ts-dropped-response.diff dropped-error-response
assert_codes "narrative-prose replacement" py-narrative.diff narrative-replacement

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
