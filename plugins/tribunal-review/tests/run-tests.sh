#!/bin/bash
# Test runner for tribunal-review plugin.
# Usage: bash plugins/tribunal-review/tests/run-tests.sh [filter]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FILTER="${1:-}"

# shellcheck source=/dev/null
. "$TESTS_DIR/lib/helpers.sh"

matched=0
matches_filter() {
  [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]
}

while IFS= read -r -d '' case_file; do
  rel="${case_file#"$TESTS_DIR/"}"
  if ! matches_filter "$rel"; then
    continue
  fi
  matched=$((matched + 1))
  # shellcheck source=/dev/null
  . "$case_file"
done < <(find "$TESTS_DIR/cases" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)

if matches_filter "test-claude-transport.py"; then
  matched=$((matched + 1))
  assert_json_field "Claude complete-diff read-only transport regressions" "python3 '$TESTS_DIR/test-claude-transport.py'"
fi
if matches_filter "test-issue-743-726.sh"; then
  matched=$((matched + 1))
  assert_json_field "scratch input paths and Grok T3 budget (#743 #726)" "bash '$TESTS_DIR/test-issue-743-726.sh'"
fi
if matches_filter "test-deepseek-runner.sh"; then
  matched=$((matched + 1))
  assert_json_field "DeepSeek dsh runner, credentials, and preflight regressions" "bash '$TESTS_DIR/test-deepseek-runner.sh'"
fi
if matches_filter "test-deepseek-collection.sh"; then
  matched=$((matched + 1))
  assert_json_field "DeepSeek sealed collection and quota backup regressions" "bash '$TESTS_DIR/test-deepseek-collection.sh'"
fi
if matches_filter "line-check-degradation.sh"; then
  matched=$((matched + 1))
  assert_json_field "pruned reviewed head marks findings then fails the leg at stamping" "bash '$TESTS_DIR/line-check-degradation.sh' '$PLUGIN_ROOT/scripts/lib.sh' pruned"
  assert_json_field "healthy position check preserves output bytes" "bash '$TESTS_DIR/line-check-degradation.sh' '$PLUGIN_ROOT/scripts/lib.sh' healthy"
fi
if matches_filter "test-arbiter-evidence.py"; then
  matched=$((matched + 1))
  assert_json_field "arbiter requires produced legs and verifies pinned evidence" "python3 '$TESTS_DIR/test-arbiter-evidence.py' '$PLUGIN_ROOT'"
fi
if matches_filter "test-required-checks-portability.sh"; then
  matched=$((matched + 1))
  # shellcheck source=/dev/null
  . "$TESTS_DIR/test-required-checks-portability.sh"
  test_required_checks_portability
fi
if matches_filter "test-collector-portability.sh"; then
  matched=$((matched + 1))
  assert_json_field "source-checkout collection and root-drift regressions" "bash '$TESTS_DIR/test-collector-portability.sh'"
fi
if matches_filter "prior-rejections.sh"; then
  matched=$((matched + 1))
  echo ""
  # shellcheck source=/dev/null
  . "$TESTS_DIR/prior-rejections.sh"
  test_prior_rejections
fi
if matches_filter "test-shared-provider-helpers.sh"; then
  matched=$((matched + 1))
  assert_json_field "shared provider helpers and configurable auth timeout" "bash '$TESTS_DIR/test-shared-provider-helpers.sh'"
fi

if [ -n "$FILTER" ] && [ "$matched" -eq 0 ]; then
  echo -e "  ${RED}FAIL${NC} no test files matched filter '$FILTER'" >&2
  exit 1
fi

echo ""
if [ "$SKIP" -ne 0 ]; then
  echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
else
  echo "PASS=$PASS FAIL=$FAIL"
fi
if [ "$FAIL" -ne 0 ]; then printf '  - %s
' "${FAILURES[@]}"; exit 1; fi
