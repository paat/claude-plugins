#!/usr/bin/env bash
# Test runner for multi-model-orchestrator plugin.
# Usage: bash plugins/multi-model-orchestrator/tests/run-tests.sh [filter]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if matches_filter "claude-api-tests.sh"; then
  matched=$((matched + 1))
  bash "$TESTS_DIR/claude-api-tests.sh"
fi

if matches_filter "test-outcome-lifecycle.py"; then
  matched=$((matched + 1))
  mmo_ensure_outcome_repo
  python3 "$TESTS_DIR/test-outcome-lifecycle.py" "$PLUGIN_ROOT/scripts" "$OUTCOMES/lifecycle" "$outcome_repo"
fi

if matches_filter "test-stop-signals.py"; then
  matched=$((matched + 1))
  python3 "$TESTS_DIR/test-stop-signals.py" "$PLUGIN_ROOT/scripts" "$WORK/stop-signals"
fi

if matches_filter "test-runner-preservation.py"; then
  matched=$((matched + 1))
  python3 "$TESTS_DIR/test-runner-preservation.py" "$PLUGIN_ROOT/scripts"
fi

if matches_filter "test-ask88-gates.sh"; then
  matched=$((matched + 1))
  bash "$TESTS_DIR/test-ask88-gates.sh"
fi

if matches_filter "test-catalog-unification.sh"; then
  matched=$((matched + 1))
  bash "$TESTS_DIR/test-catalog-unification.sh"
fi

if [ -n "$FILTER" ] && [ "$matched" -eq 0 ]; then
  printf 'FAIL: no test files matched filter: %s\n' "$FILTER" >&2
  exit 1
fi

printf 'All multi-model-orchestrator tests passed.\n'
