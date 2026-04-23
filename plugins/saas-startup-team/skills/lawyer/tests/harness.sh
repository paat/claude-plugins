#!/usr/bin/env bash
# Trivial test runner: executes every test-*.sh under this directory.
# Each test is a standalone bash script that exits 0 on pass, non-zero on fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0
failed_tests=()

for t in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$t" ]] || continue
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_tests+=("$(basename "$t")")
  fi
done

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if (( fail > 0 )); then
  printf '  - %s\n' "${failed_tests[@]}"
  exit 1
fi
