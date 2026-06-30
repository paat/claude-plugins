#!/bin/bash
# Test runner for tribunal-review plugin.
# Usage: bash plugins/tribunal-review/tests/run-tests.sh
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; FAILURES=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

assert_grep() {
  local label="$1" file="$2" pat="$3"
  if grep -q -- "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_no_grep() {
  local label="$1" file="$2" pat="$3"
  if grep -q -- "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  else
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  fi
}

assert_file() {
  local label="$1" file="$2"
  if [ -f "$PLUGIN_ROOT/$file" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_executable() {
  local label="$1" file="$2"
  if [ -x "$PLUGIN_ROOT/$file" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_bash_n() {
  local label="$1" file="$2"
  if bash -n "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_json_field() {
  local label="$1" command="$2"
  if eval "$command" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

test_qwen_envelope_parser() {
  local label="qwen result envelope parsed" work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/qwen" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"type":"assistant","message":{"model":"qwen-envelope-test","content":null}},
  {"type":"result","model":"qwen-envelope-test","result":"{\"provider\":\"qwen\",\"model\":\"placeholder\",\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
]
JSON
EOF
  chmod +x "$fake/qwen"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_QWEN=on TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="qwen" and .model=="qwen-envelope-test" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
AR=agents/opus-arbiter.md
LIB=scripts/lib.sh
PF=scripts/preflight.sh

echo "Extracted script surface:"
for script in \
  scripts/lib.sh \
  scripts/preflight.sh \
  scripts/run-codex-review.sh \
  scripts/run-gemini-review.sh \
  scripts/run-opencode-review.sh \
  scripts/run-qwen-review.sh \
  scripts/run-claude-review.sh
do
  assert_file "$script exists" "$script"
  assert_executable "$script executable" "$script"
  assert_bash_n "$script parses" "$script"
done

echo "Skill is orchestration-focused:"
line_count="$(wc -l < "$PLUGIN_ROOT/$SK" | tr -d ' ')"
if [ "$line_count" -le 260 ]; then
  echo -e "  ${GREEN}PASS${NC} compact tribunal skill ($line_count<=260)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} compact tribunal skill ($line_count>260)"; FAIL=$((FAIL+1)); FAILURES+=("compact tribunal skill")
fi
assert_grep "skill references preflight script" "$SK" "scripts/preflight.sh"
assert_grep "skill references codex runner" "$SK" "scripts/run-codex-review.sh"
assert_grep "skill references opencode runner" "$SK" "scripts/run-opencode-review.sh"
assert_grep "skill references claude runner" "$SK" "scripts/run-claude-review.sh"
assert_no_grep "skill no inline provider command bloat" "$SK" "timeout -k 10 600 codex exec"

echo "Preflight/base-ref behavior:"
assert_grep "resolves GitHub default branch" "$LIB" "defaultBranchRef"
assert_grep "supports base-ref override" "$LIB" "TRIBUNAL_BASE_REF"
assert_grep "checks diff vs BASE_REF" "$LIB" 'git diff "$base_ref"...HEAD'
assert_grep "tracks active reviewer legs" "$PF" "zero active reviewer legs"
assert_grep "warms OpenCode model registry" "$PF" "opencode models"
assert_no_grep "skill has no hardcoded origin/main" "$SK" "origin/main"
assert_no_grep "lib has no hardcoded origin/main" "$LIB" "origin/main"

echo "Context and large-diff guards:"
assert_grep "AGENTS.md capped" "$LIB" "head -c 16384"
assert_grep "reachability.md capped" "$LIB" "head -c 8192"
assert_grep "diff limit env" "$LIB" "TRIBUNAL_DIFF_LIMIT_BYTES"
assert_grep "large diff uses head -c" "$LIB" 'head -c "$max"'
assert_grep "OpenCode uses file attachment" "scripts/run-opencode-review.sh" '-f "$diff_attach"'
assert_grep "OpenCode stages diff in cwd" "scripts/run-opencode-review.sh" ".tribunal-review-"

echo "Disabled-provider markers:"
assert_json_field "codex disabled JSON" "TRIBUNAL_CODEX=off bash '$PLUGIN_ROOT/scripts/run-codex-review.sh' | jq -e '.provider==\"codex\" and .status==\"disabled\"'"
assert_json_field "gemini disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-gemini-review.sh' | jq -e '.provider==\"gemini\" and .status==\"disabled\"'"
assert_json_field "qwen disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-qwen-review.sh' | jq -e '.provider==\"qwen\" and .status==\"disabled\"'"
assert_json_field "claude disabled JSON" "TRIBUNAL_CLAUDE=off bash '$PLUGIN_ROOT/scripts/run-claude-review.sh' | jq -e '.provider==\"claude\" and .status==\"disabled\"'"
assert_json_field "opencode disabled JSONL" "TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' | jq -s -e 'length==2 and all(.[]; .status==\"disabled\")'"
test_qwen_envelope_parser

echo "Arbitration contract:"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-Finding Standard"
assert_grep "standard overrides highest-severity" "$SK" "never override 3b-0"
assert_grep "standard in arbiter agent" "$AR" "Blocking-finding standard"
assert_grep "same-class merge" "$SK" "Same-Class Merge (Every Round)"
assert_grep "reachability read by arbiter" "$SK" "Also read .reachability.md"
assert_grep "blocking_proof schema" "$SK" '"blocking_proof"'
assert_grep "scope lens switch" "$SK" "TRIBUNAL_SCOPE_LENS"
assert_grep "scope findings schema" "$SK" "scope_findings"

echo "Closing loop governor:"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 10 checkpoint" "$CL" "Round 10 — investor checkpoint"
assert_grep "round 20 ceiling" "$CL" "Round 20 — hard ceiling"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
