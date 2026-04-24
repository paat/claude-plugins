#!/bin/bash
# Test runner for saas-startup-team plugin
# Self-contained: no external dependencies beyond bash 4+ and jq
# Usage: bash plugins/saas-startup-team/tests/run-tests.sh

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
FAILURES=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_exit_code() {
  local label="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected exit $expected, got $actual)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected exit $expected, got $actual")
  fi
}

assert_output_contains() {
  local label="$1" output="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if echo "$output" | grep -qF "$expected"; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (output missing: '$expected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: output missing '$expected'")
  fi
}

assert_output_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if echo "$output" | grep -qF "$unexpected"; then
    echo -e "  ${RED}FAIL${NC} $label (output unexpectedly contains: '$unexpected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: output unexpectedly contains '$unexpected'")
  else
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file not found: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: file not found $path")
  fi
}

assert_file_contains() {
  local label="$1" path="$2" pattern="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -q "$pattern" "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($path missing pattern: $pattern)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: $path missing pattern '$pattern'")
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected '$expected', got '$actual'")
  fi
}

assert_json_valid() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if jq empty "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (invalid JSON: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: invalid JSON $path")
  fi
}

assert_json_field() {
  local label="$1" path="$2" field="$3" expected="$4"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local actual
  actual=$(jq -r "$field" "$path" 2>/dev/null || echo "__JQ_ERROR__")
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (field $field: expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: field $field expected '$expected', got '$actual'")
  fi
}

# ---------------------------------------------------------------------------
# Helper: create temp working dir with optional .startup/ fixtures
# ---------------------------------------------------------------------------

make_workdir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  git init -q "$tmpdir"
  echo "$tmpdir"
}

setup_startup_dir() {
  local workdir="$1" iteration="${2:-1}"
  mkdir -p "$workdir/.startup/handoffs"
  mkdir -p "$workdir/.startup/docs"
  mkdir -p "$workdir/.startup/signoffs"
  mkdir -p "$workdir/.startup/reviews"
  mkdir -p "$workdir/.startup/go-live"
  cat > "$workdir/.startup/state.json" <<EOF
{
  "iteration": $iteration,
  "max_iterations": 20,
  "phase": "implementation",
  "active_role": "tech-founder",
  "status": "active",
  "started": "2026-02-23T10:00:00Z"
}
EOF
}

# Run a script in a workdir, capturing exit code and output
run_in_dir() {
  local workdir="$1" script="$2" stdin_data="${3:-}"
  local exit_code=0
  local output
  output=$(cd "$workdir" && echo "$stdin_data" | bash "$script" 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# ---------------------------------------------------------------------------
# Suite A: check-idle.sh
# ---------------------------------------------------------------------------

test_check_idle() {
  echo -e "\n${CYAN}Suite A: check-idle.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/check-idle.sh"
  local workdir ec output

  # A1: empty JSON — no teammate_name → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A1: empty JSON allows idle" "$ec" 0
  rm -rf "$workdir"

  # A2: unknown teammate → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"designer"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A2: unknown teammate allows idle" "$ec" 0
  rm -rf "$workdir"

  # A3: no .startup dir → exit 0
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"business-founder"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A3: no .startup dir allows idle" "$ec" 0
  rm -rf "$workdir"

  # A4: iteration 0, research phase, business-founder, no handoffs → exit 0 (exempt)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 0
  # Override phase to "research" — the default starting phase at iteration 0
  jq '.phase = "research"' "$workdir/.startup/state.json" > "$workdir/.startup/state.tmp" \
    && mv "$workdir/.startup/state.tmp" "$workdir/.startup/state.json"
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"business-founder"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A4: iteration 0 allows idle" "$ec" 0
  rm -rf "$workdir"

  # A5: iteration 1, business-founder, no handoffs → exit 2 (BLOCKS)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"business-founder"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A5: biz-founder blocks without handoff" "$ec" 2
  assert_output_contains "A5: shows guidance message" "$output" "must write your handoff"
  rm -rf "$workdir"

  # A6: iteration 1, business-founder, has handoff → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  echo "handoff content" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"business-founder"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A6: biz-founder with handoff allows idle" "$ec" 0
  rm -rf "$workdir"

  # A7: iteration 2, tech-founder, no handoffs → exit 2 (BLOCKS)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 2
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"tech-founder"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A7: tech-founder blocks without handoff" "$ec" 2
  assert_output_contains "A7: shows guidance message" "$output" "must write your handoff"
  rm -rf "$workdir"

  # A8: iteration 2, tech-founder, has handoff → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 2
  echo "handoff content" > "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0; output=$(cd "$workdir" && echo '{"teammate_name":"tech-founder"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "A8: tech-founder with handoff allows idle" "$ec" 0
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite B: check-task-complete.sh
# ---------------------------------------------------------------------------

test_check_task_complete() {
  echo -e "\n${CYAN}Suite B: check-task-complete.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/check-task-complete.sh"
  local workdir ec output

  # B1: empty JSON → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B1: empty JSON allows completion" "$ec" 0
  rm -rf "$workdir"

  # B2: no .startup dir → exit 0
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && echo '{"task_subject":"Implement feature"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B2: no .startup dir allows completion" "$ec" 0
  rm -rf "$workdir"

  # B3: non-matching subject → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{"task_subject":"Write documentation"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B3: non-matching subject allows completion" "$ec" 0
  rm -rf "$workdir"

  # B4: roundtrip keyword, no handoffs → exit 2 (BLOCKS)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{"task_subject":"Implement user login feature"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B4: roundtrip task blocks without handoffs" "$ec" 2
  assert_output_contains "B4: shows guidance message" "$output" "handoff"
  rm -rf "$workdir"

  # B5: roundtrip keyword, has handoffs → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  echo "handoff" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  ec=0; output=$(cd "$workdir" && echo '{"task_subject":"Implement user login feature"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B5: roundtrip task with handoffs allows completion" "$ec" 0
  rm -rf "$workdir"

  # B6: go-live keyword, no signoff → exit 2 (BLOCKS)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && echo '{"task_subject":"Launch the product"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B6: go-live task blocks without signoff" "$ec" 2
  assert_output_contains "B6: shows solution-signoff guidance" "$output" "solution-signoff"
  rm -rf "$workdir"

  # B7: go-live keyword, has signoff → exit 0
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  echo "signoff" > "$workdir/.startup/go-live/solution-signoff.md"
  ec=0; output=$(cd "$workdir" && echo '{"task_subject":"Ship release v1"}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "B7: go-live task with signoff allows completion" "$ec" 0
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite C: status.sh
# ---------------------------------------------------------------------------

test_status_script() {
  echo -e "\n${CYAN}Suite C: status.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/status.sh"
  local workdir ec output

  # C1: no .startup dir
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C1: no .startup exits 0" "$ec" 0
  assert_output_contains "C1: shows no-session message" "$output" "No active startup session"
  rm -rf "$workdir"

  # C2: empty minimal .startup
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 0
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C2: minimal setup exits 0" "$ec" 0
  assert_output_contains "C2: shows zero handoffs" "$output" "Total handoffs: 0"
  rm -rf "$workdir"

  # C3: with handoffs
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 2
  echo "h1" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  echo "h2" > "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C3: with handoffs exits 0" "$ec" 0
  assert_output_contains "C3: shows handoff count" "$output" "Total handoffs: 2"
  assert_output_contains "C3: lists first handoff" "$output" "001-business-to-tech.md"
  assert_output_contains "C3: lists second handoff" "$output" "002-tech-to-business.md"
  rm -rf "$workdir"

  # C4: with solution signoff
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 5
  echo "signoff" > "$workdir/.startup/go-live/solution-signoff.md"
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C4: go-live status exits 0" "$ec" 0
  assert_output_contains "C4: shows ready for go-live" "$output" "Ready for go-live"
  rm -rf "$workdir"

  # C5: with human tasks
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 3
  cat > "$workdir/.startup/human-tasks.md" <<'TASKS'
# Human Tasks
## Pending
- [ ] Register OÜ
- [ ] Open bank account
- [ ] Get domain name
## Completed
- [x] Review business plan
TASKS
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C5: human tasks exits 0" "$ec" 0
  assert_output_contains "C5: shows pending count" "$output" "Pending: 3"
  assert_output_contains "C5: shows completed count" "$output" "Completed: 1"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite D: Template Validation
# ---------------------------------------------------------------------------

test_templates() {
  echo -e "\n${CYAN}Suite D: Template Validation${NC}"
  local tmpl_dir="$PLUGIN_ROOT/templates"

  # D1-D5: startup-brief.md
  assert_file_exists "D1: startup-brief.md exists" "$tmpl_dir/startup-brief.md"
  assert_file_contains "D2: has IDEA_DESCRIPTION placeholder" "$tmpl_dir/startup-brief.md" "{{IDEA_DESCRIPTION}}"
  assert_file_contains "D3: has INVESTOR_NOTES placeholder" "$tmpl_dir/startup-brief.md" "{{INVESTOR_NOTES}}"
  assert_file_contains "D4: has BUDGET placeholder" "$tmpl_dir/startup-brief.md" "{{BUDGET}}"
  assert_file_contains "D5: has TIMELINE placeholder" "$tmpl_dir/startup-brief.md" "{{TIMELINE}}"
  assert_file_contains "D5b: has TARGET_MARKET placeholder" "$tmpl_dir/startup-brief.md" "{{TARGET_MARKET}}"

  # D6-D10: handoff-business-to-tech.md
  assert_file_exists "D6: handoff-business-to-tech.md exists" "$tmpl_dir/handoff-business-to-tech.md"
  assert_file_contains "D7: has from frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^from:"
  assert_file_contains "D8: has to frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^to:"
  assert_file_contains "D9: has iteration frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^iteration:"
  assert_file_contains "D10: has type frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^type:"
  assert_file_contains "D10b: has ITERATION placeholder" "$tmpl_dir/handoff-business-to-tech.md" "{{ITERATION}}"
  assert_file_contains "D10c: has DATE placeholder" "$tmpl_dir/handoff-business-to-tech.md" "{{DATE}}"

  # D11-D15: handoff-tech-to-business.md
  assert_file_exists "D11: handoff-tech-to-business.md exists" "$tmpl_dir/handoff-tech-to-business.md"
  assert_file_contains "D12: has from frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^from:"
  assert_file_contains "D13: has to frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^to:"
  assert_file_contains "D14: has iteration frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^iteration:"
  assert_file_contains "D15: has type frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^type:"
  assert_file_contains "D15b: has ITERATION placeholder" "$tmpl_dir/handoff-tech-to-business.md" "{{ITERATION}}"
  assert_file_contains "D15c: has DATE placeholder" "$tmpl_dir/handoff-tech-to-business.md" "{{DATE}}"

  # D16-D20: roundtrip-signoff.md
  assert_file_exists "D16: roundtrip-signoff.md exists" "$tmpl_dir/roundtrip-signoff.md"
  assert_file_contains "D17: has feature frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^feature:"
  assert_file_contains "D18: has roundtrip frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^roundtrip:"
  assert_file_contains "D19: has signed_by frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^signed_by:"
  assert_file_contains "D20: has status frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^status:"
  assert_file_contains "D20b: has FEATURE_NAME placeholder" "$tmpl_dir/roundtrip-signoff.md" "{{FEATURE_NAME}}"
  assert_file_contains "D20c: has ROUNDTRIP_NUMBER placeholder" "$tmpl_dir/roundtrip-signoff.md" "{{ROUNDTRIP_NUMBER}}"
  assert_file_contains "D20d: has DATE placeholder" "$tmpl_dir/roundtrip-signoff.md" "{{DATE}}"

  # D21-D25: solution-signoff.md
  assert_file_exists "D21: solution-signoff.md exists" "$tmpl_dir/solution-signoff.md"
  assert_file_contains "D22: has date frontmatter" "$tmpl_dir/solution-signoff.md" "^date:"
  assert_file_contains "D23: has signed_by frontmatter" "$tmpl_dir/solution-signoff.md" "^signed_by:"
  assert_file_contains "D24: has status frontmatter" "$tmpl_dir/solution-signoff.md" "^status:"
  assert_file_contains "D25: has iteration_count frontmatter" "$tmpl_dir/solution-signoff.md" "^iteration_count:"
  assert_file_contains "D25b: has TOTAL_ITERATIONS placeholder" "$tmpl_dir/solution-signoff.md" "{{TOTAL_ITERATIONS}}"
  assert_file_contains "D25c: has ESTONIAN_SUMMARY placeholder" "$tmpl_dir/solution-signoff.md" "{{ESTONIAN_SUMMARY}}"
  assert_file_contains "D25d: has DATE placeholder" "$tmpl_dir/solution-signoff.md" "{{DATE}}"

  # D26-D28: human-tasks.md
  assert_file_exists "D26: human-tasks.md exists" "$tmpl_dir/human-tasks.md"
  assert_file_contains "D27: has Pending section" "$tmpl_dir/human-tasks.md" "## Pending"
  assert_file_contains "D28: has Completed section" "$tmpl_dir/human-tasks.md" "## Completed"
}

# ---------------------------------------------------------------------------
# Suite E: Plugin Configuration
# ---------------------------------------------------------------------------

test_plugin_config() {
  echo -e "\n${CYAN}Suite E: Plugin Configuration${NC}"

  # E1-E4: plugin.json
  assert_json_valid "E1: plugin.json is valid JSON" "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_json_field "E2: plugin.json has name" "$PLUGIN_ROOT/.claude-plugin/plugin.json" ".name" "saas-startup-team"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local ver
  ver=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "  ${GREEN}PASS${NC} E3: plugin.json version is valid semver ($ver)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} E3: plugin.json version is not valid semver ($ver)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("E3: plugin.json version not valid semver: $ver")
  fi
  local desc
  desc=$(jq -r '.description' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$desc" ] && [ "$desc" != "null" ]; then
    echo -e "  ${GREEN}PASS${NC} E4: plugin.json has description"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} E4: plugin.json missing description"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("E4: plugin.json missing description")
  fi

  # E5-E6: settings.json
  assert_json_valid "E5: settings.json is valid JSON" "$PLUGIN_ROOT/settings.json"
  assert_json_field "E6: Agent Teams enabled" "$PLUGIN_ROOT/settings.json" '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' "1"

  # E7-E10: hooks.json
  assert_json_valid "E7: hooks.json is valid JSON" "$PLUGIN_ROOT/hooks/hooks.json"
  local hooks_keys
  hooks_keys=$(jq -r '.hooks | keys[]' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_contains "E8: hooks.json has TeammateIdle" "$hooks_keys" "TeammateIdle"
  assert_output_contains "E9: hooks.json has TaskCompleted" "$hooks_keys" "TaskCompleted"
  assert_output_contains "E10: hooks.json has Stop" "$hooks_keys" "Stop"

  # C-enforce: PreToolUse enforce-handoff-naming.sh is registered
  local enforce_cmd
  enforce_cmd=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$PLUGIN_ROOT/hooks/hooks.json" | grep -F "enforce-handoff-naming.sh" || true)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$enforce_cmd" ]; then
    echo -e "  ${GREEN}PASS${NC} C-enforce: PreToolUse hook registers enforce-handoff-naming.sh"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} C-enforce: PreToolUse hook does not register enforce-handoff-naming.sh"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("C-enforce: missing enforce-handoff-naming.sh in PreToolUse")
  fi

  # C-enforce-matcher: the entry uses matcher "Write"
  local enforce_matcher
  enforce_matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | test("enforce-handoff-naming.sh")) | .matcher // empty' "$PLUGIN_ROOT/hooks/hooks.json")
  assert_equals "C-enforce-matcher: matcher is Write" "$enforce_matcher" "Write"
}

# ---------------------------------------------------------------------------
# Suite F: Stop Hook (check-stop.sh)
# ---------------------------------------------------------------------------

test_stop_hook() {
  echo -e "\n${CYAN}Suite F: Stop Hook${NC}"
  local workdir ec output
  local SCRIPT="$PLUGIN_ROOT/scripts/check-stop.sh"

  # F1: check-stop.sh exists
  assert_file_exists "F1: check-stop.sh exists" "$SCRIPT"

  # F2: check-stop.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$SCRIPT" ]; then
    echo -e "  ${GREEN}PASS${NC} F2: check-stop.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} F2: check-stop.sh is executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("F2: check-stop.sh not executable")
  fi

  # F3: Has team-member bypass (checks --agent-id in process tree)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -q -- '--agent-id' "$SCRIPT"; then
    echo -e "  ${GREEN}PASS${NC} F3: has team-member bypass (--agent-id check)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} F3: missing team-member bypass"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("F3: check-stop.sh missing --agent-id team-member bypass")
  fi

  # F4: no git repo → exit 0 (allow stop)
  workdir=$(make_workdir)
  ec=0; (cd "$workdir" && bash "$SCRIPT") || ec=$?
  assert_exit_code "F4: no git repo → allow stop" "$ec" 0
  rm -rf "$workdir"

  # F5: no .startup dir → exit 0
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q)
  ec=0; (cd "$workdir" && bash "$SCRIPT") || ec=$?
  assert_exit_code "F5: no .startup dir → allow stop" "$ec" 0
  rm -rf "$workdir"

  # F6: iteration < 2 → exit 0 (allow stop)
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup)
  echo '{"iteration": 1, "phase": "research"}' > "$workdir/.startup/state.json"
  ec=0; (cd "$workdir" && bash "$SCRIPT") || ec=$?
  assert_exit_code "F6: iteration 1 → allow stop" "$ec" 0
  rm -rf "$workdir"

  # F7: iteration >= 2, no signoff → exit 2 (block stop)
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 2, "phase": "implementation"}' > "$workdir/.startup/state.json"
  ec=0; output=$( (cd "$workdir" && bash "$SCRIPT") 2>&1 ) || ec=$?
  assert_exit_code "F7: iteration 2 no signoff → block stop" "$ec" 2
  rm -rf "$workdir"

  # F8: iteration >= 2 with signoff → exit 0 (allow stop)
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 3, "phase": "implementation"}' > "$workdir/.startup/state.json"
  echo "signed off" > "$workdir/.startup/go-live/solution-signoff.md"
  ec=0; (cd "$workdir" && bash "$SCRIPT") || ec=$?
  assert_exit_code "F8: iteration 3 with signoff → allow stop" "$ec" 0
  rm -rf "$workdir"

  # F9: block message includes iteration and phase
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 4, "phase": "review"}' > "$workdir/.startup/state.json"
  ec=0; output=$( (cd "$workdir" && bash "$SCRIPT") 2>&1 ) || ec=$?
  assert_output_contains "F9: block message shows iteration" "$output" "iteration 4"
  assert_output_contains "F9b: block message shows phase" "$output" "review"
  rm -rf "$workdir"

  # F10: hooks.json Stop entry references check-stop.sh
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if jq -e '.hooks.Stop[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null | grep -q 'check-stop.sh'; then
    echo -e "  ${GREEN}PASS${NC} F10: hooks.json Stop references check-stop.sh"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} F10: hooks.json Stop missing check-stop.sh reference"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("F10: hooks.json Stop entry missing check-stop.sh")
  fi

  # F11: status=paused bypasses the block — /pause escape hatch
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review", "status": "paused"}' > "$workdir/.startup/state.json"
  ec=0; (cd "$workdir" && bash "$SCRIPT" < /dev/null) || ec=$?
  assert_exit_code "F11: status=paused → allow stop" "$ec" 0
  rm -rf "$workdir"

  # F12: transcript with last assistant tool_use = ScheduleWakeup → allow stop
  # Regression for the 742-block runaway in /loop + async-Agent sessions.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  cat > "$workdir/.startup/transcript.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do work"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"polling"},{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":270}}]}}
EOF
  ec=0; (cd "$workdir" && printf '{"transcript_path":"%s/.startup/transcript.jsonl"}' "$workdir" | bash "$SCRIPT") || ec=$?
  assert_exit_code "F12: last tool_use=ScheduleWakeup → allow stop" "$ec" 0
  rm -rf "$workdir"

  # F13: transcript with last assistant tool_use != ScheduleWakeup → still blocks
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  cat > "$workdir/.startup/transcript.jsonl" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":270}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"woke"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
EOF
  ec=0; (cd "$workdir" && printf '{"transcript_path":"%s/.startup/transcript.jsonl"}' "$workdir" | bash "$SCRIPT") || ec=$?
  assert_exit_code "F13: last tool_use=Bash → block stop (baseline preserved)" "$ec" 2
  rm -rf "$workdir"

  # F14: missing transcript_path → falls back to default behavior (blocks)
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  ec=0; (cd "$workdir" && echo '{}' | bash "$SCRIPT") || ec=$?
  assert_exit_code "F14: missing transcript_path → block stop" "$ec" 2
  rm -rf "$workdir"

  # F15: malformed transcript JSONL → falls back to default behavior (blocks)
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  echo 'not valid json' > "$workdir/.startup/transcript.jsonl"
  ec=0; (cd "$workdir" && printf '{"transcript_path":"%s/.startup/transcript.jsonl"}' "$workdir" | bash "$SCRIPT") || ec=$?
  assert_exit_code "F15: malformed transcript → block stop (safe default)" "$ec" 2
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite G: Startup Initialization Simulation
# ---------------------------------------------------------------------------

test_startup_init() {
  echo -e "\n${CYAN}Suite G: Startup Initialization Simulation${NC}"

  # Simulate what the /startup command creates
  local workdir
  workdir=$(make_workdir)

  # Create the directory structure as specified in startup.md
  mkdir -p "$workdir/.startup/handoffs"
  mkdir -p "$workdir/.startup/docs"
  mkdir -p "$workdir/.startup/signoffs"
  mkdir -p "$workdir/.startup/reviews"
  mkdir -p "$workdir/.startup/go-live"

  cat > "$workdir/.startup/state.json" <<'EOF'
{
  "iteration": 0,
  "max_iterations": 20,
  "phase": "research",
  "active_role": "business-founder",
  "status": "active",
  "started": "2026-02-23T10:00:00Z"
}
EOF

  cat > "$workdir/.startup/brief.md" <<'EOF'
# Startup Brief

## SaaS Idea
A project management tool for Estonian small businesses.
EOF

  cp "$PLUGIN_ROOT/templates/human-tasks.md" "$workdir/.startup/human-tasks.md"

  # G1-G5: Directory structure
  assert_file_exists "G1: handoffs/ dir exists" "$workdir/.startup/handoffs"
  assert_file_exists "G2: docs/ dir exists" "$workdir/.startup/docs"
  assert_file_exists "G3: signoffs/ dir exists" "$workdir/.startup/signoffs"
  assert_file_exists "G4: reviews/ dir exists" "$workdir/.startup/reviews"
  assert_file_exists "G5: go-live/ dir exists" "$workdir/.startup/go-live"

  # G6-G11: state.json schema
  assert_json_valid "G6: state.json is valid JSON" "$workdir/.startup/state.json"
  assert_json_field "G7: iteration is 0" "$workdir/.startup/state.json" ".iteration" "0"
  assert_json_field "G8: max_iterations is 20" "$workdir/.startup/state.json" ".max_iterations" "20"
  assert_json_field "G9: phase is research" "$workdir/.startup/state.json" ".phase" "research"
  assert_json_field "G10: active_role is business-founder" "$workdir/.startup/state.json" ".active_role" "business-founder"
  assert_json_field "G11: status is active" "$workdir/.startup/state.json" ".status" "active"

  # G12: started field exists
  local started
  started=$(jq -r '.started // empty' "$workdir/.startup/state.json" 2>/dev/null)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$started" ]; then
    echo -e "  ${GREEN}PASS${NC} G12: state.json has started field"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} G12: state.json missing started field"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("G12: state.json missing started field")
  fi

  # G13: brief.md is non-empty
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -s "$workdir/.startup/brief.md" ]; then
    echo -e "  ${GREEN}PASS${NC} G13: brief.md is non-empty"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} G13: brief.md is empty or missing"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("G13: brief.md is empty or missing")
  fi

  # G14: human-tasks.md matches template structure
  assert_file_contains "G14: human-tasks has Pending section" "$workdir/.startup/human-tasks.md" "## Pending"
  assert_file_contains "G15: human-tasks has Completed section" "$workdir/.startup/human-tasks.md" "## Completed"

  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite H: Cross-File Consistency
# ---------------------------------------------------------------------------

test_cross_file_consistency() {
  echo -e "\n${CYAN}Suite H: Cross-File Consistency${NC}"

  # H1-H2: Hook script paths resolve to real files
  local idle_script task_script
  idle_script=$(jq -r '.hooks.TeammateIdle[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  task_script=$(jq -r '.hooks.TaskCompleted[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)

  # Replace ${CLAUDE_PLUGIN_ROOT} with actual plugin root
  idle_script="${idle_script//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}"
  task_script="${task_script//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}"

  assert_file_exists "H1: TeammateIdle hook script exists" "$idle_script"
  assert_file_exists "H2: TaskCompleted hook script exists" "$task_script"

  # H3-H4: Agent names in agents/*.md match what check-idle.sh handles
  local biz_name tech_name
  biz_name=$(grep '^name:' "$PLUGIN_ROOT/agents/business-founder.md" | head -1 | sed 's/^name: *//')
  tech_name=$(grep '^name:' "$PLUGIN_ROOT/agents/tech-founder.md" | head -1 | sed 's/^name: *//')

  # check-idle.sh handles "business-founder" and "tech-founder"
  assert_equals "H3: business-founder agent name matches script" "$biz_name" "business-founder"
  assert_equals "H4: tech-founder agent name matches script" "$tech_name" "tech-founder"

  # H5-H6: check-idle.sh patterns match template filenames
  assert_file_contains "H5: check-idle.sh handles business-to-tech pattern" \
    "$PLUGIN_ROOT/scripts/check-idle.sh" "business-to-tech"
  assert_file_contains "H6: check-idle.sh handles tech-to-business pattern" \
    "$PLUGIN_ROOT/scripts/check-idle.sh" "tech-to-business"

  # H7: Template filenames match the patterns that scripts expect
  assert_file_exists "H7: handoff-business-to-tech template exists" \
    "$PLUGIN_ROOT/templates/handoff-business-to-tech.md"
  assert_file_exists "H8: handoff-tech-to-business template exists" \
    "$PLUGIN_ROOT/templates/handoff-tech-to-business.md"

  # H9: Scripts are executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$PLUGIN_ROOT/scripts/check-idle.sh" ]; then
    echo -e "  ${GREEN}PASS${NC} H9: check-idle.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} H9: check-idle.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("H9: check-idle.sh is not executable")
  fi

  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$PLUGIN_ROOT/scripts/check-task-complete.sh" ]; then
    echo -e "  ${GREEN}PASS${NC} H10: check-task-complete.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} H10: check-task-complete.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("H10: check-task-complete.sh is not executable")
  fi

  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$PLUGIN_ROOT/scripts/status.sh" ]; then
    echo -e "  ${GREEN}PASS${NC} H11: status.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} H11: status.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("H11: status.sh is not executable")
  fi

  # H12-H15: Non-/startup commands reset active_role before dispatching
  # subagents. Regression guard for v0.26.0 — stops enforce-delegation from
  # firing on stale team-lead state left by a prior /startup session.
  assert_file_contains "H12: /improve resets active_role" \
    "$PLUGIN_ROOT/commands/improve.md" '.active_role = "business-founder-maintain"'
  assert_file_contains "H13: /lawyer resets active_role" \
    "$PLUGIN_ROOT/commands/lawyer.md" '.active_role = "lawyer"'
  assert_file_contains "H14: /ux-test resets active_role" \
    "$PLUGIN_ROOT/commands/ux-test.md" '.active_role = "ux-tester"'
  assert_file_contains "H15: /growth state update sets active_role" \
    "$PLUGIN_ROOT/commands/growth.md" '"active_role": "business-founder"'

  # H16-H17: Orchestrator is warned never to write active_role=team-lead.
  assert_file_contains "H16: startup.md warns against team-lead active_role" \
    "$PLUGIN_ROOT/commands/startup.md" 'Never write `active_role: "team-lead"`'
  assert_file_contains "H17: orchestration skill warns against team-lead active_role" \
    "$PLUGIN_ROOT/skills/startup-orchestration/SKILL.md" 'Never write `active_role: "team-lead"`'

  # H18-H20: v0.27.0 — /pause command and sync-vs-async dispatch guidance.
  assert_file_exists "H18: /pause command exists" "$PLUGIN_ROOT/commands/pause.md"
  assert_file_contains "H18b: /pause sets status=paused" \
    "$PLUGIN_ROOT/commands/pause.md" '.status = "paused"'
  assert_file_contains "H19: startup.md documents sync vs async dispatch" \
    "$PLUGIN_ROOT/commands/startup.md" 'Sync vs. async dispatch'
  assert_file_contains "H20: startup.md clears paused status on resume" \
    "$PLUGIN_ROOT/commands/startup.md" 'status == "paused"'
}

# ---------------------------------------------------------------------------
# Suite I: PostToolUse Hook
# ---------------------------------------------------------------------------

test_post_tool_use_hook() {
  echo -e "\n${CYAN}Suite I: PostToolUse Hook${NC}"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
  local script="$PLUGIN_ROOT/scripts/auto-learn.sh"

  # I1: hooks.json has PostToolUse key
  local hooks_keys
  hooks_keys=$(jq -r '.hooks | keys[]' "$hooks_file" 2>/dev/null)
  assert_output_contains "I1: hooks.json has PostToolUse key" "$hooks_keys" "PostToolUse"

  # I2: PostToolUse matcher covers Edit|Write
  local matcher
  matcher=$(jq -r '.hooks.PostToolUse[0].matcher' "$hooks_file" 2>/dev/null)
  assert_output_contains "I2: PostToolUse matcher covers Edit" "$matcher" "Edit"
  assert_output_contains "I2b: PostToolUse matcher covers Write" "$matcher" "Write"

  # I3: PostToolUse hook type is "command" (deterministic path filtering)
  assert_json_field "I3: PostToolUse hook type is command" "$hooks_file" \
    '.hooks.PostToolUse[0].hooks[0].type' "command"

  # I4: auto-learn.sh script exists and is executable
  assert_file_exists "I4: auto-learn.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} I4b: auto-learn.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} I4b: auto-learn.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("I4b: auto-learn.sh is not executable")
  fi

  # I5: auto-learn.sh contains .startup/ path check
  assert_file_contains "I5: auto-learn.sh has .startup/ path check" "$script" "\.startup/"

  # I6: auto-learn.sh systemMessage contains Learnings section reference
  assert_file_contains "I6: auto-learn.sh references Learnings section" "$script" "## Learnings"

  # I7: auto-learn.sh systemMessage contains duplicate-skip instruction
  assert_file_contains "I7: auto-learn.sh contains duplicate-skip instruction" "$script" "semantically equivalent"

  # I8: auto-learn.sh exits 0 silently for non-matching file
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "I8: exits 0 for non-matching file" "$ec" 0
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -z "$output" ]; then
    echo -e "  ${GREEN}PASS${NC} I8b: no output for non-matching file"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} I8b: unexpected output for non-matching file: '$output'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("I8b: unexpected output for non-matching file")
  fi

  # I9: auto-learn.sh exits 0 silently for .startup/state.json (not a target subdir)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/state.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "I9: exits 0 for .startup/state.json" "$ec" 0

  # I10: auto-learn.sh exits 2 with systemMessage for matching handoff file
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "I10: exits 2 for matching handoff file" "$ec" 2
  assert_output_contains "I10b: systemMessage in output" "$output" "systemMessage"
}

# ---------------------------------------------------------------------------
# Suite J: Plugin-issue reporting via GitHub
# ---------------------------------------------------------------------------
# The local PLUGIN_ISSUES.md workflow was retired in v0.30.1 — it was never
# aggregated across downstream projects, so feedback was lost. Agents now file
# GitHub issues directly on the plugin repo. These tests enforce the new
# guidance is present and the old file/seeds are gone.

test_plugin_issues() {
  echo -e "\n${CYAN}Suite J: plugin-issue reporting via GitHub${NC}"

  # J1: the template file is gone from plugin root
  if [[ ! -f "$PLUGIN_ROOT/PLUGIN_ISSUES.md" ]]; then
    echo -e "  ${GREEN}PASS${NC} J1: PLUGIN_ISSUES.md removed from plugin root"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} J1: PLUGIN_ISSUES.md still exists at plugin root"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # J2-J5: the four primary issue-filing agents point at gh, not the old file
  for agent in business-founder.md tech-founder.md tech-founder-maintain.md business-founder-maintain.md; do
    assert_file_contains "J-gh: $agent points to gh issue create" \
      "$PLUGIN_ROOT/agents/$agent" "gh issue create --repo paat/claude-plugins"
  done

  # J-bootstrap: bootstrap no longer seeds .startup/PLUGIN_ISSUES.md
  if ! grep -q "PLUGIN_ISSUES" "$PLUGIN_ROOT/commands/bootstrap.md"; then
    echo -e "  ${GREEN}PASS${NC} J-bootstrap: bootstrap.md no longer seeds PLUGIN_ISSUES.md"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} J-bootstrap: bootstrap.md still references PLUGIN_ISSUES"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # J-startup: startup no longer seeds .startup/PLUGIN_ISSUES.md either
  if ! grep -q "PLUGIN_ISSUES" "$PLUGIN_ROOT/commands/startup.md"; then
    echo -e "  ${GREEN}PASS${NC} J-startup: startup.md no longer seeds PLUGIN_ISSUES.md"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} J-startup: startup.md still references PLUGIN_ISSUES"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# Suite K: Auto-Commit Hook
# ---------------------------------------------------------------------------

test_auto_commit_hook() {
  echo -e "\n${CYAN}Suite K: Auto-Commit Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/auto-commit.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # K1: auto-commit.sh exists
  assert_file_exists "K1: auto-commit.sh exists" "$script"

  # K2: auto-commit.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} K2: auto-commit.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} K2: auto-commit.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("K2: auto-commit.sh is not executable")
  fi

  # K3: Has .startup/handoffs/ path filter
  assert_file_contains "K3: has .startup/handoffs/ path filter" "$script" "\.startup/handoffs/"

  # K3b: Has .startup/signoffs/ path filter
  assert_file_contains "K3b: has .startup/signoffs/ path filter" "$script" "\.startup/signoffs/"

  # K3c: Has .startup/reviews/ path filter
  assert_file_contains "K3c: has .startup/reviews/ path filter" "$script" "\.startup/reviews/"

  # K4: Uses git rev-parse --show-toplevel
  assert_file_contains "K4: uses git rev-parse --show-toplevel" "$script" "git rev-parse --show-toplevel"

  # K5: Exits 0 for non-handoff file
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "K5: exits 0 for non-handoff file" "$ec" 0

  # K6: Exits 0 for .startup/state.json (not a handoff)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/state.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "K6: exits 0 for .startup/state.json" "$ec" 0

  # K7: hooks.json PostToolUse has 13 entries
  local ptu_count
  ptu_count=$(jq '.hooks.PostToolUse | length' "$hooks_file" 2>/dev/null)
  assert_equals "K7: PostToolUse has 13 entries" "$ptu_count" "13"

  # K8: Fourth PostToolUse entry references auto-commit.sh
  local fourth_cmd
  fourth_cmd=$(jq -r '.hooks.PostToolUse[3].hooks[0].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "K8: fourth PostToolUse references auto-commit.sh" "$fourth_cmd" "auto-commit.sh"

  # K9: Uses --no-verify flag
  assert_file_contains "K9: uses --no-verify flag" "$script" "\-\-no-verify"

  # K10: Functional test — handoff write in a git repo creates a commit
  local workdir
  workdir=$(mktemp -d)
  git init -q "$workdir"
  (cd "$workdir" && git config user.email "test@test.com" && git config user.name "Test" && git commit --allow-empty -m "init" -q)
  mkdir -p "$workdir/.startup/handoffs"
  echo '{"iteration":1}' > "$workdir/.startup/state.json"
  mkdir -p "$workdir/backend"
  echo "test app code" > "$workdir/backend/app.py"
  echo "handoff content" > "$workdir/.startup/handoffs/001-business-to-tech.md"

  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?

  local commit_count
  commit_count=$(cd "$workdir" && git log --oneline 2>/dev/null | wc -l)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$commit_count" -ge 2 ]; then
    echo -e "  ${GREEN}PASS${NC} K10: functional test — handoff creates commit ($commit_count commits)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} K10: functional test — expected >=2 commits, got $commit_count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("K10: expected >=2 commits, got $commit_count")
  fi
  rm -rf "$workdir"

  # K11: Functional test — signoff write in a git repo creates a commit
  workdir=$(mktemp -d)
  git init -q "$workdir"
  (cd "$workdir" && git config user.email "test@test.com" && git config user.name "Test" && git commit --allow-empty -m "init" -q)
  mkdir -p "$workdir/.startup/signoffs"
  echo "signoff content" > "$workdir/.startup/signoffs/mvp-core.md"

  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/signoffs/mvp-core.md"}}' | bash "$script" 2>&1) || ec=$?

  commit_count=$(cd "$workdir" && git log --oneline 2>/dev/null | wc -l)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$commit_count" -ge 2 ]; then
    echo -e "  ${GREEN}PASS${NC} K11: functional test — signoff creates commit ($commit_count commits)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} K11: functional test — expected >=2 commits, got $commit_count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("K11: expected >=2 commits, got $commit_count")
  fi

  # K11b: Commit message contains "signoff:"
  local last_msg
  last_msg=$(cd "$workdir" && git log -1 --format=%s 2>/dev/null)
  assert_output_contains "K11b: signoff commit message format" "$last_msg" "signoff: mvp-core"
  rm -rf "$workdir"

  # K12: Functional test — review write in a git repo creates a commit
  workdir=$(mktemp -d)
  git init -q "$workdir"
  (cd "$workdir" && git config user.email "test@test.com" && git config user.name "Test" && git commit --allow-empty -m "init" -q)
  mkdir -p "$workdir/.startup/reviews"
  echo "review content" > "$workdir/.startup/reviews/iteration-1.md"

  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/reviews/iteration-1.md"}}' | bash "$script" 2>&1) || ec=$?

  commit_count=$(cd "$workdir" && git log --oneline 2>/dev/null | wc -l)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$commit_count" -ge 2 ]; then
    echo -e "  ${GREEN}PASS${NC} K12: functional test — review creates commit ($commit_count commits)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} K12: functional test — expected >=2 commits, got $commit_count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("K12: expected >=2 commits, got $commit_count")
  fi

  # K12b: Commit message contains "review:"
  last_msg=$(cd "$workdir" && git log -1 --format=%s 2>/dev/null)
  assert_output_contains "K12b: review commit message format" "$last_msg" "review: iteration-1"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite L: Tone Enforcement Hook
# ---------------------------------------------------------------------------

test_tone_enforcement_hook() {
  echo -e "\n${CYAN}Suite L: Tone Enforcement Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/enforce-tone.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # L1: enforce-tone.sh exists
  assert_file_exists "L1: enforce-tone.sh exists" "$script"

  # L2: enforce-tone.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} L2: enforce-tone.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} L2: enforce-tone.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("L2: enforce-tone.sh is not executable")
  fi

  # L3: Has .startup/handoffs/ path filter
  assert_file_contains "L3: has .startup/handoffs/ path filter" "$script" "\.startup/handoffs/"

  # L4: Exits 0 for non-handoff file (e.g., src/main.py)
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "L4: exits 0 for non-handoff file" "$ec" 0

  # L5: Exits 0 for .startup/state.json
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/state.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "L5: exits 0 for .startup/state.json" "$ec" 0

  # L6: Exits 0 for handoff without violations (clean production language)
  local workdir
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/001-business-to-tech.md" <<'EOF'
# Handoff 001: Business to Tech

## Summary
We need to build the initial release of the company search feature.
This is a production implementation targeting real customers.

## Requirements
- Full-text search across company names
- Filter by county and legal form
- Production-grade error handling
EOF
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "L6: exits 0 for clean handoff" "$ec" 0
  rm -rf "$workdir"

  # L7: Exits 2 with systemMessage for handoff containing "MVP"
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/001-business-to-tech.md" <<'EOF'
# Handoff 001: Business to Tech

## Summary
Build an MVP of the company search feature.
We just need the basics working for now.
EOF
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "L7: exits 2 for handoff with MVP" "$ec" 2
  assert_output_contains "L7b: systemMessage in output" "$output" "systemMessage"
  rm -rf "$workdir"

  # L8: Exits 2 for handoff containing "prototype"
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/002-tech-to-business.md" <<'EOF'
# Handoff 002: Tech to Business

## Summary
I built a prototype of the search feature.
Please review it in the browser.
EOF
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/002-tech-to-business.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "L8: exits 2 for handoff with prototype" "$ec" 2
  rm -rf "$workdir"

  # L9: Exits 0 when "MVP" appears in a NEVER/ALWAYS guideline line (false positive protection)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/001-business-to-tech.md" <<'EOF'
# Handoff 001: Business to Tech

## Guidelines
- NEVER use MVP language in customer-facing materials
- ALWAYS build production-quality features, do not use prototype approaches
- You must not refer to this as an MVP

## Summary
Build the initial release of the company search feature.
EOF
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "L9: exits 0 when MVP in NEVER/ALWAYS line" "$ec" 0
  rm -rf "$workdir"

  # L10: hooks.json PostToolUse has 13 entries
  local ptu_count
  ptu_count=$(jq '.hooks.PostToolUse | length' "$hooks_file" 2>/dev/null)
  assert_equals "L10: PostToolUse has 13 entries" "$ptu_count" "13"

  # L11: Fifth PostToolUse entry references enforce-tone.sh
  local sixth_cmd
  sixth_cmd=$(jq -r '.hooks.PostToolUse[5].hooks[0].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "L11: sixth PostToolUse references enforce-tone.sh" "$sixth_cmd" "enforce-tone.sh"
}

# ---------------------------------------------------------------------------
# Suite M: JSON Validation Hook
# ---------------------------------------------------------------------------

test_json_validation_hook() {
  echo -e "\n${CYAN}Suite M: JSON Validation Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/validate-json.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # M1: validate-json.sh exists
  assert_file_exists "M1: validate-json.sh exists" "$script"

  # M2: validate-json.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} M2: validate-json.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} M2: validate-json.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("M2: validate-json.sh is not executable")
  fi

  # M3: hooks.json references validate-json.sh
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "M3: hooks.json references validate-json.sh" "$hook_refs" "validate-json.sh"

  # M4: Exits 0 for non-JSON file
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M4: exits 0 for non-JSON file" "$ec" 0

  # M5: Exits 0 for valid JSON file
  local workdir
  workdir=$(mktemp -d)
  echo '{"key": "value", "count": 1}' > "$workdir/test.json"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/test.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M5: exits 0 for valid JSON" "$ec" 0
  rm -rf "$workdir"

  # M6: Exits 2 for JSON with trailing comma
  workdir=$(mktemp -d)
  cat > "$workdir/bad.json" <<'EOF'
{
  "key": "value",
  "count": 1,
}
EOF
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/bad.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M6: exits 2 for JSON with trailing comma" "$ec" 2
  assert_output_contains "M6b: systemMessage in output" "$output" "systemMessage"
  rm -rf "$workdir"

  # M7: Exits 2 for JSON with missing closing bracket
  workdir=$(mktemp -d)
  echo '{"key": "value"' > "$workdir/unclosed.json"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/unclosed.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M7: exits 2 for unclosed JSON" "$ec" 2
  rm -rf "$workdir"

  # M8: Exits 0 for empty file_path
  ec=0; output=""
  output=$(echo '{"tool_input":{}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M8: exits 0 for empty file_path" "$ec" 0

  # M9: Exits 0 for nonexistent JSON file (file deleted after edit)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/tmp/nonexistent-test-12345.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M9: exits 0 for nonexistent file" "$ec" 0
}

# ---------------------------------------------------------------------------
# Suite N: Delegation Enforcement Hook
# ---------------------------------------------------------------------------

test_delegation_enforcement_hook() {
  echo -e "\n${CYAN}Suite N: Delegation Enforcement Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/enforce-delegation.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # N1: enforce-delegation.sh exists
  assert_file_exists "N1: enforce-delegation.sh exists" "$script"

  # N2: enforce-delegation.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} N2: enforce-delegation.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} N2: enforce-delegation.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("N2: enforce-delegation.sh is not executable")
  fi

  # N3: hooks.json references enforce-delegation.sh
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "N3: hooks.json references enforce-delegation.sh" "$hook_refs" "enforce-delegation.sh"

  # N4: Script checks .startup directory existence
  assert_file_contains "N4: checks .startup directory" "$script" "\.startup"

  # N5: Script allows writes to CLAUDE.md
  assert_file_contains "N5: allows CLAUDE.md writes" "$script" "CLAUDE\.md"

  # N6: Script has systemMessage in block output
  assert_file_contains "N6: has systemMessage in block" "$script" "systemMessage"

  # N7: Exits 0 for .startup/ file path (always allowed)
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "N7: exits 0 for .startup/ path" "$ec" 0

  # N8: Exits 0 for CLAUDE.md path (always allowed)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/CLAUDE.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "N8: exits 0 for CLAUDE.md path" "$ec" 0

  # N9: Exits 0 when no .startup directory exists (not an active project)
  local workdir
  workdir=$(mktemp -d)
  git init -q "$workdir"
  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/src/app.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "N9: exits 0 when no .startup dir" "$ec" 0
  rm -rf "$workdir"

  # N10: Exits 2 when active_role is explicitly team-lead and editing source code
  workdir=$(mktemp -d)
  git init -q "$workdir"
  mkdir -p "$workdir/.startup"
  echo '{"active_role":"team-lead"}' > "$workdir/.startup/state.json"
  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/src/app.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "N10: exits 2 when active_role=team-lead edits source" "$ec" 2
  assert_output_contains "N10b: systemMessage present" "$output" "systemMessage"
  rm -rf "$workdir"

  # N11: Exits 0 when active_role is absent — no orchestrator context to enforce
  # (regression: /improve, /lawyer, and direct agent invocations hit this path)
  workdir=$(mktemp -d)
  git init -q "$workdir"
  mkdir -p "$workdir/.startup"
  echo '{}' > "$workdir/.startup/state.json"
  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/src/app.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "N11: exits 0 when active_role absent" "$ec" 0
  rm -rf "$workdir"

  # N12: Exits 0 when active_role is a team-member variant (e.g. tech-founder-maintain)
  workdir=$(mktemp -d)
  git init -q "$workdir"
  mkdir -p "$workdir/.startup"
  echo '{"active_role":"tech-founder-maintain"}' > "$workdir/.startup/state.json"
  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/src/app.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "N12: exits 0 when active_role=tech-founder-maintain" "$ec" 0
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite O: Duplicate Handoff Prevention Hook
# ---------------------------------------------------------------------------

test_duplicate_handoff_hook() {
  echo -e "\n${CYAN}Suite O: Duplicate Handoff Prevention Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/check-duplicate-handoff.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # O1: check-duplicate-handoff.sh exists
  assert_file_exists "O1: check-duplicate-handoff.sh exists" "$script"

  # O2: check-duplicate-handoff.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} O2: check-duplicate-handoff.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} O2: check-duplicate-handoff.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("O2: check-duplicate-handoff.sh is not executable")
  fi

  # O3: hooks.json references check-duplicate-handoff.sh
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "O3: hooks.json references check-duplicate-handoff.sh" "$hook_refs" "check-duplicate-handoff.sh"

  # O4: Exits 0 for non-handoff file
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "O4: exits 0 for non-handoff file" "$ec" 0

  # O5: Exits 0 for first handoff (no duplicates possible)
  local workdir
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  echo "handoff content" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "O5: exits 0 for first handoff" "$ec" 0
  rm -rf "$workdir"

  # O6: Exits 0 for sequential handoffs (002 after 001, different direction)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  echo "handoff 1" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  echo "handoff 2" > "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/002-tech-to-business.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "O6: exits 0 for sequential handoffs" "$ec" 0
  rm -rf "$workdir"

  # O7: Exits 2 when writing handoff 001 but 003 already exists (same direction)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  echo "handoff 3" > "$workdir/.startup/handoffs/003-business-to-tech.md"
  echo "handoff 1 dup" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "O7: exits 2 for lower-numbered duplicate" "$ec" 2
  assert_output_contains "O7b: systemMessage in output" "$output" "systemMessage"
  rm -rf "$workdir"

  # O8: Exits 0 for empty file_path
  ec=0; output=""
  output=$(echo '{"tool_input":{}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "O8: exits 0 for empty file_path" "$ec" 0
}

# ---------------------------------------------------------------------------
# Suite P: compact-state.sh
# ---------------------------------------------------------------------------

# Helper: seed state.json with N handoff keys (ready + scope each).
seed_handoffs() {
  local state_file="$1" count="$2"
  local builder='.'
  local i padded
  for i in $(seq 1 "$count"); do
    padded=$(printf '%03d' "$i")
    builder="$builder + {\"handoff_${padded}_ready\": \"2026-02-01T10:00:00Z\", \"handoff_${padded}_scope\": \"Test scope $i\"}"
  done
  jq "$builder" "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
}

test_compact_state() {
  echo -e "\n${CYAN}Suite P: compact-state.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/compact-state.sh"
  local workdir ec output state before_hash after_hash

  # P1: script exists and is executable
  assert_file_exists "P1: compact-state.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} P1b: compact-state.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P1b: compact-state.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P1b: compact-state.sh is not executable")
  fi

  # P2: no-op on fresh state (no handoff_* keys)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  before_hash=$(md5sum "$workdir/.startup/state.json" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P2: fresh state exits 0" "$ec" 0
  after_hash=$(md5sum "$workdir/.startup/state.json" | awk '{print $1}')
  assert_equals "P2b: fresh state unchanged" "$after_hash" "$before_hash"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -f "$workdir/.startup/state-archive.json" ]; then
    echo -e "  ${GREEN}PASS${NC} P2c: no archive created for fresh state"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P2c: archive unexpectedly created"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P2c: archive unexpectedly created")
  fi
  rm -rf "$workdir"

  # P3: no-op when handoff count ≤ window (default 10)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  seed_handoffs "$workdir/.startup/state.json" 5
  before_hash=$(md5sum "$workdir/.startup/state.json" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P3: below threshold exits 0" "$ec" 0
  after_hash=$(md5sum "$workdir/.startup/state.json" | awk '{print $1}')
  assert_equals "P3b: below threshold unchanged" "$after_hash" "$before_hash"
  rm -rf "$workdir"

  # P4: compacts when handoff count > window
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P4: compaction exits 0" "$ec" 0
  assert_file_exists "P4b: archive file created" "$workdir/.startup/state-archive.json"
  assert_json_valid "P4c: state.json still valid" "$state"
  assert_json_valid "P4d: archive file valid JSON" "$workdir/.startup/state-archive.json"
  # Last 10 (6-15) remain inline; 1-5 archived
  assert_json_field "P4e: handoff_001 archived out" "$state" '.handoff_001_ready // "MISSING"' "MISSING"
  assert_json_field "P4f: handoff_005 archived out" "$state" '.handoff_005_ready // "MISSING"' "MISSING"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$(jq -r '.handoff_015_ready // "MISSING"' "$state")" != "MISSING" ]; then
    echo -e "  ${GREEN}PASS${NC} P4g: handoff_015 kept inline"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P4g: handoff_015 unexpectedly archived"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P4g: handoff_015 unexpectedly archived")
  fi
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$(jq -r '.handoff_006_ready // "MISSING"' "$state")" != "MISSING" ]; then
    echo -e "  ${GREEN}PASS${NC} P4h: handoff_006 kept inline (boundary)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P4h: handoff_006 wrongly archived (boundary)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P4h: handoff_006 wrongly archived")
  fi
  rm -rf "$workdir"

  # P5: coordination keys preserved after compaction
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_json_field "P5a: iteration preserved" "$state" ".iteration" "13"
  assert_json_field "P5b: phase preserved" "$state" ".phase" "implementation"
  assert_json_field "P5c: active_role preserved" "$state" ".active_role" "tech-founder"
  assert_json_field "P5d: status preserved" "$state" ".status" "active"
  assert_json_field "P5e: max_iterations preserved" "$state" ".max_iterations" "20"
  assert_json_field "P5f: started preserved" "$state" ".started" "2026-02-23T10:00:00Z"
  rm -rf "$workdir"

  # P6: schema_version, archived_through, latest_handoff added
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_json_field "P6a: schema_version = 2" "$state" ".schema_version" "2"
  assert_json_field "P6b: archived_through = 5" "$state" ".archived_through" "5"
  assert_json_field "P6c: latest_handoff = 15" "$state" ".latest_handoff" "15"
  rm -rf "$workdir"

  # P7: round-trip — inline ∪ archived ⊇ original keys
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  local original_keys merged_keys missing
  original_keys=$(jq -r 'keys[]' "$state" | sort)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  merged_keys=$(
    { jq -r 'keys[]' "$state"; \
      jq -r '.entries[].keys | keys[]' "$workdir/.startup/state-archive.json"; } \
    | grep -vE '^(schema_version|archived_through|latest_handoff)$' | sort -u
  )
  missing=$(comm -23 <(echo "$original_keys") <(echo "$merged_keys"))
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -z "$missing" ]; then
    echo -e "  ${GREEN}PASS${NC} P7: round-trip preserves all original keys"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P7: missing keys after compaction: $missing"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P7: missing keys: $missing")
  fi
  rm -rf "$workdir"

  # P8: idempotent — second run is a no-op
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  bash "$script" --state-file "$state" --archive-file "$workdir/.startup/state-archive.json" >/dev/null 2>&1 || true
  before_hash=$(md5sum "$state" | awk '{print $1}')
  ec=0; output=$(bash "$script" --state-file "$state" --archive-file "$workdir/.startup/state-archive.json" 2>&1) || ec=$?
  assert_exit_code "P8: second run exits 0" "$ec" 0
  after_hash=$(md5sum "$state" | awk '{print $1}')
  assert_equals "P8b: second run is no-op" "$after_hash" "$before_hash"
  rm -rf "$workdir"

  # P9: --dry-run does not write
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  before_hash=$(md5sum "$state" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" --dry-run 2>&1) || ec=$?
  assert_exit_code "P9: --dry-run exits 0" "$ec" 0
  after_hash=$(md5sum "$state" | awk '{print $1}')
  assert_equals "P9b: --dry-run leaves state.json unchanged" "$after_hash" "$before_hash"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -f "$workdir/.startup/state-archive.json" ]; then
    echo -e "  ${GREEN}PASS${NC} P9c: --dry-run created no archive"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P9c: --dry-run unexpectedly created archive"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P9c: --dry-run unexpectedly created archive")
  fi
  assert_output_contains "P9d: --dry-run output labelled" "$output" "DRY RUN"
  rm -rf "$workdir"

  # P10: no .startup/state.json → exit 0 silently
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P10: no state.json exits 0" "$ec" 0
  rm -rf "$workdir"

  # P11: historical keys (iterationN_signoff, signoff_vN) archived
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  jq '. + {"iteration8_signoff": "2026-02-26T01:00:00Z", "signoff_v2": "2026-02-25T20:10:00Z", "final_signoff": "2026-02-26T09:30:00Z"}' \
    "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P11: historical+handoffs compaction exits 0" "$ec" 0
  assert_json_field "P11b: iteration8_signoff archived" "$state" '.iteration8_signoff // "MISSING"' "MISSING"
  assert_json_field "P11c: signoff_v2 archived"        "$state" '.signoff_v2 // "MISSING"'        "MISSING"
  assert_json_field "P11d: final_signoff archived"     "$state" '.final_signoff // "MISSING"'     "MISSING"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$(jq -r '.entries[].keys.signoff_v2 // "MISSING"' "$workdir/.startup/state-archive.json")" != "MISSING" ]; then
    echo -e "  ${GREEN}PASS${NC} P11e: signoff_v2 present in archive"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P11e: signoff_v2 not in archive"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P11e: signoff_v2 not in archive")
  fi
  rm -rf "$workdir"

  # P12: growth_* keys preserved inline (never archived)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  jq '. + {"growth_phase": "launch", "growth_iteration": 2, "growth_last_brief": 399}' \
    "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_json_field "P12a: growth_phase preserved inline"    "$state" ".growth_phase" "launch"
  assert_json_field "P12b: growth_iteration preserved"       "$state" ".growth_iteration" "2"
  assert_json_field "P12c: growth_last_brief preserved"      "$state" ".growth_last_brief" "399"
  rm -rf "$workdir"

  # P13: archive append-only — two waves of compaction produce two entries
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  bash "$script" --state-file "$state" --archive-file "$workdir/.startup/state-archive.json" >/dev/null 2>&1 || true
  # Add 10 more handoffs (16-25), ensuring the next wave archives some of them.
  local builder='.'
  local i padded
  for i in $(seq 16 25); do
    padded=$(printf '%03d' "$i")
    builder="$builder + {\"handoff_${padded}_ready\": \"2026-03-01T10:00:00Z\"}"
  done
  jq "$builder" "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  bash "$script" --state-file "$state" --archive-file "$workdir/.startup/state-archive.json" >/dev/null 2>&1 || true
  local entry_count
  entry_count=$(jq '.entries | length' "$workdir/.startup/state-archive.json")
  assert_equals "P13: two archive entries after two waves" "$entry_count" "2"
  assert_json_valid "P13b: archive still valid JSON after two waves" "$workdir/.startup/state-archive.json"
  rm -rf "$workdir"

  # P14: state.json with schema_version=2 already set is accepted
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  jq '. + {"schema_version": 2, "archived_through": 0, "latest_handoff": 0}' \
    "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P14: schema v2 pre-set exits 0" "$ec" 0
  assert_json_field "P14b: schema_version stays 2" "$state" ".schema_version" "2"
  rm -rf "$workdir"

  # P15: historical keys are archived even when handoff count ≤ window
  # (Fixes a bug where 5 handoffs + 50 legacy keys yielded a no-op.)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  state="$workdir/.startup/state.json"
  jq '. + {
    "signoff_v2":        "2026-02-25T20:10:00Z",
    "iteration8_signoff":"2026-02-26T01:00:00Z",
    "final_signoff":     "2026-02-26T09:30:00Z",
    "legacy_feature_xx": "done"
  }' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  seed_handoffs "$state" 3                # well below window=10
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P15: historical-only compaction exits 0" "$ec" 0
  assert_file_exists "P15b: archive created for historical-only" "$workdir/.startup/state-archive.json"
  assert_json_field "P15c: signoff_v2 archived"         "$state" '.signoff_v2 // "MISSING"'         "MISSING"
  assert_json_field "P15d: legacy_feature_xx archived"  "$state" '.legacy_feature_xx // "MISSING"'  "MISSING"
  # Handoff keys must remain inline (count ≤ window → none archived)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$(jq -r '.handoff_001_ready // "MISSING"' "$state")" != "MISSING" ]; then
    echo -e "  ${GREEN}PASS${NC} P15e: handoff_001 kept inline (below window)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P15e: handoff_001 wrongly archived below window"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P15e: handoff_001 wrongly archived below window")
  fi
  assert_json_field "P15f: schema_version set to 2"     "$state" ".schema_version" "2"
  rm -rf "$workdir"

  # P16: corrupt state.json → exit 1, file untouched
  workdir=$(make_workdir)
  mkdir -p "$workdir/.startup"
  echo '{not valid json' > "$workdir/.startup/state.json"
  before_hash=$(md5sum "$workdir/.startup/state.json" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P16: corrupt state.json exits 1" "$ec" 1
  after_hash=$(md5sum "$workdir/.startup/state.json" | awk '{print $1}')
  assert_equals "P16b: corrupt state.json left unchanged" "$after_hash" "$before_hash"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -f "$workdir/.startup/state-archive.json" ]; then
    echo -e "  ${GREEN}PASS${NC} P16c: no archive created from corrupt state"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P16c: archive created from corrupt state"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P16c: archive created from corrupt state")
  fi
  rm -rf "$workdir"

  # P17: corrupt archive → renamed to .corrupt-*, compaction still succeeds, new archive started
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  echo 'CORRUPT' > "$workdir/.startup/state-archive.json"
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P17: corrupt archive compaction exits 0" "$ec" 0
  # Old archive preserved as .corrupt-*
  local corrupt_count
  corrupt_count=$(find "$workdir/.startup" -maxdepth 1 -name 'state-archive.json.corrupt-*' | wc -l)
  assert_equals "P17b: corrupt archive preserved as .corrupt-*" "$corrupt_count" "1"
  assert_output_contains "P17c: warns on stderr about corrupt archive" "$output" "corrupt"
  assert_json_valid "P17d: new archive is valid JSON" "$workdir/.startup/state-archive.json"
  assert_equals "P17e: new archive has exactly one entry" \
    "$(jq '.entries | length' "$workdir/.startup/state-archive.json")" "1"
  rm -rf "$workdir"

  # P18: concurrency — two parallel runs produce exactly one archive entry
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  (cd "$workdir" && bash "$script" >/dev/null 2>&1) &
  (cd "$workdir" && bash "$script" >/dev/null 2>&1) &
  wait
  assert_json_valid "P18: archive still valid JSON after race" "$workdir/.startup/state-archive.json"
  assert_equals "P18b: exactly one archive entry after two parallel runs" \
    "$(jq '.entries | length' "$workdir/.startup/state-archive.json")" "1"
  # Each archived key must appear exactly once (no duplicate-key inflation)
  local archived_keys_count unique_archived_keys_count
  archived_keys_count=$(jq '[.entries[].keys | keys[]] | length' "$workdir/.startup/state-archive.json")
  unique_archived_keys_count=$(jq '[.entries[].keys | keys[]] | unique | length' "$workdir/.startup/state-archive.json")
  assert_equals "P18c: no duplicate keys in archive after race" \
    "$archived_keys_count" "$unique_archived_keys_count"
  rm -rf "$workdir"

  # P19: invalid --window argument → exit 2 with clean error
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && bash "$script" --window abc 2>&1) || ec=$?
  assert_exit_code "P19: --window abc exits 2" "$ec" 2
  assert_output_contains "P19b: --window abc shows friendly error" "$output" "window"
  rm -rf "$workdir"

  # P20: --window 0 → exit 2
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  ec=0; output=$(cd "$workdir" && bash "$script" --window 0 2>&1) || ec=$?
  assert_exit_code "P20: --window 0 exits 2" "$ec" 2
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite Q: migrate-state.sh
# ---------------------------------------------------------------------------

test_migrate_state() {
  echo -e "\n${CYAN}Suite Q: migrate-state.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/migrate-state.sh"
  local workdir ec output state before_hash after_hash bak_count

  # Q1: script exists and is executable
  assert_file_exists "Q1: migrate-state.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} Q1b: migrate-state.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} Q1b: migrate-state.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("Q1b: migrate-state.sh is not executable")
  fi

  # Q2: no args defaults to dry-run (no writes, no .bak)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  before_hash=$(md5sum "$state" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "Q2: no args exits 0" "$ec" 0
  after_hash=$(md5sum "$state" | awk '{print $1}')
  assert_equals "Q2b: no args leaves state.json unchanged" "$after_hash" "$before_hash"
  assert_output_contains "Q2c: no args output mentions dry-run" "$output" "DRY RUN"
  bak_count=$(find "$workdir/.startup" -maxdepth 1 -name 'state.json.bak-*' | wc -l)
  assert_equals "Q2d: no args created no backup" "$bak_count" "0"
  rm -rf "$workdir"

  # Q3: --yes applies compaction
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" --yes 2>&1) || ec=$?
  assert_exit_code "Q3: --yes exits 0" "$ec" 0
  assert_file_exists "Q3b: archive file created" "$workdir/.startup/state-archive.json"
  assert_json_field "Q3c: schema_version = 2 after --yes" "$state" ".schema_version" "2"
  rm -rf "$workdir"

  # Q4: --yes creates timestamped .bak backup that equals pre-migration state
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  before_hash=$(md5sum "$state" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" --yes 2>&1) || ec=$?
  assert_exit_code "Q4: --yes exits 0" "$ec" 0
  bak_count=$(find "$workdir/.startup" -maxdepth 1 -name 'state.json.bak-*' | wc -l)
  assert_equals "Q4b: --yes created one backup" "$bak_count" "1"
  local bak_file
  bak_file=$(find "$workdir/.startup" -maxdepth 1 -name 'state.json.bak-*' | head -1)
  assert_json_valid "Q4c: backup is valid JSON" "$bak_file"
  after_hash=$(md5sum "$bak_file" | awk '{print $1}')
  assert_equals "Q4d: backup matches pre-migration state" "$after_hash" "$before_hash"
  rm -rf "$workdir"

  # Q5: --yes is safe to run twice (no double-archiving)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  (cd "$workdir" && bash "$script" --yes) >/dev/null 2>&1 || true
  local first_archive_count
  first_archive_count=$(jq '.entries | length' "$workdir/.startup/state-archive.json")
  ec=0; output=$(cd "$workdir" && bash "$script" --yes 2>&1) || ec=$?
  assert_exit_code "Q5: --yes second run exits 0" "$ec" 0
  local second_archive_count
  second_archive_count=$(jq '.entries | length' "$workdir/.startup/state-archive.json")
  assert_equals "Q5b: archive not double-written" "$second_archive_count" "$first_archive_count"
  rm -rf "$workdir"

  # Q6: --dry-run explicit flag is also a no-op
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  seed_handoffs "$state" 15
  before_hash=$(md5sum "$state" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" --dry-run 2>&1) || ec=$?
  assert_exit_code "Q6: --dry-run exits 0" "$ec" 0
  after_hash=$(md5sum "$state" | awk '{print $1}')
  assert_equals "Q6b: --dry-run leaves state.json unchanged" "$after_hash" "$before_hash"
  rm -rf "$workdir"

  # Q7: --yes on fresh state is no-op (no .bak needed)
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 1
  state="$workdir/.startup/state.json"
  before_hash=$(md5sum "$state" | awk '{print $1}')
  ec=0; output=$(cd "$workdir" && bash "$script" --yes 2>&1) || ec=$?
  assert_exit_code "Q7: --yes on fresh exits 0" "$ec" 0
  after_hash=$(md5sum "$state" | awk '{print $1}')
  assert_equals "Q7b: fresh state unchanged" "$after_hash" "$before_hash"
  bak_count=$(find "$workdir/.startup" -maxdepth 1 -name 'state.json.bak-*' | wc -l)
  assert_equals "Q7c: fresh state got no backup" "$bak_count" "0"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite R: Enforce Handoff Naming Hook (enforce-handoff-naming.sh)
# ---------------------------------------------------------------------------

test_enforce_handoff_naming_hook() {
  echo -e "\n${CYAN}Suite R: enforce-handoff-naming.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/enforce-handoff-naming.sh"
  local workdir ec output

  # R1: script exists and is executable
  assert_file_exists "R1: enforce-handoff-naming.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} R1b: script is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} R1b: script is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("R1b: script is not executable")
  fi

  # R2: path outside .startup/handoffs/ passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R2: outside handoffs exits 0" "$ec" 0

  # R3: INDEX.md passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/INDEX.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R3: INDEX.md exits 0" "$ec" 0

  # R4: canonical business-to-tech passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R4: canonical business-to-tech exits 0" "$ec" 0

  # R5: canonical tech-to-business passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/042-tech-to-business.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R5: canonical tech-to-business exits 0" "$ec" 0

  # R6: canonical business-to-growth passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/007-business-to-growth.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R6: canonical business-to-growth exits 0" "$ec" 0

  # R7: slug-only filename is blocked
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/business-to-tech-foo.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R7: slug-only filename exits 2" "$ec" 2
  assert_output_contains "R7b: block message mentions NNN" "$output" "NNN"
  assert_output_contains "R7c: block message mentions next NNN 001" "$output" "001"
  rm -rf "$workdir"

  # R8: timestamp-prefixed filename is blocked
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/2026-04-16T074318Z-business-to-tech-improve-189.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R8: timestamp-prefix exits 2" "$ec" 2

  # R9: non-.md (binary) is blocked
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/sample.pdf"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R9: .pdf exits 2" "$ec" 2
  assert_output_contains "R9b: block message mentions attachments/" "$output" "attachments"

  # R10: non-canonical direction NNN-business-to-team is blocked
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/476-business-to-team.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R10: non-canonical direction exits 2" "$ec" 2

  # R11: next-NNN computation reflects actual max
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/012-business-to-tech.md"
  touch "$workdir/.startup/handoffs/007-tech-to-business.md"
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/bogus.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R11: block with existing files exits 2" "$ec" 2
  assert_output_contains "R11b: next NNN is 013" "$output" "013"
  rm -rf "$workdir"

  # R12: empty file_path in stdin passes (defensive)
  ec=0
  output=$(echo '{}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R12: empty input exits 0" "$ec" 0

  # R13: signoffs/ path is not blocked (not a handoff path)
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/signoffs/roundtrip-001.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R13: signoffs/ path exits 0" "$ec" 0
}

# ---------------------------------------------------------------------------
# Suite S: Migrate Handoff Names (migrate-handoff-names.sh)
# ---------------------------------------------------------------------------

test_migrate_handoff_names() {
  echo -e "\n${CYAN}Suite S: migrate-handoff-names.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/migrate-handoff-names.sh"
  local workdir ec output

  # S1: script exists and is executable
  assert_file_exists "S1: migrate-handoff-names.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} S1b: script is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S1b: script is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S1b: script is not executable")
  fi

  # S2: dry-run on empty dir returns 0 with summary
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S2: empty dir dry-run exits 0" "$ec" 0
  assert_output_contains "S2b: output says dry-run" "$output" "Dry-run"
  assert_output_contains "S2c: summary line present" "$output" "Summary:"
  rm -rf "$workdir"

  # S3: canonical-only dir — nothing to change
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/001-business-to-tech.md"
  touch "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S3: canonical-only exits 0" "$ec" 0
  assert_output_contains "S3b: skip count is 2" "$output" "Skipping (already canonical): 2"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  echo -e "${YELLOW}=== saas-startup-team Plugin Tests ===${NC}"
  echo "Plugin root: $PLUGIN_ROOT"
  echo ""

  # Check prerequisites
  if ! command -v jq &>/dev/null; then
    echo -e "${RED}ERROR: jq is required but not found${NC}"
    exit 1
  fi

  test_check_idle
  test_check_task_complete
  test_status_script
  test_templates
  test_plugin_config
  test_stop_hook
  test_startup_init
  test_cross_file_consistency
  test_post_tool_use_hook
  test_plugin_issues
  test_auto_commit_hook
  test_tone_enforcement_hook
  test_json_validation_hook
  test_delegation_enforcement_hook
  test_duplicate_handoff_hook
  test_compact_state
  test_migrate_state
  test_index_handoff_hook
  test_enforce_handoff_naming_hook
  test_migrate_handoff_names

  # Summary
  echo ""
  echo -e "${YELLOW}=== Summary ===${NC}"
  echo -e "Total: $TOTAL_COUNT | ${GREEN}Pass: $PASS_COUNT${NC} | ${RED}Fail: $FAIL_COUNT${NC}"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failures:${NC}"
    for f in "${FAILURES[@]}"; do
      echo -e "  ${RED}- $f${NC}"
    done
    exit 1
  else
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Suite Q: Handoff Index Hook (index-handoff.sh)
# ---------------------------------------------------------------------------

test_index_handoff_hook() {
  echo -e "\n${CYAN}Suite Q: Handoff Index Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/index-handoff.sh"
  local backfill="$PLUGIN_ROOT/scripts/backfill-handoff-index.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
  local workdir ec output

  # Q1: hook script exists and is executable
  assert_file_exists "Q1: index-handoff.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} Q1b: index-handoff.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} Q1b: index-handoff.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("Q1b: index-handoff.sh is not executable")
  fi

  # Q2: backfill script exists and is executable
  assert_file_exists "Q2: backfill-handoff-index.sh exists" "$backfill"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$backfill" ]; then
    echo -e "  ${GREEN}PASS${NC} Q2b: backfill-handoff-index.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} Q2b: backfill-handoff-index.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("Q2b: backfill-handoff-index.sh is not executable")
  fi

  # Q3: hooks.json references index-handoff.sh
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "Q3: hooks.json references index-handoff.sh" "$hook_refs" "index-handoff.sh"

  # Q4: exits 0 for non-handoff file (must never block writes)
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "Q4: exits 0 for non-handoff file" "$ec" 0

  # Q5: exits 0 for empty input (must never block writes)
  ec=0
  output=$(echo '{}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "Q5: exits 0 for empty input" "$ec" 0

  # Q6: creates INDEX.md with header on first handoff write
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/001-business-to-tech.md" <<'EOF'
---
from: business-founder
to: tech-founder
iteration: 1
date: 2026-02-25
type: requirements
---

## Summary

Build the initial release.
EOF
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "Q6: exits 0 on first handoff" "$ec" 0
  assert_file_exists "Q6b: INDEX.md created" "$workdir/.startup/handoffs/INDEX.md"
  assert_file_contains "Q6c: INDEX has header" "$workdir/.startup/handoffs/INDEX.md" "Handoff Index"
  assert_file_contains "Q6d: INDEX has entry for 001" "$workdir/.startup/handoffs/INDEX.md" "001 | business-to-tech | 2026-02-25 | 001-business-to-tech.md | Build the initial release."

  # Q7: upsert — re-writing same file does not duplicate
  echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" >/dev/null 2>&1 || true
  local dup_count
  dup_count=$(grep -c "001-business-to-tech.md" "$workdir/.startup/handoffs/INDEX.md" || echo 0)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$dup_count" -eq 1 ]; then
    echo -e "  ${GREEN}PASS${NC} Q7: upsert keeps exactly one entry per filename"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} Q7: expected 1 entry, got $dup_count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("Q7: upsert failed ($dup_count entries)")
  fi

  # Q8: skips INDEX.md itself (avoid infinite recursion)
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/INDEX.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "Q8: exits 0 when target is INDEX.md" "$ec" 0
  rm -rf "$workdir"

  # Q9: handles unnumbered filename gracefully
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/business-to-tech-ad-hoc-topic.md" <<'EOF'
## Summary
Ad-hoc handoff without number prefix.
EOF
  ec=0
  echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/business-to-tech-ad-hoc-topic.md"}}' | bash "$script" >/dev/null 2>&1 || ec=$?
  assert_exit_code "Q9: exits 0 for unnumbered handoff" "$ec" 0
  assert_file_contains "Q9b: unnumbered gets --- prefix" "$workdir/.startup/handoffs/INDEX.md" "business-to-tech-ad-hoc-topic.md"
  rm -rf "$workdir"

  # Q10: backfill rebuilds index from directory
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/001-business-to-tech.md" <<'EOF'
---
date: 2026-03-01
---

## Summary
First.
EOF
  cat > "$workdir/.startup/handoffs/002-tech-to-business.md" <<'EOF'
---
date: 2026-03-02
---

## Summary
Second.
EOF
  ec=0
  output=$(bash "$backfill" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "Q10: backfill exits 0" "$ec" 0
  assert_file_exists "Q10b: INDEX.md created by backfill" "$workdir/.startup/handoffs/INDEX.md"
  assert_file_contains "Q10c: backfill includes 001" "$workdir/.startup/handoffs/INDEX.md" "001-business-to-tech.md"
  assert_file_contains "Q10d: backfill includes 002" "$workdir/.startup/handoffs/INDEX.md" "002-tech-to-business.md"
  rm -rf "$workdir"
}

main "$@"
