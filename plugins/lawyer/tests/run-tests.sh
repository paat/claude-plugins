#!/bin/bash
# Test runner for the lawyer plugin. Requires bash 4+, jq, python3.
# Usage: bash plugins/lawyer/tests/run-tests.sh

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
FAILURES=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# record LABEL RC DETAIL — RC 0 is a pass; DETAIL is shown only on failure.
record() {
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$2" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $1 ($3)"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$1")
  fi
}

assert_exit_code() { local rc=0; [ "$2" -eq "$3" ] || rc=1; record "$1" $rc "exit $2, expected $3"; }
assert_equals() { local rc=0; [ "$2" = "$3" ] || rc=1; record "$1" $rc "got '$2', expected '$3'"; }
assert_output_contains() { local rc=0; grep -qF -- "$3" <<<"$2" || rc=1; record "$1" $rc "missing '$3'"; }
assert_output_not_contains() { local rc=0; ! grep -qF -- "$3" <<<"$2" || rc=1; record "$1" $rc "unexpected '$3'"; }
assert_file_exists() { local rc=0; [ -f "$2" ] || rc=1; record "$1" $rc "missing $2"; }
assert_file_contains() { local rc=0; grep -qF -- "$3" "$2" || rc=1; record "$1" $rc "'$3' not in $2"; }
assert_json_field() {
  local rc=0 actual
  actual=$(jq -r "$3" "$2" 2>/dev/null || echo "<jq error>")
  [ "$actual" = "$4" ] || rc=1
  record "$1" $rc "got '$actual', expected '$4'"
}

make_workdir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  git init -q "$tmpdir"
  echo "$tmpdir"
}

echo -e "${YELLOW}=== lawyer Plugin Tests ===${NC}"
while IFS= read -r -d '' suite; do
  echo ""
  # shellcheck source=/dev/null
  . "$suite"
done < <(find "$PLUGIN_ROOT/tests" -maxdepth 1 -type f -name '*.tests.sh' -print0 | sort -z)

echo ""
echo -e "Total: $TOTAL_COUNT | ${GREEN}Pass: $PASS_COUNT${NC} | ${RED}Fail: $FAIL_COUNT${NC}"
if [ "$FAIL_COUNT" -gt 0 ] || [ "$TOTAL_COUNT" -ne "$((PASS_COUNT + FAIL_COUNT))" ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
echo -e "${GREEN}All tests passed!${NC}"
