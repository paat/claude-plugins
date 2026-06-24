#!/bin/bash
# Test runner for tribunal-review plugin (content-presence over the SKILL/agent docs)
# Usage: bash plugins/tribunal-review/tests/run-tests.sh
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; FAILURES=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

assert_grep() {  # label, file, pattern
  local label="$1" file="$2" pat="$3"
  if grep -q "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}
assert_count_ge() {  # label, file, pattern, min
  local label="$1" file="$2" pat="$3" min="$4"
  local n; n=$(grep -c "$pat" "$PLUGIN_ROOT/$file" || true)
  if [ "$n" -ge "$min" ]; then
    echo -e "  ${GREEN}PASS${NC} $label ($n>=$min)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($n<$min)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
AR=agents/opus-arbiter.md

echo "Blocking-finding standard (piece 0):"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-finding standard"
assert_grep "standard overrides highest-severity" "$SK" "never overrides 3b-0"
assert_grep "standard in arbiter agent" "$AR" "Blocking-finding standard"

echo "Same-class merge (piece 5):"
assert_grep "same-class merge" "$SK" "Same-class merge (every round)"

echo "reachability.md injection (piece 1):"
assert_count_ge "injected into >=5 legs" "$SK" "head -c 8192 reachability.md" 5
assert_grep "arbiter reads reachability" "$SK" "Also read .reachability.md. from the repo root"

echo "blocking_proof schema (piece 0 structured):"
assert_grep "schema field" "$SK" '"blocking_proof"'
assert_grep "required for crit/high" "$SK" "Required for critical/high"

echo "Closing loop governor (pieces 2/3/4/6):"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 10 checkpoint" "$CL" "Round 10 — investor checkpoint"
assert_grep "round 20 ceiling" "$CL" "Round 20 — hard ceiling"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
