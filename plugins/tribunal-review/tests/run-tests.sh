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

test_codex_pins() {
  local expected_model="$1" expected_effort="$2" overrides="$3" label="$4"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/codex.args"
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"fake","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE"}}
JSON
EOF
  chmod +x "$fake/codex"

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
    export PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1
    unset TRIBUNAL_CODEX_MODEL TRIBUNAL_CODEX_EFFORT TRIBUNAL_CODEX_SANDBOX_BYPASS
    if [ "$overrides" = "yes" ]; then
      export TRIBUNAL_CODEX_MODEL="$expected_model" TRIBUNAL_CODEX_EFFORT="$expected_effort"
    fi
    bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null &&
    awk -v model="$expected_model" -v effort="model_reasoning_effort=\"$expected_effort\"" '
      previous == "-m" && $0 == model { model_seen = 1 }
      previous == "-c" && $0 == effort { effort_seen = 1 }
      previous == "-s" && $0 == "read-only" { read_only_seen = 1 }
      $0 == "--ignore-user-config" { isolated_seen = 1 }
      $0 == "mcp_servers={}" { mcp_disabled = 1 }
      { previous = $0 }
      END { exit !(model_seen && effort_seen && read_only_seen && isolated_seen && mcp_disabled) }
    ' "$work/codex.args"
  then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Vacuous verdict = zero findings + a blocking verdict. Both the reported BLOCK
# shape (quality 0.0) and the broader NEEDS_WORK / nonzero-quality shape must be
# downgraded to a leg error, never passed through as a real review (issue #171).
test_codex_vacuous_guard() {
  local verdict="$1" quality="$2" label="$3"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/codex.args"
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"default","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":$quality,"verdict":"$verdict"}}
JSON
EOF
  chmod +x "$fake/codex"

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
    PATH="$fake:$PATH" TRIBUNAL_CODEX_SANDBOX_BYPASS=on TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="codex" and (.error | test("vacuous"))' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  if [ "$verdict" = "BLOCK" ] && [ "$quality" = "0.0" ]; then
    local label2="codex bypass flag forwarded when TRIBUNAL_CODEX_SANDBOX_BYPASS=on"
    if grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$work/codex.args" 2>/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $label2"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label2"; FAIL=$((FAIL+1)); FAILURES+=("$label2")
    fi
  fi
  rm -rf "$work"
}

# A provider can return structurally valid JSON whose line numbers are
# diff-global/prompt positions that cannot exist in the named file (issue #259).
# The runner must mark such findings (and findings on files outside the diff)
# instead of silently accepting them, while leaving valid positions untouched.
test_codex_line_bounds_guard() {
  local label="codex out-of-bounds finding positions are marked, valid ones untouched"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"default","findings":[
  {"severity":"high","category":"logic","file":"file.txt","line":1,"title":"valid position","description":"d","suggestion":"s","confidence":0.9},
  {"severity":"high","category":"logic","file":"file.txt","line":9333,"title":"diff-global position","description":"d","suggestion":"s","confidence":0.9},
  {"severity":"medium","category":"logic","file":"other.py","line":12,"title":"file outside diff","description":"d","suggestion":"s","confidence":0.8}
],"summary":{"total_findings":3,"critical":0,"high":2,"medium":1,"low":0,"quality_score":5.0,"verdict":"NEEDS_WORK"}}
JSON
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    printf 'x = 1\n' > other.py
    git add file.txt other.py
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_CODEX_SANDBOX_BYPASS=on TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      (.findings[0] | has("line_check") | not)
      and (.findings[1].line_check | test("out of bounds"))
      and (.findings[2].line_check == "file not in reviewed diff")
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
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
assert_grep "OpenCode prompt positional precedes -f (array flag swallows positionals, issue #170)" "scripts/run-opencode-review.sh" '"$(cat "$prompt")" -f "$diff_attach"'
assert_no_grep "OpenCode -f does not precede prompt positional" "scripts/run-opencode-review.sh" '-f "$diff_attach" "$(cat'
assert_grep "OpenCode stages diff in cwd" "scripts/run-opencode-review.sh" ".tribunal-review-"

echo "Disabled-provider markers:"
assert_json_field "codex disabled JSON" "TRIBUNAL_CODEX=off bash '$PLUGIN_ROOT/scripts/run-codex-review.sh' | jq -e '.provider==\"codex\" and .status==\"disabled\"'"
assert_json_field "gemini disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-gemini-review.sh' | jq -e '.provider==\"gemini\" and .status==\"disabled\"'"
assert_json_field "qwen disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-qwen-review.sh' | jq -e '.provider==\"qwen\" and .status==\"disabled\"'"
assert_json_field "claude disabled JSON" "TRIBUNAL_CLAUDE=off bash '$PLUGIN_ROOT/scripts/run-claude-review.sh' | jq -e '.provider==\"claude\" and .status==\"disabled\"'"
assert_json_field "opencode disabled JSONL" "TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' | jq -s -e 'length==2 and all(.[]; .status==\"disabled\")'"
test_qwen_envelope_parser
test_codex_pins gpt-5.6-sol medium no "codex defaults pin Sol and medium in argv"
test_codex_pins test-model high yes "codex model and effort environment overrides stay explicit"
test_codex_vacuous_guard BLOCK 0.0 "codex vacuous empty-BLOCK downgraded to leg error"
test_codex_vacuous_guard NEEDS_WORK 7.5 "codex vacuous empty-NEEDS_WORK (nonzero quality) downgraded to leg error"
test_codex_vacuous_guard " BLOCK " 0.0 "codex vacuous verdict tolerates surrounding whitespace"
test_codex_line_bounds_guard

echo "Finding position validation:"
assert_grep "lib defines line-bounds validator" "$LIB" "tribunal_line_check()"
assert_grep "prepare_diff records changed paths" "$LIB" 'git diff --name-only "$base_ref"'
for runner in run-codex-review.sh run-claude-review.sh run-gemini-review.sh run-qwen-review.sh run-opencode-review.sh; do
  assert_grep "$runner pipes through line check" "scripts/$runner" "tribunal_line_check"
done
assert_grep "arbiter told to distrust marked positions" "$SK" "line_check"

echo "Arbitration contract:"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-Finding Standard"
assert_grep "standard overrides highest-severity" "$SK" "never override 3b-0"
assert_grep "same-class merge" "$SK" "Same-Class Merge (Every Round)"
assert_grep "reachability read by arbiter" "$SK" "Also read .reachability.md"
assert_grep "blocking_proof schema" "$SK" '"blocking_proof"'
assert_grep "scope lens switch" "$SK" "TRIBUNAL_SCOPE_LENS"
assert_grep "scope findings schema" "$SK" "scope_findings"
assert_grep "calling context arbitrates" "$SK" "calling context arbitrates"
assert_grep "caller provider metadata optional" "$SK" "TRIBUNAL_CALLER_PROVIDER"
assert_grep "caller model metadata optional" "$SK" "TRIBUNAL_CALLER_MODEL"
assert_grep "caller effort metadata optional" "$SK" "TRIBUNAL_CALLER_EFFORT"
assert_grep "standalone caller identity is optional" "$SK" "standalone runs may leave all three unset"
assert_no_grep "tribunal skill has no Opus authority claim" "$SK" "Opus"
assert_no_grep "closing skill has no Opus authority claim" "$CL" "Opus"
assert_no_grep "README has no Opus authority claim" "README.md" "Opus"
assert_no_grep "Claude reviewer has no Opus authority claim" "agents/claude-reviewer.md" "Opus"

echo "Closing loop governor:"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 10 checkpoint" "$CL" "Round 10 — checkpoint"
assert_grep "round 20 ceiling" "$CL" "Round 20 — hard ceiling"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
