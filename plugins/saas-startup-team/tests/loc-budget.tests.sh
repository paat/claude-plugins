# LOC budget gate regressions (issue #382).
declare -F make_workdir >/dev/null 2>&1 || {
  echo "loc-budget.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_loc_budget() {
  echo -e "\n${CYAN}Suite LB: ratcheting LOC budgets${NC}"
  local checker="$PLUGIN_ROOT/scripts/check_loc_budget.py"
  local budget="$PLUGIN_ROOT/integrity/loc-budget.json"
  local ec out

  assert_file_exists "LB1: check_loc_budget.py exists" "$checker"
  assert_file_exists "LB2: loc-budget.json exists" "$budget"

  out=$(python3 "$checker" --plugin-root "$PLUGIN_ROOT" 2>&1) || ec=$?
  ec=${ec:-0}
  assert_equals "LB3: current tree passes pre-1.0 ratchet" "$ec" "0"
  assert_output_contains "LB4: OK banner" "$out" "LOC budget OK"

  ec=0
  out=$(python3 "$checker" --plugin-root "$PLUGIN_ROOT" --release 1.0.0 2>&1) || ec=$?
  assert_equals "LB5: --release 1.0.0 fails until targets met" "$ec" "1"
  assert_output_contains "LB6: release failure names a metric" "$out" "release_target"

  # Nested Python fixture suite (exceed-each-metric, anti-weaken, baseline, aliases).
  ec=0
  out=$(python3 -m unittest discover -s "$PLUGIN_ROOT/tests/loc-budget" -p 'test_*.py' -v 2>&1) || ec=$?
  assert_equals "LB7: python loc-budget unit/fixture suite" "$ec" "0"
  if [ "$ec" -ne 0 ]; then
    echo "$out" >&2
  fi

  local gen="$PLUGIN_ROOT/scripts/generate_workflow_aliases.py"
  local entrypoints="$PLUGIN_ROOT/integrity/entrypoints.json"
  assert_file_exists "LB8: workflow alias generator exists" "$gen"
  assert_file_exists "LB9: entrypoints.json manifest exists" "$entrypoints"
  ec=0
  out=$(python3 "$gen" --plugin-root "$PLUGIN_ROOT" --check 2>&1) || ec=$?
  assert_equals "LB10: generated workflow aliases are clean" "$ec" "0"
}

test_loc_budget
