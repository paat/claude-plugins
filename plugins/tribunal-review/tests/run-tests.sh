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
assert_no_grep() {  # label, file, pattern
  local label="$1" file="$2" pat="$3"
  if grep -q "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  else
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
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
assert_count_ge "injected into >=5 legs" "$SK" "head -c 8192" 5
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

echo "Issue #110: default branch and usable provider counting:"
assert_grep "resolves GitHub default branch" "$SK" "defaultBranchRef"
assert_grep "supports base-ref override" "$SK" "TRIBUNAL_BASE_REF"
assert_grep "status counts active reviewer legs" "$SK" "active reviewer legs"
assert_grep "tracks skipped providers" "$SK" "SKIPPED_PROVIDERS"
assert_grep "deepseek model miss is skipped" "$SK" "mark_skipped deepseek .*OpenCode model"
assert_grep "deepseek model hit is usable" "$SK" "mark_usable deepseek"
assert_count_ge "reviewer calls use BASE_REF" "$SK" 'git diff "$BASE_REF"...HEAD' 4
assert_no_grep "skill has no hardcoded origin/main" "$SK" "origin/main"
assert_no_grep "codex agent has no hardcoded origin/main" "agents/codex-reviewer.md" "origin/main"
assert_no_grep "gemini agent has no hardcoded origin/main" "agents/gemini-reviewer.md" "origin/main"
assert_no_grep "qwen agent has no hardcoded origin/main" "agents/qwen-reviewer.md" "origin/main"
assert_no_grep "claude agent has no hardcoded origin/main" "agents/claude-reviewer.md" "origin/main"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
