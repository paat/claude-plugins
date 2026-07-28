# standard-medium-eval removed from runtime (#388 LOC / epic #390 path).
declare -F assert_file_not_exists >/dev/null 2>&1 || {
  echo "standard-medium-eval.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_standard_medium_eval() {
  echo -e "\n${CYAN}Suite SME: standard-medium-eval removed from runtime${NC}"
  assert_file_not_exists "SME1: standard-medium-eval.sh deleted" \
    "$PLUGIN_ROOT/scripts/standard-medium-eval.sh"
}

test_standard_medium_eval
