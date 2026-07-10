# Sourced by run-tests.sh's discovered-suite loop. The lawyer skill's own
# test-*.sh files live under skills/lawyer/tests/ and are run by their own
# harness.sh — this shim makes that harness's pass/fail visible to the main
# runner, which otherwise has no path to them.
echo -e "${CYAN}Testing: lawyer skill test harness${NC}"
lh_ec=0
bash "$PLUGIN_ROOT/skills/lawyer/tests/harness.sh" >/dev/null 2>&1 || lh_ec=$?
assert_exit_code "LH1: lawyer skill test harness passes" "$lh_ec" 0
