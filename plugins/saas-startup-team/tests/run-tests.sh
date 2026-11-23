#!/bin/bash
# Test runner for saas-startup-team plugin
# Self-contained: no external dependencies beyond bash 4+ and jq
# Usage: bash plugins/saas-startup-team/tests/run-tests.sh [filter]

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FILTER="${1:-}"

# shellcheck source=/dev/null
. "$TESTS_DIR/lib/helpers.sh"

main() {
  echo -e "${YELLOW}=== saas-startup-team Plugin Tests ===${NC}"
  echo "Plugin root: $PLUGIN_ROOT"
  [ -z "$FILTER" ] || echo "Filter: $FILTER"
  echo ""

  if ! command -v jq &>/dev/null; then
    echo -e "${RED}ERROR: jq is required but not found${NC}"
    exit 1
  fi

  local matched=0 case_file suite rel

  while IFS= read -r -d '' case_file; do
    rel="${case_file#"$TESTS_DIR/"}"
    if [ -n "$FILTER" ] && [[ "$rel" != *"$FILTER"* ]]; then
      continue
    fi
    matched=$((matched + 1))
    # shellcheck source=/dev/null
    . "$case_file"
  done < <(find "$TESTS_DIR/cases" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)

  # Discovered suites: tests/**/*.tests.sh so nested suites (e.g. lifecycle/) load.
  while IFS= read -r -d '' suite; do
    rel="${suite#"$TESTS_DIR/"}"
    if [ -n "$FILTER" ] && [[ "$rel" != *"$FILTER"* ]]; then
      continue
    fi
    matched=$((matched + 1))
    echo ""
    echo -e "${CYAN}Discovered suite: ${rel}${NC}"
    # shellcheck source=/dev/null
    . "$suite"
  done < <(find "$TESTS_DIR" -type f -name '*.tests.sh' -print0 | sort -z)

  if [ -n "$FILTER" ] && [ "$matched" -eq 0 ]; then
    echo -e "${RED}ERROR: no test files matched filter '$FILTER'${NC}" >&2
    exit 1
  fi

  # Summary
  echo ""
  echo -e "${YELLOW}=== Summary ===${NC}"
  echo -e "Total: $TOTAL_COUNT | ${GREEN}Pass: $PASS_COUNT${NC} | ${RED}Fail: $FAIL_COUNT${NC}"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failures:${NC}"
    for f in "${FAILURES[@]}"; do
      echo -e "  ${RED}- $f${NC}"
    done
  else
    echo ""
  fi

  if [ "$TOTAL_COUNT" -ne "$((PASS_COUNT + FAIL_COUNT))" ]; then
    echo -e "${RED}COUNTER MISMATCH: Total: $TOTAL_COUNT | Pass: $PASS_COUNT | Fail: $FAIL_COUNT${NC}"
    exit 1
  fi

  if [ "${#FAILURES[@]}" -ne "$FAIL_COUNT" ]; then
    echo -e "${RED}FAILURE MISMATCH: Failures: ${#FAILURES[@]} | Fail: $FAIL_COUNT${NC}"
    exit 1
  fi

  [ "$FAIL_COUNT" -eq 0 ] || exit 1
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
}

main "$@"
