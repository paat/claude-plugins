#!/bin/bash
# Test runner for saas-operations plugin
# Self-contained harness: Bash 4+, git, jq, GNU date, and standard Unix tools
# Usage: bash plugins/saas-operations/tests/run-tests.sh

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
FAILURES=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_exit_code() {
  local label="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected exit $expected, got $actual)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected exit $expected, got $actual")
  fi
}

assert_output_contains() {
  local label="$1" output="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF -- "$expected" <<< "$output"; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (output missing: '$expected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: output missing '$expected'")
  fi
}

assert_output_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF -- "$unexpected" <<< "$output"; then
    echo -e "  ${RED}FAIL${NC} $label (output unexpectedly contains: '$unexpected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: output unexpectedly contains '$unexpected'")
  else
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file not found: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: file not found $path")
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly exists: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$label: file exists $path")
  fi
}

assert_file_contains() {
  local label="$1" path="$2" pattern="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -q -- "$pattern" "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($path missing pattern: $pattern)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: $path missing pattern '$pattern'")
  fi
}

assert_file_not_contains() {
  local label="$1" path="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF "$unexpected" "$path" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly contains: '$unexpected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: file unexpectedly contains '$unexpected'")
  else
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected '$expected', got '$actual'")
  fi
}

assert_json_valid() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if jq empty "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (invalid JSON: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: invalid JSON $path")
  fi
}

assert_json_field() {
  local label="$1" path="$2" field="$3" expected="$4"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local actual
  actual=$(jq -r "$field" "$path" 2>/dev/null || echo "__JQ_ERROR__")
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected '$expected', got '$actual'")
  fi
}

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
make_workdir() {
  local tmpdir
  tmpdir=$(mktemp -d "$TEST_TMP/case.XXXXXX")
  git init -q "$tmpdir"
  echo "$tmpdir"
}

# Extract the first ```bash fenced block within a "## <heading>" section of a
# markdown command file.
extract_md_bash() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    $0 == h { inseg=1; next }
    inseg && /^## / { inseg=0 }
    inseg && /^```bash$/ && !done { cap=1; next }
    cap && /^```$/ { done=1; cap=0; next }
    cap { print }
  ' "$file"
}

make_mock_gh() {
  mkdir -p "$1/bin"
  cat > "$1/bin/gh" <<'MOCK'
#!/usr/bin/env bash
_args="$*"; printf '%s\n' "${_args//$'\n'/ }" >> "${GH_CALLS_LOG:?}"
if [ -n "${GH_FAIL_ON:-}" ] && [[ "$*" == *"$GH_FAIL_ON"* ]]; then
  echo 'mock gh: forced failure' >&2; exit 1
fi
case "$1 $2" in
  "repo view") echo "${GH_REPO:-o/r}" ;;
  "issue create") echo "https://github.com/o/r/issues/${GH_CREATE_NUMBER:?}" ;;
  "issue comment") echo 'https://github.com/o/r/issues/commented' ;;
  "issue view")
    if [[ "$*" == *"body"* ]]; then echo "${GH_VIEW_BODY:-}"
    else echo "${GH_VIEW_STATE:-OPEN}"; fi ;;
  "issue list") echo "${GH_SEARCH_JSON:-[]}" ;;
  "label create") : ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
MOCK
  chmod +x "$1/bin/gh"
}

for suite in "$PLUGIN_ROOT"/tests/*.tests.sh; do
  . "$suite"
done
printf '\nTotal: %s | Pass: %s | Fail: %s\n' "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  printf 'FAIL: %s\n' "${FAILURES[@]}"
fi
[ "$TOTAL_COUNT" -eq "$((PASS_COUNT + FAIL_COUNT))" ]
[ "${#FAILURES[@]}" -eq "$FAIL_COUNT" ]
[ "$FAIL_COUNT" -eq 0 ]
