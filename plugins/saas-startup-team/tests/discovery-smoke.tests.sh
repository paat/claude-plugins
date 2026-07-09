# Sourced by run-tests.sh's discovered-suite loop; proves discovery stays wired.
echo -e "${CYAN}Testing: discovered-suite loading${NC}"
assert_equals "DS1: discovered suite runs with harness helpers" "sourced" "sourced"
