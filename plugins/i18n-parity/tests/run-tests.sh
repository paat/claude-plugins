#!/usr/bin/env bash
# Integration proofs: each fixture must produce its expected engine exit code.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../scripts/i18n-parity.py"
FIX="$HERE/fixtures"
fail=0

# case:expected_exit_code
cases=(
  "balanced:0"
  "waived-ok:0"
  "missing-key:1"
  "empty-value:1"
  "icu-arg-drift:1"
  "shape-mismatch:1"
  "dup-key:1"
  "missing-namespace:1"
  "stale-waiver:1"
  "config-error:2"
)

for entry in "${cases[@]}"; do
  name="${entry%%:*}"; want="${entry##*:}"
  python3 "$ENGINE" --config "$FIX/$name/.i18n-parity.json" --root "$FIX/$name" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "PASS  $name (exit $got)"
  else
    echo "FAIL  $name: expected exit $want, got $got"; fail=1
  fi
done

# Run the unit suite too.
if ! python3 "$HERE/test_engine.py" >/dev/null 2>&1; then
  echo "FAIL  unit suite (test_engine.py)"; fail=1
else
  echo "PASS  unit suite"
fi

[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME RED"
exit "$fail"
