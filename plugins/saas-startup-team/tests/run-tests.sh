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

assert_file_not_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly exists: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$label: file exists $path")
  fi
}

assert_file_contains() {
  local label="$1" path="$2" pattern="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -q -- "$pattern" "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($path missing pattern: $pattern)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: $path missing pattern '$pattern'")
  fi
}

assert_file_not_contains() {
  local label="$1" path="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF "$unexpected" "$path" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly contains: '$unexpected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: file unexpectedly contains '$unexpected'")
  else
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
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
    echo -e "  ${RED}FAIL${NC} $label (expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected '$expected', got '$actual'")
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
  mkdir -p "$workdir/docs"
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
  cat > "$workdir/docs/human-tasks.md" <<'TASKS'
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

  # E7-E12: hooks.json
  assert_json_valid "E7: hooks.json is valid JSON" "$PLUGIN_ROOT/hooks/hooks.json"
  local hooks_keys
  hooks_keys=$(jq -r '.hooks | keys[]' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_contains "E8: hooks.json has PreToolUse" "$hooks_keys" "PreToolUse"
  assert_output_contains "E9: hooks.json has PostToolUse" "$hooks_keys" "PostToolUse"
  assert_output_contains "E10: hooks.json has Stop" "$hooks_keys" "Stop"
  assert_output_not_contains "E11: hooks.json omits Codex-unsupported TeammateIdle" "$hooks_keys" "TeammateIdle"
  assert_output_not_contains "E12: hooks.json omits Codex-unsupported TaskCompleted" "$hooks_keys" "TaskCompleted"

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

  # F10b: Codex hook bundle omits Claude-only ScheduleWakeup matcher.
  local post_matchers
  post_matchers=$(jq -r '.hooks.PostToolUse[]?.matcher // empty' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_not_contains "F10b: PostToolUse omits ScheduleWakeup matcher" "$post_matchers" "ScheduleWakeup"

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

  local MARKYIELD="$PLUGIN_ROOT/scripts/mark-yield.sh"

  # F16: fresh yield sentinel → allow stop EVEN when the transcript's last
  # assistant tool is not ScheduleWakeup. This is the issue #103 race: the
  # wakeup turn isn't flushed yet, so the `... | last` transcript check resolves
  # to the previous (Bash) turn and misses — the sentinel is authoritative.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  cat > "$workdir/.startup/transcript.jsonl" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
EOF
  echo "$(($(date +%s) + 270))" > "$workdir/.startup/.yielding"
  ec=0; (cd "$workdir" && printf '{"transcript_path":"%s/.startup/transcript.jsonl"}' "$workdir" | bash "$SCRIPT") || ec=$?
  assert_exit_code "F16: fresh yield sentinel → allow stop (race-proof)" "$ec" 0
  rm -rf "$workdir"

  # F17: STALE (expired) yield sentinel → still blocks. Self-expiry must not
  # permanently disable the hook; a genuine post-wakeup quit is still caught.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  echo "$(($(date +%s) - 60))" > "$workdir/.startup/.yielding"
  ec=0; (cd "$workdir" && bash "$SCRIPT" < /dev/null) || ec=$?
  assert_exit_code "F17: expired yield sentinel → block stop" "$ec" 2
  rm -rf "$workdir"

  # F18: mark-yield.sh writes a future-dated sentinel from the ScheduleWakeup
  # PostToolUse payload (delaySeconds honored).
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup)
  ec=0; (cd "$workdir" && printf '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":270}}' | bash "$MARKYIELD") || ec=$?
  assert_exit_code "F18: mark-yield exits 0" "$ec" 0
  assert_file_exists "F18: mark-yield wrote .yielding" "$workdir/.startup/.yielding"
  if [ -f "$workdir/.startup/.yielding" ] && [ "$(cat "$workdir/.startup/.yielding")" -gt "$(date +%s)" ]; then
    echo -e "  ${GREEN}PASS${NC} F18: sentinel expiry is in the future"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} F18: sentinel expiry not in the future"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("F18: sentinel expiry not in the future")
  fi
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  rm -rf "$workdir"

  # F19: mark-yield.sh defaults delaySeconds when the payload omits it.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup)
  ec=0; (cd "$workdir" && printf '{"tool_name":"ScheduleWakeup","tool_input":{}}' | bash "$MARKYIELD") || ec=$?
  assert_exit_code "F19: mark-yield (no delaySeconds) exits 0" "$ec" 0
  assert_file_exists "F19: mark-yield wrote .yielding with default delay" "$workdir/.startup/.yielding"
  rm -rf "$workdir"

  # F20: mark-yield.sh is a no-op outside an initialized .startup project.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q)
  ec=0; (cd "$workdir" && printf '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":270}}' | bash "$MARKYIELD") || ec=$?
  assert_exit_code "F20: mark-yield no .startup → exit 0 (no-op)" "$ec" 0
  assert_file_not_exists "F20: no sentinel written without .startup" "$workdir/.startup/.yielding"
  rm -rf "$workdir"

  # F21: garbage sentinel contents → rejected (not coerced into a bypass) → block.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  printf 'not-a-number\n' > "$workdir/.startup/.yielding"
  ec=0; (cd "$workdir" && bash "$SCRIPT" < /dev/null) || ec=$?
  assert_exit_code "F21: garbage sentinel → block stop (strict validation)" "$ec" 2
  rm -rf "$workdir"

  # F22: check-stop removes an EXPIRED sentinel as it falls through to block.
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup/go-live)
  echo '{"iteration": 5, "phase": "review"}' > "$workdir/.startup/state.json"
  echo "$(($(date +%s) - 60))" > "$workdir/.startup/.yielding"
  ec=0; (cd "$workdir" && bash "$SCRIPT" < /dev/null) || ec=$?
  assert_exit_code "F22: expired sentinel → block stop" "$ec" 2
  assert_file_not_exists "F22: expired sentinel cleaned up" "$workdir/.startup/.yielding"
  rm -rf "$workdir"

  # F23: mark-yield clamps an absurd delaySeconds so a stale sentinel can't
  # disable the Stop block for an unreasonable span (cap = 600s).
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q && mkdir -p .startup)
  now=$(date +%s)
  ec=0; (cd "$workdir" && printf '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":999999999}}' | bash "$MARKYIELD") || ec=$?
  assert_exit_code "F23: mark-yield (huge delay) exits 0" "$ec" 0
  if [ -f "$workdir/.startup/.yielding" ] && [ "$(cat "$workdir/.startup/.yielding")" -le "$((now + 600 + 5))" ]; then
    echo -e "  ${GREEN}PASS${NC} F23: absurd delaySeconds clamped to <= now+600"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} F23: absurd delaySeconds not clamped"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("F23: absurd delaySeconds not clamped")
  fi
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
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

  mkdir -p "$workdir/docs"
  cp "$PLUGIN_ROOT/templates/human-tasks.md" "$workdir/docs/human-tasks.md"

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
  assert_file_contains "G14: human-tasks has Pending section" "$workdir/docs/human-tasks.md" "## Pending"
  assert_file_contains "G15: human-tasks has Completed section" "$workdir/docs/human-tasks.md" "## Completed"

  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite H: Cross-File Consistency
# ---------------------------------------------------------------------------

test_cross_file_consistency() {
  echo -e "\n${CYAN}Suite H: Cross-File Consistency${NC}"

  # H1-H2: Codex-supported hook resolver targets resolve to real files
  local stop_script handoff_script hook_commands
  stop_script=$(jq -r '.hooks.Stop[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  handoff_script=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  hook_commands=$(jq -r '.. | objects | .command? // empty' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)

  assert_output_not_contains "H0: hook commands do not directly depend on CLAUDE_PLUGIN_ROOT" "$hook_commands" '${CLAUDE_PLUGIN_ROOT}/'

  stop_script=$(printf '%s\n' "$stop_script" | sed -n 's/.*p=\([^;]*\);.*/\1/p')
  handoff_script=$(printf '%s\n' "$handoff_script" | sed -n 's/.*p=\([^;]*\);.*/\1/p')

  assert_file_exists "H1: Stop hook script exists" "$PLUGIN_ROOT/$stop_script"
  assert_file_exists "H2: PreToolUse handoff hook script exists" "$PLUGIN_ROOT/$handoff_script"

  # H3-H4: Agent names in agents/*.md match the role tokens the handoff/dispatch
  # conventions key on (business-founder, tech-founder* for both engines).
  local biz_name tech_claude_name tech_codex_name
  biz_name=$(grep '^name:' "$PLUGIN_ROOT/agents/business-founder.md" | head -1 | sed 's/^name: *//')
  tech_claude_name=$(grep '^name:' "$PLUGIN_ROOT/agents/tech-founder-claude.md" | head -1 | sed 's/^name: *//')
  tech_codex_name=$(grep '^name:' "$PLUGIN_ROOT/agents/tech-founder-codex.md" | head -1 | sed 's/^name: *//')

  assert_equals "H3: business-founder agent name matches role token" "$biz_name" "business-founder"
  assert_equals "H4a: tech-founder-claude agent name correct" "$tech_claude_name" "tech-founder-claude"
  assert_equals "H4b: tech-founder-codex agent name correct" "$tech_codex_name" "tech-founder-codex"
  # both engine names must prefix-match the tech-founder role token
  case "$tech_claude_name" in tech-founder*) assert_equals "H4c: claude engine matches tech-founder role" "ok" "ok";; *) assert_equals "H4c: claude engine matches tech-founder role" "no" "ok";; esac
  case "$tech_codex_name" in tech-founder*) assert_equals "H4d: codex engine matches tech-founder role" "ok" "ok";; *) assert_equals "H4d: codex engine matches tech-founder role" "no" "ok";; esac

  # H7: Template filenames match the patterns that scripts expect
  assert_file_exists "H7: handoff-business-to-tech template exists" \
    "$PLUGIN_ROOT/templates/handoff-business-to-tech.md"
  assert_file_exists "H8: handoff-tech-to-business template exists" \
    "$PLUGIN_ROOT/templates/handoff-tech-to-business.md"

  # H10-H11: Scripts are executable
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
    "$PLUGIN_ROOT/references/workflows/improve.md" '.active_role = "business-founder-maintain"'
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

  # I6: auto-learn.sh guidance contains Learnings section reference
  assert_file_contains "I6: auto-learn.sh references Learnings section" "$script" "## Learnings"

  # I7: auto-learn.sh guidance contains duplicate-skip instruction
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

  # I10: auto-learn.sh exits 0 with non-blocking PostToolUse context for matching handoff file
  local errfile stderr
  errfile=$(mktemp)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>"$errfile") || ec=$?
  stderr=$(cat "$errfile")
  rm -f "$errfile"
  assert_exit_code "I10: exits 0 for matching handoff file" "$ec" 0
  assert_output_contains "I10b: hookSpecificOutput in stdout" "$output" "hookSpecificOutput"
  assert_output_contains "I10c: PostToolUse event name in stdout" "$output" '"hookEventName":"PostToolUse"'
  assert_output_contains "I10d: additionalContext in stdout" "$output" "additionalContext"
  assert_output_not_contains "I10e: no legacy systemMessage output" "$output" "systemMessage"
  assert_equals "I10f: no stderr for matching handoff file" "$stderr" ""

  # I11: script parses (catches any quoting breakage)
  ec=0; bash -n "$script" 2>/dev/null || ec=$?
  assert_exit_code "I11: auto-learn.sh parses (bash -n)" "$ec" 0
  # I12: still emits valid JSON additionalContext on a matching handoff
  out="$(printf '{"tool_input":{"file_path":"/tmp/x/.startup/handoffs/h.md"}}' | bash "$script")"
  ec=0; printf '%s\n' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | type == "string")' >/dev/null 2>&1 || ec=$?
  assert_exit_code "I12: emits JSON additionalContext" "$ec" 0
  # I13: no longer instructs blanket NEVER/ALWAYS for rules
  assert_file_not_contains "I13: drops blanket NEVER/ALWAYS instruction" "$script" "NEVER/ALWAYS for rules"
  # I14: embeds the house-style label shape
  assert_file_contains "I14: house-style label shape" "$script" "<Label>:"
  # I15: keeps the terse why mandate
  assert_file_contains "I15: mandates terse why" "$script" "terse why"
  # I16: rations emphasis
  assert_file_contains "I16: rations emphasis" "$script" "landmine"
  # I17: applies novelty gate + calibration guard
  assert_file_contains "I17: novelty gate" "$script" "surprising to a competent model"
  assert_file_contains "I18: keeps version-specific facts" "$script" "version-specific"
  # I19: routes tier-2 standards out of learnings
  assert_file_contains "I19: promotes general standards" "$script" "general standard"
  # I20: still caps entries at 3
  assert_file_contains "I20: caps at 3 entries" "$script" "Max 3 new entries"
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

  # J2-J5: the shared reference holds the gh filing command; the four primary
  # issue-filing agents point at that reference (stated once, referenced elsewhere).
  # tech-founder-codex* inherit plugin-issue reporting via tech-founder-claude.md (which they read).
  assert_file_contains "J-gh-ref: reference files via the pinned repo variable" \
    "$PLUGIN_ROOT/templates/plugin-issue-reporting.md" 'gh issue create --repo "${SAAS_PLUGIN_REPO}"'
  for agent in business-founder.md tech-founder-claude.md tech-founder-claude-maintain.md business-founder-maintain.md; do
    assert_file_contains "J-gh: $agent references the plugin-issue-reporting doc" \
      "$PLUGIN_ROOT/agents/$agent" "templates/plugin-issue-reporting.md"
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
# Suite K: /maintain command
# ---------------------------------------------------------------------------

test_maintain() {
  echo -e "\n${CYAN}== /maintain command ==${NC}"
  local cmd="$PLUGIN_ROOT/references/workflows/maintain.md"
  local codex_cmd="$PLUGIN_ROOT/skills/saas-startup-team-maintain-workflow/SKILL.md"
  assert_file_exists "M1: maintain.md exists" "$cmd"
  # Frontmatter
  assert_file_contains "M2: name frontmatter"          "$cmd" "name: maintain"
  assert_file_contains "M3: user_invocable"            "$cmd" "user_invocable: true"
  # Reuse / dependencies
  assert_file_contains "M4: invokes goal-deliver"      "$cmd" "goal-deliver"
  assert_file_contains "M5: tribunal hard dep"         "$cmd" "tribunal-review"
  # Stateless supervisor + disk state
  assert_file_contains "M6: disk state dir"            "$cmd" ".startup/maintain"
  assert_file_contains "M7: current-run persisted"     "$cmd" "current-run.json"
  assert_file_contains "M8: stateless re-read"         "$cmd" "stateless"
  # Read-only triage + supervisor-only mutation
  assert_file_contains "M9: read-only triage"          "$cmd" "read-only"
  # Verdicts (no deliver-hold; hold tier removed)
  assert_file_contains "M10: agent-fixable verdict"    "$cmd" "agent-fixable"
  assert_file_contains "M11: needs-human verdict"      "$cmd" "needs-human"
  assert_file_contains "M12: blocked verdict"          "$cmd" "maintain:blocked"
  assert_file_contains "M13: claimed label"            "$cmd" "maintain:claimed"
  # Triage fences humans into human-tasks.md
  assert_file_contains "M14: human-tasks.md"           "$cmd" "human-tasks.md"
  # Dependency ordering in v1
  assert_file_contains "M15: dependency order"         "$cmd" "depends on"
  # Idempotency: linked-PR detection is delegated to the queue builder.
  assert_file_contains "M16: linked-PR detection"      "$cmd" ".excluded.linked_pr"
  # Injection firewall + external side-effect ban
  assert_file_contains "M17: injection firewall"       "$cmd" "inform requirements only"
  assert_file_contains "M18: side-effect ban"          "$cmd" "side-effect"
  # Merge safety (no --auto default; explicit rerun)
  assert_file_contains "M19: squash merge"             "$cmd" "gh pr merge --squash"
  # Circuit breakers
  assert_file_contains "M20: max-issues breaker"       "$cmd" "max-issues"
  assert_file_contains "M21: max-merges breaker"       "$cmd" "max-merges"
  # Safety flags
  assert_file_contains "M22: --once flag"              "$cmd" "--once"
  assert_file_contains "M23: --dry-run flag"           "$cmd" "--dry-run"
  # Explicit final state / digest
  assert_file_contains "M24: run digest"               "$cmd" "runs/"
  assert_file_contains "M25: deploy classification"    "$cmd" "deploy-blocked"
  # Dedicated worktree isolation (primary checkout stays free)
  assert_file_contains "M26: dedicated worktree"        "$cmd" "worktree add --detach"
  assert_file_contains "M27: worktree path convention"  "$cmd" ".worktrees/maintain"
  # Fast no-op must not strand cached deliverable issues.
  assert_file_contains "M28: cached resumable gate" "$cmd" "cached_resumable"
  assert_file_contains "M29: cached agent-fixable enters queue" "$cmd" "deliverable queue input"
  assert_file_contains "M30: cache hit still feeds queue" "$cmd" "A cache hit supplies the cached verdict"
  # Claude /maintain recurrence + tribunal gates.
  assert_file_contains "M31: command recurrence class gate" "$cmd" "root cause / recurrence class"
  assert_file_contains "M32: command fixes recurrence class" "$cmd" "fix the class, not only the observed instance"
  assert_file_contains "M33: command red-green proof" "$cmd" "red-before/green-after proof"
  assert_file_contains "M34: command current HEAD tribunal predicate" "$cmd" "current PR HEAD and latest diff"
  assert_file_contains "M35: command stale verdict invalidation" "$cmd" "reopens tribunal validation"
  assert_file_contains "M36: command missing recurrence proof blocks merge" "$cmd" "missing recurrence proof"
  # Codex workflow hard gates
  assert_file_exists "M37: Codex maintain workflow exists" "$codex_cmd"
  assert_file_contains "M38: Codex recurrence class gate" "$codex_cmd" "root cause / recurrence class"
  assert_file_contains "M39: Codex recurrence proof gate" "$codex_cmd" "red-before/green-after proof"
  assert_file_contains "M40: Codex closing loop prerequisite" "$codex_cmd" "main merge prerequisite"
  assert_file_contains "M41: Codex stale verdict invalidation" "$codex_cmd" "reopens the closing loop"
  assert_file_contains "M42: Codex current HEAD predicate" "$codex_cmd" "current PR HEAD and latest diff"
  assert_file_contains "M43: Codex gates run in maintain cycle" "$codex_cmd" "issue-delivery cycle"
  assert_file_contains "M44: Codex QA before closing loop" "$codex_cmd" "business-founder QA phase with Playwright"
  assert_file_contains "M45: Codex QA not-applicable record" "$codex_cmd" "Business-founder Playwright QA: not applicable"
  assert_file_contains "M45a: maintain uses queue builder" "$cmd" "maintain-queue.sh"
  assert_file_contains "M45a1: maintain checks queue builder exit" "$cmd" "if ! QUEUE_JSON="
  assert_file_contains "M45a2: maintain dry-run uses fixture queue state" "$cmd" "--issues-file <issues.json>"

  # Queue builder regression: no-dependency issues must survive dependency parsing.
  local queue_script issues_file prs_file blocked_file bad_blocked_file bad_blocked_err dep_issues_file dep_status_file serial_dep_issues_file serial_dep_status_file closed_issues_file fake_bin live_out repo_live_out closed_status closed_err missing_status missing_err fixture_closed_status fixture_closed_err zero_status zero_err bad_blocked_status out filtered single_issue cooled dep_out serial_dep_out queue_numbers
  queue_script="$PLUGIN_ROOT/scripts/maintain-queue.sh"
  assert_file_exists "M45b: queue builder script exists" "$queue_script"
  assert_file_contains "M45b1: queue builder fetches linked PR refs" "$queue_script" "closedByPullRequestsReferences"
  workdir=$(mktemp -d)
  issues_file="$workdir/issues.json"
  prs_file="$workdir/open-prs.json"
  cat > "$issues_file" <<'JSON'
[
  {
    "number": 101,
    "title": "Unlabelled no-dependency issue",
    "body": "No dependency markers here.",
    "labels": [],
    "createdAt": "2026-01-05T00:00:00Z",
    "updatedAt": "2026-01-05T00:00:00Z"
  },
  {
    "number": 102,
    "title": "Critical no-dependency issue",
    "body": "No dependency markers here either.",
    "labels": [{"name": "critical"}, {"name": "release"}],
    "createdAt": "2026-01-04T00:00:00Z",
    "updatedAt": "2026-01-04T00:00:00Z"
  },
  {
    "number": 103,
    "title": "Already has PR",
    "body": "Fix is in flight.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": "2026-01-01T00:00:00Z"
  },
  {
    "number": 104,
    "title": "Depends on queued work",
    "body": "Blocked by #101, #102; context from #110.",
    "labels": [{"name": "medium"}],
    "createdAt": "2026-01-03T00:00:00Z",
    "updatedAt": "2026-01-03T00:00:00Z"
  },
  {
    "number": 105,
    "title": "Human decision",
    "body": "Needs a product call.",
    "labels": [{"name": "needs-human"}],
    "createdAt": "2026-01-06T00:00:00Z",
    "updatedAt": "2026-01-06T00:00:00Z"
  },
  {
    "number": 106,
    "title": "Temporarily blocked",
    "body": "External dependency.",
    "labels": [{"name": "maintain:blocked"}],
    "createdAt": "2026-01-07T00:00:00Z",
    "updatedAt": "2026-01-07T00:00:00Z"
  },
  {
    "number": 107,
    "title": "Umbrella epic",
    "body": "Tracking issue.",
    "labels": [{"name": "epic"}],
    "createdAt": "2026-01-08T00:00:00Z",
    "updatedAt": "2026-01-08T00:00:00Z"
  },
  {
    "number": 108,
    "title": "Low no-dependency issue",
    "body": "No dependency markers.",
    "labels": [{"name": "low"}],
    "createdAt": "2026-01-02T00:00:00Z",
    "updatedAt": "2026-01-02T00:00:00Z"
  },
  {
    "number": 109,
    "title": "Mentioned by in-flight PR",
    "body": "No dependency markers.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-08T00:00:00Z",
    "updatedAt": "2026-01-08T00:00:00Z"
  },
  {
    "number": 110,
    "title": "High no-dependency issue",
    "body": "No dependency markers.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-09T00:00:00Z",
    "updatedAt": "2026-01-09T00:00:00Z"
  },
  {
    "number": 111,
    "title": "Medium no-dependency issue",
    "body": "No dependency markers.",
    "labels": [{"name": "medium"}],
    "createdAt": "2026-01-10T00:00:00Z",
    "updatedAt": "2026-01-10T00:00:00Z"
  }
]
JSON
  cat > "$prs_file" <<'JSON'
[
  {
    "number": 20,
    "title": "Fix linked issue",
    "body": "Closes #103",
    "closingIssuesReferences": [{"number": 103}]
  },
  {
    "number": 21,
    "title": "WIP for #109",
    "body": "Implementation notes only; no closing keyword.",
    "closingIssuesReferences": []
  }
]
JSON
  out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file")
  queue_numbers=$(jq -r '.queue[].number' <<<"$out")
  assert_equals "M45c: queue preserves no-dependency issues and orders by severity" \
    "$queue_numbers" $'102\n110\n111\n108\n101'
  assert_equals "M45d: no-dependency issue has empty deps" \
    "$(jq -r '.queue[] | select(.number == 101) | (.deps | length)' <<<"$out")" "0"
  assert_equals "M45e: linked open PR is excluded" \
    "$(jq -r '.excluded.linked_pr | index(103) != null' <<<"$out")" "true"
  assert_equals "M45e2: ambiguous open PR mention is excluded" \
    "$(jq -r '.excluded.linked_pr | index(109) != null' <<<"$out")" "true"
  assert_equals "M45f: explicit dependencies defer dependent issue" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 104) | (.deps | join(","))' <<<"$out")" "101,102"
  assert_equals "M45g: needs-human label is excluded" \
    "$(jq -r '.excluded.needs_human | index(105) != null' <<<"$out")" "true"
  assert_equals "M45h: maintain:blocked label is excluded" \
    "$(jq -r '.excluded.maintain_blocked | index(106) != null' <<<"$out")" "true"
  assert_equals "M45i: epic label is excluded" \
    "$(jq -r '.excluded.epic | index(107) != null' <<<"$out")" "true"
  assert_equals "M45j: all open issues are accounted for" \
    "$(jq -r '.unaccounted | length' <<<"$out")" "0"
  filtered=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --label release)
  assert_equals "M45k: label filter keeps matching eligible issue" \
    "$(jq -r '.queue[].number' <<<"$filtered")" "102"
  assert_equals "M45l: label filter accounts for nonmatching issues" \
    "$(jq -r '.excluded.label_filter | index(101) != null' <<<"$filtered")" "true"
  single_issue=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --issue 101 --label release)
  assert_equals "M45m: explicit issue bypasses label filter" \
    "$(jq -r '.queue[].number' <<<"$single_issue")" "101"
  missing_err="$workdir/missing-issue.err"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --issue 999 > /dev/null 2> "$missing_err"
  missing_status=$?
  set -e
  assert_exit_code "M45m1: missing fixture issue fails loudly" "$missing_status" 3
  assert_file_contains "M45m1b: missing fixture issue is named" "$missing_err" "issue #999 was not found in fixture"
  zero_err="$workdir/leading-zero.err"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --issue 007 > /dev/null 2> "$zero_err"
  zero_status=$?
  set -e
  assert_exit_code "M45m2: leading-zero issue is rejected before jq" "$zero_status" 2
  assert_file_contains "M45m3: leading-zero issue error is clear" "$zero_err" "without leading zeros"
  closed_issues_file="$workdir/closed-issues.json"
  cat > "$closed_issues_file" <<'JSON'
[
  {
    "number": 112,
    "state": "CLOSED",
    "title": "Closed fixture issue",
    "body": "Already done.",
    "labels": [],
    "createdAt": "2026-01-12T00:00:00Z",
    "updatedAt": "2026-01-12T00:00:00Z"
  }
]
JSON
  fixture_closed_err="$workdir/fixture-closed.err"
  set +e
  bash "$queue_script" --issues-file "$closed_issues_file" --open-prs-file "$prs_file" --issue 112 > /dev/null 2> "$fixture_closed_err"
  fixture_closed_status=$?
  set -e
  assert_exit_code "M45m4: closed fixture issue fails loudly" "$fixture_closed_status" 3
  assert_file_contains "M45m5: closed fixture issue names state problem" "$fixture_closed_err" "issue #112 is not open"
  blocked_file="$workdir/blocked.jsonl"
  printf '%s\n' '{"number":101,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' > "$blocked_file"
  cooled=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$blocked_file")
  assert_equals "M45n: blocked-file cooldown excludes issue" \
    "$(jq -r '.excluded.cooldown | index(101) != null' <<<"$cooled")" "true"
  bad_blocked_file="$workdir/bad-blocked.jsonl"
  bad_blocked_err="$workdir/bad-blocked.err"
  printf '%s\n' '{"number":101,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' 'not-json' > "$bad_blocked_file"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$bad_blocked_file" > /dev/null 2> "$bad_blocked_err"
  bad_blocked_status=$?
  set -e
  assert_exit_code "M45n1: malformed blocked-file fails loudly" "$bad_blocked_status" 3
  assert_file_contains "M45n2: malformed blocked-file names file" "$bad_blocked_err" "invalid blocked file: $bad_blocked_file"
  dep_issues_file="$workdir/dependency-issues.json"
  dep_status_file="$workdir/dependency-status.json"
  cat > "$dep_issues_file" <<'JSON'
[
  {
    "number": 201,
    "title": "Depends on completed prerequisite",
    "body": "Depends on #200; context from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-11T00:00:00Z",
    "updatedAt": "2026-01-11T00:00:00Z"
  }
]
JSON
  cat > "$dep_status_file" <<'JSON'
[
  {
    "number": 200,
    "state": "CLOSED",
    "closedByPullRequestsReferences": [
      {"number": 77, "mergedAt": "2026-01-11T00:00:00Z", "baseRefName": "main"}
    ]
  }
]
JSON
  dep_out=$(bash "$queue_script" --issues-file "$dep_issues_file" --open-prs-file "$prs_file" --dependency-status-file "$dep_status_file" --default-branch main)
  assert_equals "M45o: dependency status fixture marks closed PR-backed prerequisite satisfied" \
    "$(jq -r '.queue[].number' <<<"$dep_out")" "201"
  serial_dep_issues_file="$workdir/serial-dependency-issues.json"
  serial_dep_status_file="$workdir/serial-dependency-status.json"
  cat > "$serial_dep_issues_file" <<'JSON'
[
  {
    "number": 203,
    "title": "Depends on completed and pending prerequisites",
    "body": "Depends on #200, and #202; context from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-12T00:00:00Z",
    "updatedAt": "2026-01-12T00:00:00Z"
  },
  {
    "number": 204,
    "title": "Depends on: #205",
    "body": "**Blocked by:** #200\n\nDepends on:\n- #202\nContext from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-13T00:00:00Z",
    "updatedAt": "2026-01-13T00:00:00Z"
  }
]
JSON
  cat > "$serial_dep_status_file" <<'JSON'
[
  {
    "number": 200,
    "state": "CLOSED",
    "closedByPullRequestsReferences": [
      {"number": 77, "mergedAt": "2026-01-11T00:00:00Z", "baseRefName": "main"}
    ]
  }
]
JSON
  serial_dep_out=$(bash "$queue_script" --issues-file "$serial_dep_issues_file" --open-prs-file "$prs_file" --dependency-status-file "$serial_dep_status_file" --default-branch main)
  assert_equals "M45o1: serial-comma dependency keeps pending prerequisite blocked" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 203) | (.deps | join(","))' <<<"$serial_dep_out")" "202"
  assert_equals "M45o2: markdown dependency syntax keeps pending prerequisites blocked" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 204) | (.deps | join(","))' <<<"$serial_dep_out")" "202,205"
  fake_bin="$workdir/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {
    "number": 201,
    "title": "Depends on completed prerequisite",
    "body": "Depends on #200; context from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-11T00:00:00Z",
    "updatedAt": "2026-01-11T00:00:00Z",
    "closedByPullRequestsReferences": []
  }
]
JSON
    ;;
  "pr list")
    printf '[]\n'
    ;;
  "repo view")
    for arg in "$@"; do
      [ "$arg" = "--repo" ] && exit 42
    done
    printf 'main\n'
    ;;
  "issue view")
    if [ "${3:-}" = "200" ]; then
      cat <<'JSON'
{"number":200,"state":"CLOSED","closedByPullRequestsReferences":[{"number":77}]}
JSON
    elif [ "${3:-}" = "202" ]; then
      cat <<'JSON'
{"number":202,"state":"CLOSED","closedByPullRequestsReferences":[]}
JSON
    else
      exit 1
    fi
    ;;
  "pr view")
    [ "${3:-}" = "77" ] || exit 1
    cat <<'JSON'
{"number":77,"state":"MERGED","mergedAt":"2026-01-11T00:00:00Z","baseRefName":"main"}
JSON
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fake_bin/gh"
  live_out=$(PATH="$fake_bin:$PATH" bash "$queue_script")
  assert_equals "M45p: live gh dependency lookup marks closed PR-backed prerequisite satisfied" \
    "$(jq -r '.queue[].number' <<<"$live_out")" "201"
  repo_live_out=$(PATH="$fake_bin:$PATH" bash "$queue_script" --repo owner/repo)
  assert_equals "M45p2: live --repo default-branch lookup uses gh repo view owner/repo" \
    "$(jq -r '.queue[].number' <<<"$repo_live_out")" "201"
  closed_err="$workdir/closed.err"
  set +e
  PATH="$fake_bin:$PATH" bash "$queue_script" --issue 202 > /dev/null 2> "$closed_err"
  closed_status=$?
  set -e
  assert_exit_code "M45q: explicit closed issue fails loudly" "$closed_status" 3
  assert_file_contains "M45r: explicit closed issue names state problem" "$closed_err" "issue #202 is not open"
  rm -rf "$workdir"

  # Regression for fast no-op: open>0, new=0, cached agent-fixable => no fast no-op.
  local workdir cache open_json open new cached_deliverable fast_noop
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/maintain"
  cache="$workdir/.startup/maintain/triage-cache.jsonl"
  open_json='[{"number":1350,"updatedAt":"2026-07-04T00:00:00Z","labels":[]},{"number":1351,"updatedAt":"2026-07-04T00:01:00Z","labels":[]}]'
  printf '%s\n' \
    '{"number":1350,"updatedAt":"2026-07-04T00:00:00Z","verdict":"agent-fixable"}' \
    '{"number":1351,"updatedAt":"2026-07-04T00:01:00Z","verdict":"needs-human"}' \
    > "$cache"
  open=$(jq length <<<"$open_json")
  new=$(jq --slurpfile seen <(jq -c '{number, updatedAt}' "$cache") \
    '[.[] | select({number, updatedAt} as $k | ($seen | index($k)) | not)] | length' <<<"$open_json")
  cached_deliverable=$(jq -s --slurpfile open <(printf '%s\n' "$open_json") '
    def matching_open($c):
      any($open[0][]; .number == $c.number and .updatedAt == $c.updatedAt);
    def nonfinal($c):
      (($c.final_state // $c.finalState // "") as $s
       | ($s == "" or ($s | test("^(fixed:|needs-human:|escalated:|skipped:|split:)") | not)));
    [ .[]
      | select(matching_open(.))
      | select(.verdict == "agent-fixable" or .verdict == "partially-fixable")
      | select(nonfinal(.))
    ] | length' "$cache")
  fast_noop=false
  if [ "$open" -eq 0 ] || { [ "$new" -eq 0 ] && [ "$cached_deliverable" -eq 0 ]; }; then
    fast_noop=true
  fi
  assert_equals "M46: cached agent-fixable has no cache miss" "$new" "0"
  assert_equals "M47: cached agent-fixable counted deliverable" "$cached_deliverable" "1"
  assert_equals "M48: cached agent-fixable prevents fast no-op" "$fast_noop" "false"

  printf '%s\n' \
    '{"number":1350,"updatedAt":"2026-07-04T00:00:00Z","verdict":"agent-fixable","final_state":"fixed:PR#12"}' \
    '{"number":1351,"updatedAt":"2026-07-04T00:01:00Z","verdict":"needs-human"}' \
    > "$cache"
  cached_deliverable=$(jq -s --slurpfile open <(printf '%s\n' "$open_json") '
    def matching_open($c):
      any($open[0][]; .number == $c.number and .updatedAt == $c.updatedAt);
    def nonfinal($c):
      (($c.final_state // $c.finalState // "") as $s
       | ($s == "" or ($s | test("^(fixed:|needs-human:|escalated:|skipped:|split:)") | not)));
    [ .[]
      | select(matching_open(.))
      | select(.verdict == "agent-fixable" or .verdict == "partially-fixable")
      | select(nonfinal(.))
    ] | length' "$cache")
  fast_noop=false
  if [ "$open" -eq 0 ] || { [ "$new" -eq 0 ] && [ "$cached_deliverable" -eq 0 ]; }; then
    fast_noop=true
  fi
  assert_equals "M49: cached final state removes deliverability" "$cached_deliverable" "0"
  assert_equals "M50: cached final state permits fast no-op" "$fast_noop" "true"
  rm -rf "$workdir"
}

test_maintain_loop() {
  echo -e "\n${CYAN}== /maintain-loop command ==${NC}"
  local cmd="$PLUGIN_ROOT/references/workflows/maintain-loop.md"
  local codex_cmd="$PLUGIN_ROOT/skills/saas-startup-team-maintain-loop-workflow/SKILL.md"

  assert_file_exists "ML1: maintain-loop.md exists" "$cmd"
  assert_file_contains "ML2: name frontmatter" "$cmd" "name: maintain-loop"
  assert_file_contains "ML3: user_invocable" "$cmd" "user_invocable: true"
  assert_file_contains "ML4: worker is fresh tech-founder" "$cmd" '--role tech-founder --profile "$PROFILE"'
  assert_file_not_contains "ML5: no composite maintain-loop supervisor launch" "$cmd" '--role maintain-loop-supervisor'
  assert_file_contains "ML6: supervisor is sole delivery mutation owner" "$cmd" "only delivery-state mutation owner"
  assert_file_contains "ML7: worker edits source and tests only" "$cmd" "task-required product source and tests"
  assert_file_contains "ML8: worker cannot stage or commit" "$cmd" "must not stage or commit"
  assert_file_contains "ML9: worker cannot mutate GitHub or deployment" "$cmd" "push, open or edit a PR, merge, deploy, or"
  assert_file_contains "ML10: supervisor never patches source" "$cmd" "supervisor never patches product source itself"
  assert_file_contains "ML11: one writer at a time" "$cmd" "Only one source writer may run at a time"
  assert_file_contains "ML12: browser stays flattened on Codex" "$cmd" "browser work stays flattened"
  assert_file_contains "ML13: source fixes use fresh tech-founder" "$cmd" "tech-founder attempt, then repeats containment"
  assert_file_contains "ML14: worker shell preflight" "$cmd" "codex:worker-shell"
  assert_file_contains "ML15: default branch is resolved, not assumed" "$cmd" "default-branch.sh"
  assert_file_contains "ML16: dedicated worktree" "$cmd" ".worktrees/maintain-loop"
  assert_file_contains "ML17: run id initialized by event library" "$cmd" 'agent-events.sh" new-run-id'
  assert_file_contains "ML18: pass lease acquired" "$cmd" "--acquire maintain-loop:pass"
  assert_file_contains "ML19: worktree lease acquired" "$cmd" '--acquire "$WT_KEY"'
  assert_file_contains "ML20: pass owner persists" "$cmd" 'PASS_OWNER="$LEASE_DIR/.owners/maintain-loop-pass-$RUN_ID.owner"'
  assert_file_contains "ML21: worktree owner persists" "$cmd" 'WT_OWNER="$LEASE_DIR/.owners/maintain-loop-worktree-$RUN_ID.owner"'
  assert_file_contains "ML22: lease guardian crosses shell PIDs" "$cmd" 'lease-guardian.sh" start'
  assert_file_contains "ML23: heartbeat failure is fail-closed" "$cmd" "HEARTBEAT_FAILED"
  assert_file_contains "ML24: guardian state persists beyond setup shell" "$cmd" 'GUARDIAN_PID_FILE='
  assert_file_contains "ML25: one-shot shell traps are not trusted" "$cmd" 'Never rely on shell variables or traps surviving a Bash tool call'
  assert_file_contains "ML26: worktree lease released" "$cmd" '--release "$WT_KEY"'
  assert_file_contains "ML27: pass lease released" "$cmd" "--release maintain-loop:pass"
  assert_file_contains "ML28: stale replacement requires reason" "$cmd" "--replace-stale --reason"
  assert_file_contains "ML29: maintain-loop uses queue builder" "$cmd" "maintain-queue.sh"
  assert_file_contains "ML30: unexplained empty queue fails" "$cmd" "otherwise fail"
  assert_file_contains "ML31: autonomous semantic router" "$cmd" "delivery-route.sh classify --mode autonomous"
  assert_file_contains "ML32: autonomous light rejects UI" "$cmd" 'requires `ui_touch=false`'
  assert_file_contains "ML33: one task file per attempt" "$cmd" "issue-<N>-attempt-<A>.md"
  assert_file_contains "ML34: task text excluded from events" "$cmd" "Do not put issue text or the prompt in events"
  assert_file_contains "ML35: supervisor launches from worktree" "$cmd" '(cd "$WT" && env SAAS_RUN_ID='
  assert_file_contains "ML36: writer sandbox is fixed workspace-write" "$cmd" 'CODEX_SANDBOX=workspace-write'
  assert_file_not_contains "ML37: no direct unpinned Codex launch" "$cmd" 'codex exec'
  assert_file_contains "ML38: supervisor checks worker HEAD boundary" "$cmd" "HEAD, branch, index, refs"
  assert_file_contains "ML39: worker-authored commits rejected" "$cmd" "all worker-authored commits"
  assert_file_contains "ML40: source-free success rejected" "$cmd" "source-free"
  assert_file_contains "ML41: only isolated supervisor path stages" "$cmd" 'only `supervisor-commit.sh` stages the accepted candidate'
  assert_file_contains "ML42: working-tree post-diff containment" "$cmd" 'check-diff --base "$BASE_SHA"'
  assert_file_not_contains "ML42b: containment does not stage on the host" "$cmd" '--base "$BASE_SHA" --cached'
  assert_file_contains "ML42c: source writer opens an exact mutation guard" "$cmd" '--snapshot "$ROLE_GUARD"'
  assert_file_contains "ML42d: source writer guard is verified after exit" "$cmd" '--verify "$ROLE_GUARD"'
  assert_file_contains "ML43: light continuation needs non-UI light diff" "$cmd" 'and `ui_touch=false`'
  assert_file_contains "ML44: escalation artifact is primary and attempt-specific" "$cmd" 'escalations/<RUN_ID>/issue-<N>-attempt-<A>.json'
  assert_file_contains "ML45: escalation artifact is outside disposable worktree" "$cmd" "never placed in or deleted with the disposable worktree"
  assert_file_contains "ML46: supervisor writes escalation artifact" "$cmd" "supervisor atomically writes"
  assert_file_contains "ML47: escalation verifies PR cleanup" "$cmd" "open_pr=false"
  assert_file_contains "ML48: escalation verifies remote cleanup" "$cmd" "remote_branch=false"
  assert_file_contains "ML49: escalation verifies base reset" "$cmd" "head_at_base=true"
  assert_file_contains "ML50: escalation verifies clean worktree" "$cmd" "worktree_clean=true"
  assert_file_contains "ML51: missing escalation evidence blocks restart" "$cmd" "artifact exists, validates, and all four facts are true"
  assert_file_contains "ML52: queue eligibility survives escalation" "$cmd" "Keep queue eligibility unchanged"
  assert_file_contains "ML53: deep restart is once only" "$cmd" "never perform another lower-to-deep restart"
  assert_file_contains "ML54: supervisor owns gated commit" "$cmd" "supervisor-commit.sh --repo-root"
  assert_file_contains "ML55: product hooks stay enabled" "$cmd" '--no-verify'
  assert_file_contains "ML56: QA mutation boundary enforced" "$cmd" "delivery-mutation-guard.sh"
  assert_file_contains "ML57: QA not-applicable marker" "$cmd" "Business-founder Playwright QA: not applicable"
  assert_file_contains "ML58: supervisor owns PR closure audit" "$cmd" "issue-closure-audit.sh"
  assert_file_contains "ML59: supervisor owns tribunal" "$cmd" 'closing-tribunal-loop` from the supervisor'
  assert_file_contains "ML60: tribunal is read-only" "$cmd" "read-only"
  assert_file_contains "ML61: tribunal fixes return to writer" "$cmd" "needs source changes returns to a fresh tech-founder"
  assert_file_contains "ML62: concrete PR number required" "$cmd" 'concrete numeric `PR_NUMBER`'
  assert_file_contains "ML63: PR head SHA is independently matched" "$cmd" 'matching remote `headRefOid`'
  assert_file_contains "ML64: default ancestry required before merge" "$cmd" 'merge-base --is-ancestor "origin/$default" "$PR_HEAD_SHA"'
  assert_file_contains "ML65: merge is supervisor-owned" "$cmd" 'gh pr merge "$PR_NUMBER"'
  assert_file_contains "ML66: merged SHA must land on default" "$cmd" 'merge-base --is-ancestor "$MERGE_SHA" "origin/$default"'
  assert_file_contains "ML67: deploy run is tied to merge SHA" "$cmd" '`headSha` equals `MERGE_SHA`'
  assert_file_contains "ML68: deploy poll uses concrete run" "$cmd" 'poll-gate.sh --run "$DEPLOY_RUN_ID"'
  assert_file_contains "ML69: latest deploy is not trusted" "$cmd" 'never trust "latest"'
  assert_file_contains "ML70: live QA requires timestamped assertions" "$cmd" "timestamped assertion evidence"
  assert_file_contains "ML71: unresolved deploy/live blocks success" "$cmd" "Missing URL, mismatched SHA"
  assert_file_contains "ML72: rollback gets deploy and live verification" "$cmd" "waits for the rollback-SHA deploy"
  assert_file_contains "ML73: rollback never counts fixed" "$cmd" "increment the delivered count for a rolled-back"
  assert_file_contains "ML74: result artifact lives in primary state" "$cmd" ".startup/maintain-loop/runs/<RUN_ID>/issue-<N>.md"
  assert_file_contains "ML75: result binds PR head SHA" "$cmd" "pr_head_sha:<sha>"
  assert_file_contains "ML76: result binds merge SHA" "$cmd" "merge_sha:<sha>"
  assert_file_contains "ML77: result binds tribunal SHA" "$cmd" 'verdict SHA equal to `pr_head_sha`'
  assert_file_contains "ML78: result binds deploy SHA" "$cmd" 'head SHA equal to `merge_sha`'
  assert_file_contains "ML79: evidence is re-queried before fixed/count/event" "$cmd" 'independently re-query those facts before writing `fixed:`'
  assert_file_contains "ML80: no-op emits no worker event" "$cmd" "emit no worker event"
  assert_file_contains "ML81: once sets one-issue cap" "$cmd" 'MAX_ISSUES=1'
  assert_file_contains "ML82: default max-issues is uncapped" "$cmd" "unset means no issue-count cap"
  assert_file_contains "ML83: max-merges default and rollback carveout" "$cmd" 'forward-merge cap, default `5`'
  assert_file_contains "ML84: rollback overage is explicit" "$cmd" "merge_budget_overage:rollback"
  assert_file_exists "ML85: Codex maintain-loop workflow exists" "$codex_cmd"
  assert_file_contains "ML86: Codex workflow aliases command" "$codex_cmd" "/maintain-loop"
  assert_file_contains "ML87: Codex workflow hard gates" "$codex_cmd" "Codex Maintain Hard Gates"
}

# ---------------------------------------------------------------------------
# Suite L: Auto-Commit Hook
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

  # K7: hooks.json PostToolUse has 13 Codex-supported entries
  local ptu_count
  ptu_count=$(jq '.hooks.PostToolUse | length' "$hooks_file" 2>/dev/null)
  assert_equals "K7: PostToolUse has 13 entries" "$ptu_count" "13"

  # K8: Fourth PostToolUse entry references auto-commit.sh
  local fourth_cmd
  fourth_cmd=$(jq -r '.hooks.PostToolUse[3].hooks[0].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "K8: fourth PostToolUse references auto-commit.sh" "$fourth_cmd" "auto-commit.sh"

  # K9: Artifact commits use the exact-file helper and never use a hook bypass flag.
  assert_file_not_contains "K9: artifact hook does not use a bypass flag" "$script" "\-\-no-verify"
  assert_file_contains "K9b: artifact commit uses isolated helper" "$script" "commit-artifact.sh"

  # K10: Handoff writes never commit product code.
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
  if [ "$commit_count" -eq 1 ] && ! (cd "$workdir" && git ls-files --error-unmatch backend/app.py >/dev/null 2>&1); then
    echo -e "  ${GREEN}PASS${NC} K10: handoff leaves product code uncommitted"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} K10: handoff swept product code into a commit"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("K10: handoff committed product code")
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

  # K13: no implementation directory is staged by the artifact hook.
  assert_file_not_contains "K13a: auto-commit never stages src" "$script" "git add -A src/"
  assert_file_not_contains "K13b: auto-commit never stages backend" "$script" "git add -A backend/"
  assert_file_not_contains "K13c: auto-commit never stages frontend" "$script" "git add -A frontend/"

  # K14: Functional — src remains untracked and no commit is created at handoff.
  workdir=$(mktemp -d)
  git init -q "$workdir"
  (cd "$workdir" && git config user.email "test@test.com" && git config user.name "Test" && git commit --allow-empty -m "init" -q)
  mkdir -p "$workdir/.startup/handoffs" "$workdir/src/app"
  echo "export const Page = () => null" > "$workdir/src/app/page.tsx"
  echo "handoff content" > "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/002-tech-to-business.md"}}' | bash "$script" 2>&1) || ec=$?
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  commit_count=$(cd "$workdir" && git log --oneline | wc -l)
  if [ "$commit_count" -eq 1 ] && ! (cd "$workdir" && git ls-files --error-unmatch src/app/page.tsx >/dev/null 2>&1); then
    echo -e "  ${GREEN}PASS${NC} K14: src code remains supervisor-owned"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} K14: src code was auto-committed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("K14: src code was auto-committed")
  fi
  rm -rf "$workdir"

  # K15: An artifact commit must not sweep a pre-staged product diff.
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email test@test.com && git config user.name Test && git commit --allow-empty -m init -q)
  mkdir -p "$workdir/docs/research" "$workdir/src"
  echo 'product' > "$workdir/src/app.js"; (cd "$workdir" && git add src/app.js)
  echo '# research' > "$workdir/docs/research/market.md"
  ec=0; output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/docs/research/market.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_output_contains "K15a: artifact was committed" "$(cd "$workdir" && git show --name-only --format= HEAD)" "docs/research/market.md"
  assert_output_not_contains "K15b: staged product absent from artifact commit" "$(cd "$workdir" && git show --name-only --format= HEAD)" "src/app.js"
  assert_output_contains "K15c: product remains staged" "$(cd "$workdir" && git diff --cached --name-only)" "src/app.js"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite G2: Staged-size / package-store guard (check-staged-size.sh) — issue #90
# ---------------------------------------------------------------------------

test_check_staged_size() {
  echo -e "\n${CYAN}Suite G2: Large-file / package-store commit guard${NC}"
  local script="$PLUGIN_ROOT/scripts/check-staged-size.sh"
  local workdir ec output

  # G1: script exists
  assert_file_exists "G1: check-staged-size.sh exists" "$script"

  # G2: clean small staged tree passes (exit 0)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  echo "hello" > "$workdir/README.md"
  (cd "$workdir" && git add README.md)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G2: clean staged tree passes" "$ec" 0
  rm -rf "$workdir"

  # G3: staged node_modules/ is rejected by name (exit 1)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/node_modules/pkg"; echo "x" > "$workdir/node_modules/pkg/index.js"
  (cd "$workdir" && git add -A node_modules/)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G3: staged node_modules rejected" "$ec" 1
  assert_output_contains "G3b: names dependency/store path" "$output" "dependency/store"
  rm -rf "$workdir"

  # G4: staged .pnpm-store/ is rejected (the exact issue #90 failure)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.pnpm-store/v11/files/0a"; echo "blob" > "$workdir/.pnpm-store/v11/files/0a/x"
  (cd "$workdir" && git add -A .pnpm-store/)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G4: staged .pnpm-store rejected" "$ec" 1
  rm -rf "$workdir"

  # G5: oversized blob rejected (threshold lowered to 1 MB for the test)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  head -c 2097152 /dev/zero > "$workdir/big.bin"
  (cd "$workdir" && git add big.bin)
  ec=0; output=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=1 bash "$script" 2>&1) || ec=$?
  assert_exit_code "G5: oversized blob rejected" "$ec" 1
  assert_output_contains "G5b: names the size limit" "$output" "limit"
  rm -rf "$workdir"

  # G6: same blob passes when the limit is raised above its size (override works)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  head -c 2097152 /dev/zero > "$workdir/big.bin"
  (cd "$workdir" && git add big.bin)
  ec=0; output=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=5 bash "$script" 2>&1) || ec=$?
  assert_exit_code "G6: oversized blob passes under raised limit" "$ec" 0
  rm -rf "$workdir"

  # G7: outside a git repo it is a silent no-op (exit 0)
  workdir=$(mktemp -d)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G7: non-git dir is a no-op" "$ec" 0
  rm -rf "$workdir"

  # G8: /bootstrap gitignores dependency trees and package stores (issue #90 primary fix).
  # The ignore rules live in templates/gitignore-block.txt, applied by bootstrap.md.
  local bootstrap="$PLUGIN_ROOT/commands/bootstrap.md"
  local gitignore_block="$PLUGIN_ROOT/templates/gitignore-block.txt"
  assert_file_contains "G8-ref: bootstrap applies the gitignore block" "$bootstrap" "templates/gitignore-block.txt"
  assert_file_contains "G8a: gitignore block has node_modules/" "$gitignore_block" "node_modules/"
  assert_file_contains "G8b: gitignore block has .pnpm-store/" "$gitignore_block" ".pnpm-store/"
  assert_file_contains "G8c: gitignore block has build output (dist/)" "$gitignore_block" "dist/"

  # G9: the guard is wired into the bootstrap commit and the /improve catch-all commit
  assert_file_contains "G9a: bootstrap runs the guard before commit" "$bootstrap" "check-staged-size.sh"
  assert_file_contains "G9b: improve uses supervisor commit guard" "$PLUGIN_ROOT/references/workflows/improve.md" "supervisor-commit.sh"
  assert_file_contains "G9c: tweak uses trapped commit guard" "$PLUGIN_ROOT/references/workflows/tweak.md" "tweak-run.sh"
  assert_file_contains "G9d: startup guards the initial git add -A" "$PLUGIN_ROOT/commands/startup.md" "check-staged-size.sh"

  # G10: measures the STAGED blob, not the working tree — stage a big blob, then truncate the
  # working-tree copy. The commit would still carry the big blob, so the guard must still reject.
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  head -c 2097152 /dev/zero > "$workdir/big.bin"
  (cd "$workdir" && git add big.bin)
  : > "$workdir/big.bin"   # working tree now 0 bytes; index still holds the 2 MB blob
  ec=0; output=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=1 bash "$script" 2>&1) || ec=$?
  assert_exit_code "G10: sizes the staged blob, not the working tree" "$ec" 1
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

  # L10: hooks.json PostToolUse has 13 Codex-supported entries
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

  # P21: pause metadata (paused_at, paused_reason) survives compaction (issue #24).
  # A paused loop's pause timestamp/reason are legitimate inline state and must NOT be
  # swept to the archive when an unrelated key triggers compaction.
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 13
  state="$workdir/.startup/state.json"
  jq '.status = "paused" | .paused_at = "2026-05-10T12:00:00Z" | .paused_reason = "investor stepped away"' \
    "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  seed_handoffs "$state" 15
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "P21: compaction with pause metadata exits 0" "$ec" 0
  assert_json_field "P21b: paused_at preserved inline"     "$state" '.paused_at // "MISSING"'     "2026-05-10T12:00:00Z"
  assert_json_field "P21c: paused_reason preserved inline" "$state" '.paused_reason // "MISSING"' "investor stepped away"
  assert_json_field "P21d: status=paused preserved"        "$state" ".status" "paused"
  # Must be kept inline, NOT also copied into the archive (no duplication).
  assert_json_field "P21e: paused_at not duplicated into archive"     "$workdir/.startup/state-archive.json" '([.entries[].keys.paused_at] | map(select(. != null)) | length)'     "0"
  assert_json_field "P21f: paused_reason not duplicated into archive" "$workdir/.startup/state-archive.json" '([.entries[].keys.paused_reason] | map(select(. != null)) | length)' "0"
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

  # R11c: pre-migration timestamp-prefixed files don't poison max NNN
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/005-business-to-tech.md"
  touch "$workdir/.startup/handoffs/2026-04-16T074318Z-business-to-tech-improve-189.md"
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/bogus.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R11c: exits 2" "$ec" 2
  assert_output_contains "R11d: next NNN ignores timestamp prefix, is 006" "$output" "006"
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

  # S4: roundtrip-signoff moves to signoffs/
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/133-roundtrip-signoff.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S4: dry-run with signoff exits 0" "$ec" 0
  assert_output_contains "S4b: plan moves to signoffs/" "$output" "Move to .startup/signoffs/"
  assert_output_contains "S4c: plan lists 133-roundtrip-signoff" "$output" "133-roundtrip-signoff.md"
  rm -rf "$workdir"

  # S5: qa-review moves to reviews/
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/369-qa-review.md"
  touch "$workdir/.startup/handoffs/business-to-tech-satisfaction-guarantee.lawyer.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S5: plan moves to reviews/" "$output" "Move to .startup/reviews/"
  assert_output_contains "S5b: plan lists qa-review file" "$output" "369-qa-review.md"
  assert_output_contains "S5c: .lawyer.md renamed to lawyer-*" "$output" "lawyer-business-to-tech-satisfaction-guarantee.md"
  rm -rf "$workdir"

  # S6: binary moves to attachments/
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/arve_fixed_logo_preview.pdf"
  touch "$workdir/.startup/handoffs/arve_fixed_logo_preview.png"
  mkdir -p "$workdir/.startup/handoffs/421-artifacts"
  touch "$workdir/.startup/handoffs/421-artifacts/sample.pdf"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S6: plan moves to attachments/" "$output" "Move to .startup/attachments/"
  assert_output_contains "S6b: plan lists pdf" "$output" "arve_fixed_logo_preview.pdf"
  assert_output_contains "S6c: plan lists directory" "$output" "421-artifacts"
  rm -rf "$workdir"

  # S7: topic-slug renames to next-available NNN
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/012-business-to-tech.md"
  # older slug file — should get NNN 013
  touch -t 202603010000 "$workdir/.startup/handoffs/business-to-tech-foo.md"
  # newer slug file — should get NNN 014
  touch -t 202603020000 "$workdir/.startup/handoffs/tech-to-business-bar.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S7: rename section present" "$output" "Rename"
  assert_output_contains "S7b: foo → 013-business-to-tech" "$output" "business-to-tech-foo.md → 013-business-to-tech.md"
  assert_output_contains "S7c: bar → 014-tech-to-business" "$output" "tech-to-business-bar.md → 014-tech-to-business.md"
  rm -rf "$workdir"

  # S8: timestamp-prefix renames with canonical direction extracted
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/2026-04-16T074318Z-business-to-tech-improve-189.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S8: timestamp file renamed to business-to-tech" "$output" "2026-04-16T074318Z-business-to-tech-improve-189.md → 001-business-to-tech.md"
  rm -rf "$workdir"

  # S9: frontmatter wins over filename
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/business-to-tech-misnamed.md" <<'EOF'
---
from: tech-founder
to: business-founder
iteration: 3
date: 2026-04-10
type: implementation
---

## Summary
Actually a tech-to-business handoff misnamed.
EOF
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S9: frontmatter-derived direction wins" "$output" "business-to-tech-misnamed.md → 001-tech-to-business.md"
  rm -rf "$workdir"

  # S10: --apply performs moves and renames
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/001-business-to-tech.md"
  touch "$workdir/.startup/handoffs/133-roundtrip-signoff.md"
  touch "$workdir/.startup/handoffs/369-qa-review.md"
  touch "$workdir/.startup/handoffs/arve.pdf"
  touch "$workdir/.startup/handoffs/business-to-tech-foo.md"
  ec=0
  output=$(bash "$script" --apply "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S10: --apply exits 0" "$ec" 0
  assert_file_exists "S10b: canonical preserved" "$workdir/.startup/handoffs/001-business-to-tech.md"
  assert_file_exists "S10c: signoff moved" "$workdir/.startup/signoffs/133-roundtrip-signoff.md"
  assert_file_exists "S10d: review moved" "$workdir/.startup/reviews/369-qa-review.md"
  assert_file_exists "S10e: binary moved" "$workdir/.startup/attachments/arve.pdf"
  assert_file_exists "S10f: slug renamed to 002-business-to-tech.md" "$workdir/.startup/handoffs/002-business-to-tech.md"
  # Source filenames must no longer exist in handoffs/
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -e "$workdir/.startup/handoffs/business-to-tech-foo.md" ]; then
    echo -e "  ${GREEN}PASS${NC} S10g: source slug removed from handoffs/"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S10g: source slug still in handoffs/"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S10g: source slug not removed")
  fi
  assert_file_exists "S10h: INDEX.md regenerated" "$workdir/.startup/handoffs/INDEX.md"
  rm -rf "$workdir"

  # S11: --apply collision appends -dup suffix
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs" "$workdir/.startup/signoffs"
  touch "$workdir/.startup/handoffs/133-roundtrip-signoff.md"
  touch "$workdir/.startup/signoffs/133-roundtrip-signoff.md"  # pre-existing
  ec=0
  output=$(bash "$script" --apply "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S11: collision exits 0" "$ec" 0
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if ls "$workdir/.startup/signoffs/"*-dup* >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} S11b: collision produces -dup file"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S11b: no -dup file in signoffs/"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S11b: no -dup file")
  fi
  rm -rf "$workdir"

  # S12: directory collision in attachments/ — extensionless dest doesn't corrupt path
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs/421-artifacts"
  mkdir -p "$workdir/.startup/attachments/421-artifacts"  # pre-existing dir
  touch "$workdir/.startup/handoffs/421-artifacts/x.txt"
  touch "$workdir/.startup/attachments/421-artifacts/y.txt"
  ec=0
  output=$(bash "$script" --apply "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S12: dir collision exits 0" "$ec" 0
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if ls -d "$workdir/.startup/attachments/421-artifacts-dup"*/ >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} S12b: extensionless dir collision produces -dup suffix"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S12b: no -dup dir in attachments/"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S12b: no -dup dir")
  fi
  # The original pre-existing dir must still exist (only the new one got renamed)
  assert_file_exists "S12c: pre-existing attachments/421-artifacts preserved" "$workdir/.startup/attachments/421-artifacts/y.txt"
  assert_output_not_contains "S12d: no WARN lines" "$output" "[WARN]"
  rm -rf "$workdir"

  # S13: orphan roles fold to canonical directions (investor, team, team-lead)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/205-investor-to-business.md"
  touch "$workdir/.startup/handoffs/225-investor-to-tech.md"
  touch "$workdir/.startup/handoffs/476-business-to-team.md"
  touch "$workdir/.startup/handoffs/tech-to-team-lead-fixes.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S13: investor-to-business folds to business-to-tech" "$output" "205-investor-to-business.md → 001-business-to-tech.md"
  assert_output_contains "S13b: investor-to-tech folds to business-to-tech" "$output" "225-investor-to-tech.md → 002-business-to-tech.md"
  assert_output_contains "S13c: business-to-team folds to business-to-tech" "$output" "476-business-to-team.md → 003-business-to-tech.md"
  assert_output_contains "S13d: tech-to-team-lead folds to tech-to-business" "$output" "tech-to-team-lead-fixes.md → 004-tech-to-business.md"
  assert_output_not_contains "S13e: no manual review" "$output" "Manual review needed"
  rm -rf "$workdir"

  # S13e: --apply exits non-zero when a mv operation fails
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  # Pre-create a read-only destination dir so mv into it will fail
  mkdir -p "$workdir/.startup/attachments"
  touch "$workdir/.startup/handoffs/broken.pdf"
  chmod -w "$workdir/.startup/attachments"
  ec=0
  output=$(bash "$script" --apply "$workdir/.startup/handoffs" 2>&1) || ec=$?
  chmod +w "$workdir/.startup/attachments"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$ec" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} S13f: --apply exits non-zero on mv failure (got $ec)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S13f: --apply exited 0 despite mv failure"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S13f: --apply should exit non-zero on mv failure")
  fi
  assert_output_contains "S13g: warning line present" "$output" "[WARN]"
  rm -rf "$workdir"

  # S14: widened review rule catches regression-results without trailing hyphen + sequencing-plan
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/317-regression-results.md"
  touch "$workdir/.startup/handoffs/311-sequencing-plan.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S14: regression-results routed to reviews/" "$output" "317-regression-results.md"
  assert_output_contains "S14b: sequencing-plan routed to reviews/" "$output" "311-sequencing-plan.md"
  assert_output_contains "S14c: both in reviews section" "$output" "Move to .startup/reviews/ (2 files)"
  assert_output_not_contains "S14d: no manual review" "$output" "Manual review needed"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite W: check.sh template (canonical full-suite entrypoint)
# ---------------------------------------------------------------------------

test_check_sh_template() {
  echo -e "\n${CYAN}Suite W: check.sh template${NC}"
  local tmpl="$PLUGIN_ROOT/templates/check.sh"
  local workdir ec output

  # W1: template exists and has the bash shebang
  assert_file_exists "W1: check.sh template exists" "$tmpl"
  assert_file_contains "W2: uses env bash shebang" "$tmpl" '#!/usr/bin/env bash'
  assert_file_contains "W3: has REQUIRED_SUITES array" "$tmpl" 'REQUIRED_SUITES='
  assert_file_contains "W4: has run_suite helper" "$tmpl" 'run_suite()'
  assert_file_contains "W5: has suite_stub helper" "$tmpl" 'suite_stub()'
  assert_file_contains "W6: VERIFY COMPLETE banner present" "$tmpl" 'VERIFY COMPLETE'

  # W7: vacuous run (no suites declared) → non-zero, refuses to report success
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W7: vacuous run fails (non-zero)" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W7b: refuses to report success" "$output" "no suites ran"
  rm -rf "$workdir"

  # W8: a wired, green suite → exit 0
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  # declare + wire frontend_tests to a trivially-green command.
  # NOTE: the wiring seds match `^name().*` so they are agnostic to the
  # template's column-aligned spacing between `()` and `{`.
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(frontend_tests)/' "$workdir/check.sh"
  sed -i "s|^frontend_tests().*|frontend_tests() { run_suite frontend_tests 'true'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_exit_code "W8: wired green suite passes" "$ec" 0
  rm -rf "$workdir"

  # W9: a declared-but-unwired suite → non-zero (Guard 2)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(backend_tests)/' "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W9: unwired declared suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W9b: names the unwired suite" "$output" "backend_tests"
  rm -rf "$workdir"

  # W9c: declared suite hand-edited to return 0 WITHOUT run_suite → still fails (Guard 2)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(backend_tests)/' "$workdir/check.sh"
  sed -i 's|^backend_tests().*|backend_tests() { true; }|' "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W9c: declared-but-never-ran suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W9d: Guard 2 names never-ran suite" "$output" "never ran a command"
  rm -rf "$workdir"

  # W10: a wired, RED suite → non-zero
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(lint)/' "$workdir/check.sh"
  sed -i "s|^lint().*|lint() { run_suite lint 'false'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W10: wired red suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  rm -rf "$workdir"

  # W11: mid-command failure in an &&-chain propagates (no pipefail masking)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(typecheck)/' "$workdir/check.sh"
  sed -i "s|^typecheck().*|typecheck() { run_suite typecheck 'false \&\& true'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W11: &&-chain mid failure fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  rm -rf "$workdir"

  # W12-W16: CI workflow template
  local ci="$PLUGIN_ROOT/templates/ci-workflow.yml"
  assert_file_exists "W12: ci-workflow.yml exists" "$ci"
  assert_file_contains "W13: workflow name is CI" "$ci" '^name: CI'
  assert_file_contains "W14: pull_request trigger" "$ci" '^  pull_request:'
  assert_file_contains "W15: job id check" "$ci" '^  check:'
  assert_file_contains "W16: runs ./check.sh" "$ci" 'run: ./check.sh'
  assert_file_contains "W17: STACK_SETUP token alone on its own comment line" "$ci" '^      # {{STACK_SETUP}}$'
}

# ---------------------------------------------------------------------------
# Suite X: bootstrap pre-merge safety-net scaffolding
# ---------------------------------------------------------------------------

test_bootstrap_safety_net() {
  echo -e "\n${CYAN}Suite X: bootstrap safety-net scaffolding${NC}"
  local cmd="$PLUGIN_ROOT/commands/bootstrap.md"
  local workdir ec output

  # Extract the scaffolding bash block from bootstrap.md
  local script
  workdir=$(mktemp -d)
  extract_md_bash "$cmd" "## Step 6.5: Scaffold the pre-merge safety net" > "$workdir/scaffold.sh"

  # X1: the block is non-empty
  assert_equals "X1: scaffold block extracted" "$([ -s "$workdir/scaffold.sh" ] && echo yes || echo no)" "yes"

  # X2-X5: no stack present → scaffolds files with the placeholder marker
  mkdir -p "$workdir/repo"; (cd "$workdir/repo" && git init -q)
  mkdir -p "$workdir/repo/.startup"
  ec=0; output=$(cd "$workdir/repo" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X2: scaffold runs cleanly" "$ec" 0
  assert_file_exists "X3: ci.yml created" "$workdir/repo/.github/workflows/ci.yml"
  assert_file_exists "X4: check.sh created" "$workdir/repo/check.sh"
  assert_equals "X5: check.sh executable" "$([ -x "$workdir/repo/check.sh" ] && echo yes || echo no)" "yes"
  assert_file_contains "X6: human-tasks has branch-protection task" "$workdir/repo/docs/human-tasks.md" "branch protection"
  assert_file_contains "X7: human task is sequenced after green CI" "$workdir/repo/docs/human-tasks.md" "first CI run"
  # no stack detected → placeholder marker remains in ci.yml
  assert_file_contains "X8: no-stack keeps TECH-FOUNDER marker" "$workdir/repo/.github/workflows/ci.yml" "TECH-FOUNDER"

  # X9: idempotent — re-run does not duplicate the human task or error
  ec=0; output=$(cd "$workdir/repo" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X9: re-run is idempotent (clean exit)" "$ec" 0
  local count
  # Count the unique idempotency-guard heading (the phrase "branch protection"
  # itself appears twice per block: in the heading and in the UI instructions).
  count=$(grep -c "Require the CI check (branch protection)" "$workdir/repo/docs/human-tasks.md")
  assert_equals "X10: branch-protection task not duplicated" "$count" "1"

  # X11-X13: node stack detected → STACK_SETUP substituted with setup-node
  rm -rf "$workdir/repo2"; mkdir -p "$workdir/repo2/.startup"; (cd "$workdir/repo2" && git init -q)
  echo '{"scripts":{"test":"jest"}}' > "$workdir/repo2/package.json"
  ec=0; output=$(cd "$workdir/repo2" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X11: node scaffold runs cleanly" "$ec" 0
  assert_file_contains "X12: node setup injected" "$workdir/repo2/.github/workflows/ci.yml" "setup-node"
  assert_file_contains "X13: check.sh has node detection hint" "$workdir/repo2/check.sh" "DETECTED"

  # X14-X15: node WITHOUT lockfile → npm install, not npm ci
  assert_file_contains "X14: no-lockfile uses npm install" "$workdir/repo2/.github/workflows/ci.yml" "npm install"
  assert_file_not_contains "X15: no-lockfile avoids npm ci" "$workdir/repo2/.github/workflows/ci.yml" "npm ci"

  # X16-X17: node WITH lockfile → npm ci + cache
  rm -rf "$workdir/repo3"; mkdir -p "$workdir/repo3/.startup"; (cd "$workdir/repo3" && git init -q)
  echo '{"scripts":{"test":"jest"}}' > "$workdir/repo3/package.json"
  echo '{}' > "$workdir/repo3/package-lock.json"
  (cd "$workdir/repo3" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" >/dev/null 2>&1)
  assert_file_contains "X16: lockfile uses npm ci" "$workdir/repo3/.github/workflows/ci.yml" "npm ci"
  assert_file_contains "X17: lockfile sets cache npm" "$workdir/repo3/.github/workflows/ci.yml" "cache: npm"

  # X18: python WITH requirements.txt → pip install -r
  rm -rf "$workdir/repo4"; mkdir -p "$workdir/repo4/.startup"; (cd "$workdir/repo4" && git init -q)
  echo 'pytest' > "$workdir/repo4/requirements.txt"
  (cd "$workdir/repo4" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" >/dev/null 2>&1)
  assert_file_contains "X18: requirements uses pip -r" "$workdir/repo4/.github/workflows/ci.yml" "pip install -r requirements.txt"
  assert_file_contains "X18b: python setup injected" "$workdir/repo4/.github/workflows/ci.yml" "setup-python"

  # X19: python pyproject-only (no requirements.txt) → pip install -e .
  rm -rf "$workdir/repo5"; mkdir -p "$workdir/repo5/.startup"; (cd "$workdir/repo5" && git init -q)
  printf '[project]\nname = "x"\n' > "$workdir/repo5/pyproject.toml"
  (cd "$workdir/repo5" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" >/dev/null 2>&1)
  assert_file_contains "X19: pyproject-only uses pip install -e ." "$workdir/repo5/.github/workflows/ci.yml" "pip install -e \."

  # X20: the extracted Step 6.5 block has NO nested triple-backtick fences
  fence_cnt=$(grep -c '^```' "$workdir/scaffold.sh" || true)
  assert_equals "X20: no nested code fences in scaffold block" "$fence_cnt" "0"

  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite Y: canonical entrypoint wiring (plugin-self drift guard)
# ---------------------------------------------------------------------------

test_canonical_entrypoint_wiring() {
  echo -e "\n${CYAN}Suite Y: canonical entrypoint wiring${NC}"
  assert_file_contains "Y1: improve.md names check.sh" \
    "$PLUGIN_ROOT/references/workflows/improve.md" "check.sh"
  assert_file_contains "Y2: tech-founder SKILL names check.sh" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "check.sh"
  assert_file_contains "Y3: ci-workflow names check.sh" \
    "$PLUGIN_ROOT/templates/ci-workflow.yml" "check.sh"
  assert_file_contains "Y4: tech-founder names canonical entrypoint" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Canonical entrypoint"
  assert_file_contains "Y5: tech-founder has derived-output guidance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Derived-output correctness"
  assert_file_contains "Y6: tech-founder names green-but-wrong risk" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "green-but-wrong"
  assert_file_contains "Y7: tech-founder mentions golden suite" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "golden"
  assert_file_contains "Y7a: tech-founder requires recurrence class" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "root cause / recurrence class"
  assert_file_contains "Y7b: tech-founder fixes failure class" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "fix the class"
  assert_file_contains "Y7c: tech-founder requires mechanical guard" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "durable mechanical guard"
  assert_file_contains "Y7d: tech-founder records red-green proof" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "red-before/green-after proof"
  assert_file_contains "Y8: quality-standards has single-source-of-truth principle" \
    "$PLUGIN_ROOT/skills/tech-founder/references/quality-standards.md" "Single source of truth"
  assert_file_contains "Y9: quality-standards warns about re-derived rules" \
    "$PLUGIN_ROOT/skills/tech-founder/references/quality-standards.md" "re-derive"
  assert_file_contains "Y10: maintain agent has independent spot-check" \
    "$PLUGIN_ROOT/agents/business-founder-maintain.md" "independent source"
  assert_file_contains "Y11: build agent has independent spot-check" \
    "$PLUGIN_ROOT/agents/business-founder.md" "independent source"
  assert_file_contains "Y12: maintain agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/agents/business-founder-maintain.md" "another layer"
  assert_file_contains "Y13: build agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/agents/business-founder.md" "another layer"
  assert_file_contains "Y14: quality-standards handoff checklist names check.sh" \
    "$PLUGIN_ROOT/skills/tech-founder/references/quality-standards.md" "check.sh"
}

# ---------------------------------------------------------------------------
# Suite W: monitor-dedup.sh
# ---------------------------------------------------------------------------

test_monitor_dedup() {
  echo -e "\n${CYAN}Suite W: monitor-dedup.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/monitor-dedup.sh"
  local workdir ec output state mins

  # W1: first run (no state) → 1440-minute window, exit 0
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W1: window first-run exits 0" "$ec" 0
  assert_output_contains "W1: first-run window is 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  # W2: recent last_run_at (30m ago) → window between 1 and 60
  workdir=$(make_workdir); state="$workdir/state.json"
  printf '{"version":1,"last_run_at":"%s","patterns":{}}' "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$state" 2>&1) || ec=$?
  mins=$(printf '%s\n' "$output" | sed -n 's/^MONITOR_SINCE_MINUTES=//p')
  assert_exit_code "W2: window exits 0" "$ec" 0
  assert_equals "W2: ~30m window within (1,60]" "$([ "$mins" -ge 1 ] && [ "$mins" -le 60 ] && echo ok)" "ok"

  # W3: old last_run_at → capped at 2880, exit 0
  workdir=$(make_workdir); state="$workdir/state.json"
  printf '{"version":1,"last_run_at":"%s","patterns":{}}' "$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$state" 2>&1) || ec=$?
  assert_exit_code "W3: window exits 0" "$ec" 0
  assert_output_contains "W3: capped at 2880" "$output" "MONITOR_SINCE_MINUTES=2880"

  # W4: corrupt JSON state → first-run window
  workdir=$(make_workdir); echo 'not json {{{' > "$workdir/state.json"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W4: corrupt state exits 0" "$ec" 0
  assert_output_contains "W4: corrupt → 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  # W4b: valid JSON but unparseable last_run_at → first-run window (must not crash under set -e)
  workdir=$(make_workdir)
  printf '{"version":1,"last_run_at":"not-a-date","patterns":{}}' > "$workdir/state.json"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W4b: bad timestamp exits 0" "$ec" 0
  assert_output_contains "W4b: bad timestamp → 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  local L  # gh calls log path, per-test

  # W5: new pattern → CREATE; --repo present on every gh call; state records issue
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-1","title":"[Monitor] err","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=142 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W5: create exits 0" "$ec" 0
  assert_output_contains "W5: action create" "$output" '"action":"create"'
  assert_file_contains "W5: gh issue create called" "$L" "issue create"
  assert_equals "W5: every gh call carries --repo" "$(grep -c -- '--repo o/r' "$L")" "$(wc -l < "$L" | tr -d ' ')"
  assert_equals "W5: state records 142" "$(jq -c '.patterns["pipeline:err:categorize"].gh_issue' "$state")" "142"

  # W6: same (entity,pattern) in state → SKIP, NO gh calls at all
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W6: action skip" "$output" '"action":"skip"'
  # reconciliation may `gh issue view` to confirm the stored issue is still open, but
  # an already-seen (entity,pattern) must never create or comment.
  assert_file_not_contains "W6: no create" "$L" "issue create"
  assert_file_not_contains "W6: no comment" "$L" "issue comment"

  # W7: known pattern, NEW entity → COMMENT; entity appended (sessions length 2)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-2","title":"T","body":"B","summary":"recurred"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W7: action comment" "$output" '"action":"comment"'
  assert_file_contains "W7: commented on 142" "$L" "issue comment 142"
  assert_equals "W7: 2 sessions" "$(jq -c '.patterns["pipeline:err:categorize"].sessions|length' "$state")" "2"

  # W8: same entity, DIFFERENT pattern → CREATE (not collapsed)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:timeout:narrative","severity":"high","entity":"S-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=143 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W8: action create" "$output" '"action":"create"'
  assert_output_not_contains "W8: not a comment" "$output" '"action":"comment"'
  assert_equals "W8: new pattern stored" "$(jq -c '.patterns["pipeline:timeout:narrative"].gh_issue' "$state")" "143"

  # W9: two findings, same pattern, different entity, ONE run → 1 create + 1 comment, both entities stored
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n%s\n' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=150 GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_equals "W9: one create" "$(grep -c 'issue create' "$L")" "1"
  assert_equals "W9: one comment" "$(grep -c 'issue comment' "$L")" "1"
  assert_equals "W9: both entities stored" "$(jq -c '.patterns["payment:stuck"].sessions|length' "$state")" "2"

  # W9b: empty stdin → exit 0, state initialized, last_run_at advanced (non-null)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r < /dev/null 2>&1) || ec=$?
  assert_exit_code "W9b: empty stdin exits 0" "$ec" 0
  assert_file_exists "W9b: state written" "$state"
  assert_output_not_contains "W9b: last_run_at advanced" "$(jq -r '.last_run_at' "$state")" "null"

  # W10: stored issue CLOSED → CREATE fresh (sessions fixture uses "" for null entity)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:llm-gap:failure":{"gh_issue":99,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"ops:llm-gap:failure","severity":"high","entity":null,"title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=CLOSED GH_CREATE_NUMBER=200 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W10: closed → create" "$output" '"action":"create"'
  assert_equals "W10: now issue 200" "$(jq -c '.patterns["ops:llm-gap:failure"].gh_issue' "$state")" "200"

  # W10b: stored issue, gh view FAILS → conservative: treat as OPEN → COMMENT, not create
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:llm-gap:failure":{"gh_issue":99,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"ops:llm-gap:failure","severity":"high","entity":"E-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue view" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W10b: view-fail → comment" "$output" '"action":"comment"'
  assert_file_not_contains "W10b: no duplicate create" "$L" "issue create"

  # W11: lost state, an existing open issue whose body embeds the markers → adopt/COMMENT
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:failed","severity":"high","entity":"P-9","title":"T","body":"B","summary":"again"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    GH_SEARCH_JSON='[{"number":321}]' GH_VIEW_BODY='**Pattern:** `payment:failed`
**Entity:** `P-9`' \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W11: recovered → comment" "$output" '"action":"comment"'
  assert_file_contains "W11: commented on 321" "$L" "issue comment 321"
  assert_file_contains "W11: recovery search is colon-tokenized" "$L" "payment failed"
  assert_file_not_contains "W11: no duplicate create" "$L" "issue create"

  # W11b: search hit but body lacks the entity marker → do NOT adopt → CREATE
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:failed","severity":"high","entity":"P-9","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=500 \
    GH_SEARCH_JSON='[{"number":777}]' GH_VIEW_BODY='**Pattern:** `payment:failed`
**Entity:** `SOMEONE-ELSE`' \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W11b: mismatch → create" "$output" '"action":"create"'
  assert_file_not_contains "W11b: did not comment on 777" "$L" "issue comment 777"

  # W12: malformed line → tracking issue + non-zero, BUT the window ADVANCES.
  # Malformed input is NOT a transient op failure — it is already escalated via the
  # tracking issue, and re-emits every run; freezing last_run_at on it causes silent
  # window degradation (issue #85). Only real gh op failures may freeze the window.
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n' 'this is not json' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=400 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12: malformed → non-zero" "$ec" 1
  assert_file_contains "W12: monitor-input:malformed filed" "$L" "monitor-input:malformed"
  assert_output_not_contains "W12: window advanced past frozen ts" "$(jq -r '.last_run_at' "$state")" "2026-06-01T00:00:00Z"

  # W12b: multiple malformed lines → exactly ONE tracking issue
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n%s\n' 'garbage one' 'garbage two' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=401 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_equals "W12b: one malformed issue" "$(grep -c 'monitor-input:malformed' "$L")" "1"

  # W12c: an OPEN malformed-input tracking issue already in state → do NOT file a duplicate,
  # but DO append the new malformed lines as a recurrence comment (recurring signal, #85),
  # and the window still ADVANCES (malformed is not a transient op failure).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:monitor-input:malformed":{"gh_issue":300,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' 'garbage' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_CREATE_NUMBER=301 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12c: malformed run still non-zero" "$ec" 1
  assert_file_not_contains "W12c: no duplicate malformed issue created" "$L" "issue create"
  assert_file_contains "W12c: recurrence comment appended to open tracking issue" "$L" "issue comment 300"
  assert_output_not_contains "W12c: window advanced (null→ts)" "$(jq -r '.last_run_at' "$state")" "null"

  # W12e: a malformed line PLUS a real gh op failure → op_failed freezes the window.
  # Proves the window advances ONLY when there is no transient op failure (#85): the
  # malformed line alone would advance it, but the failed create must still freeze it.
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-02T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n%s\n' 'not json' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=420 GH_FAIL_ON="issue create" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12e: op failure → non-zero" "$ec" 1
  assert_equals "W12e: window frozen on op failure" "$(jq -r '.last_run_at' "$state")" "2026-06-02T00:00:00Z"

  # W13: gh create fails → not in state, non-zero, window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue create" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W13: gh fail → non-zero" "$ec" 1
  assert_equals "W13: not in state" "$(jq -c '.patterns["payment:stuck"] // "absent"' "$state")" '"absent"'
  assert_equals "W13: window unchanged" "$(jq -r '.last_run_at' "$state")" "2026-06-01T00:00:00Z"

  # W13b: comment fails on known new entity → non-zero, entity NOT appended, window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{"payment:stuck":{"gh_issue":50,"sessions":["P-1"],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_FAIL_ON="issue comment" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W13b: comment fail → non-zero" "$ec" 1
  assert_equals "W13b: entity not appended" "$(jq -c '.patterns["payment:stuck"].sessions|length' "$state")" "1"

  # W14: --dry-run → exit 0, no state file, no gh calls
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14: dry-run exits 0" "$ec" 0
  assert_file_not_exists "W14: no state written" "$state"
  assert_file_not_exists "W14: no gh calls" "$L"
  assert_output_contains "W14: would create" "$output" '"action":"create"'

  # W14d: --dry-run WITHOUT --repo must not call `gh repo view` to resolve the repo (offline-safe)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14d: dry-run without --repo exits 0" "$ec" 0
  assert_file_not_exists "W14d: no gh calls (no repo resolution)" "$L"
  assert_output_contains "W14d: would create" "$output" '"action":"create"'

  # W14e: dry-run previews within-batch dedup — two same-pattern/different-entity findings → 1 create + 1 comment, not 2 creates
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n%s\n' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14e: dry-run exits 0" "$ec" 0
  assert_equals "W14e: one create previewed" "$(printf '%s' "$output" | grep -c '"action":"create"')" "1"
  assert_equals "W14e: one comment previewed" "$(printf '%s' "$output" | grep -c '"action":"comment"')" "1"

  # W15: invalid pattern_key → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"BAD KEY!!","severity":"high","entity":"X","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=402 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W15: invalid key → non-zero" "$ec" 1
  assert_output_contains "W15: action malformed" "$output" '"action":"malformed"'

  # W15b: missing required field (no body) → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"X","title":"T"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=403 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15b: missing body → malformed" "$output" '"action":"malformed"'

  # W15c: entity wrong type (object) → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":{"x":1},"title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=404 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15c: bad entity type → malformed" "$output" '"action":"malformed"'

  # W15d: entity containing a backtick → malformed (would corrupt markers / inject markdown)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"a`b","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=410 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15d: backtick entity → malformed" "$output" '"action":"malformed"'

  # W20: legacy unversioned state with a compatible patterns shape → UPGRADE in place,
  # back up the original first, and preserve existing mappings — no data loss, no duplicate
  # issues for already-tracked patterns (#88).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"last_run_at":"2026-05-01T00:00:00Z","patterns":{"payment:stuck":{"gh_issue":77,"sessions":["P-1"],"first_seen":"2026-05-01T00:00:00Z","last_seen":"2026-05-01T00:00:00Z"}}}' > "$state"
  cp "$state" "$workdir/orig.json"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20: legacy-state commit exits 0" "$ec" 0
  assert_output_contains "W20: existing mapping recognized → skip" "$output" '"action":"skip"'
  assert_file_not_contains "W20: no duplicate issue created" "$L" "issue create"
  assert_file_exists "W20: original backed up" "$state.pre-v1.bak"
  assert_equals "W20: backup preserves original bytes" "$(cat "$state.pre-v1.bak")" "$(cat "$workdir/orig.json")"
  assert_json_field "W20: upgraded to version 1" "$state" ".version" "1"
  assert_equals "W20: mapping preserved" "$(jq -c '.patterns["payment:stuck"].gh_issue' "$state")" "77"

  # W20b: existing-but-incompatible state (valid JSON, no patterns object) → back up + warn,
  # then start fresh and proceed — never a silent overwrite (#88).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"hello":"world","reported_cids":[1,2,3]}' > "$state"
  cp "$state" "$workdir/orig.json"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=88 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20b: incompatible-state commit exits 0" "$ec" 0
  assert_output_contains "W20b: warns about incompatible state" "$output" "WARNING"
  assert_file_exists "W20b: original backed up" "$state.pre-v1.bak"
  assert_equals "W20b: backup preserves original bytes" "$(cat "$state.pre-v1.bak")" "$(cat "$workdir/orig.json")"
  assert_output_contains "W20b: filed the new finding" "$output" '"action":"create"'
  assert_json_field "W20b: upgraded to version 1" "$state" ".version" "1"

  # W20c: a healthy v1 state file must NOT spawn a .pre-v1.bak (no needless backup every run).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r < /dev/null 2>&1) || ec=$?
  assert_exit_code "W20c: v1 state commit exits 0" "$ec" 0
  assert_file_not_exists "W20c: no backup for healthy v1 state" "$state.pre-v1.bak"

  # W20d: dry-run must not mutate — no backup written even for a legacy state file.
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20d: dry-run legacy exits 0" "$ec" 0
  assert_file_not_exists "W20d: dry-run writes no backup" "$state.pre-v1.bak"

  # W20e: legacy state with a malformed pattern entry → the upgrade DROPS schema-incompatible
  # entries (must be an object with numeric gh_issue + array sessions) so downstream commit
  # never crashes indexing them; the dropped key is re-created cleanly (#88 robustness).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"patterns":{"good:one":{"gh_issue":55,"sessions":["E-1"],"first_seen":"2026-05-01T00:00:00Z","last_seen":"2026-05-01T00:00:00Z"},"bad:two":"not-an-object"}}' > "$state"
  printf '%s\n' '{"pattern_key":"bad:two","severity":"high","entity":"E-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_CREATE_NUMBER=66 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20e: malformed-entry legacy commit exits 0" "$ec" 0
  assert_output_contains "W20e: dropped bad entry → fresh create" "$output" '"action":"create"'
  assert_equals "W20e: compatible entry preserved" "$(jq -c '.patterns["good:one"].gh_issue' "$state")" "55"
  assert_equals "W20e: bad:two re-created cleanly" "$(jq -c '.patterns["bad:two"].gh_issue' "$state")" "66"

  # W20g: if the .pre-v1.bak backup cannot be written, ABORT before any gh op or overwrite —
  # never silently destroy the original (the core #88 guarantee; codex review).
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"
  mkdir -p "$workdir/ro"; printf '{"patterns":{}}' > "$workdir/ro/state.json"; cp "$workdir/ro/state.json" "$workdir/orig.json"
  chmod 555 "$workdir/ro"
  printf '%s\n' '{"pattern_key":"x:y","severity":"high","entity":"E","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=9 \
    bash "$script" commit --state "$workdir/ro/state.json" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  chmod 755 "$workdir/ro"
  assert_exit_code "W20g: backup-failure aborts non-zero" "$ec" 1
  assert_file_not_contains "W20g: aborted before any gh create" "$L" "issue create"
  assert_equals "W20g: original state untouched" "$(cat "$workdir/ro/state.json")" "$(cat "$workdir/orig.json")"

  # W21: a non-canonical severity ("High") is normalized to lowercase — no junk grey label (#86).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"High","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=86 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W21: normalized-severity commit exits 0" "$ec" 0
  assert_file_contains "W21: applies canonical 'high' label" "$L" ",high"
  assert_file_not_contains "W21: no capitalized 'High' label" "$L" "High"

  # W21b: an unsupported severity ("critical") maps to the default "medium" with a warning (#86).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"critical","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=87 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W21b: unknown-severity commit exits 0" "$ec" 0
  assert_output_contains "W21b: warns about unsupported severity" "$output" "unsupported severity"
  assert_file_contains "W21b: applies default 'medium' label" "$L" ",medium"
  assert_file_not_contains "W21b: no junk 'critical' label" "$L" "critical"

  # W21c: a canonical severity passes through unchanged, no warning (regression guard).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"feedback:got","severity":"low","entity":"F-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=89 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_file_contains "W21c: applies 'low' label" "$L" ",low"
  assert_output_not_contains "W21c: no warning for canonical severity" "$output" "unsupported severity"

  local cmd="$PLUGIN_ROOT/commands/monitor-nightly.md"
  # W16: command exists, right frontmatter, calls engine, uses flock, parses config — and NEVER calls gh
  assert_file_exists "W16: command exists" "$cmd"
  assert_file_contains "W16: argument-hint" "$cmd" 'argument-hint'
  assert_file_contains "W16: defines engine path" "$cmd" 'scripts/monitor-dedup.sh'
  assert_file_contains "W16: runs engine commit" "$cmd" '"$ENGINE" commit'
  assert_file_contains "W16: runs engine window" "$cmd" '"$ENGINE" window'
  assert_file_contains "W16: flock" "$cmd" 'flock'
  assert_file_contains "W16: reads .local.md" "$cmd" 'saas-startup-team.local.md'
  # the command must NOT call gh itself (engine owns all gh). Match a gh word-boundary command form.
  assert_file_not_contains "W16: no gh issue calls" "$cmd" 'gh issue'
  assert_file_not_contains "W16: no gh repo calls" "$cmd" 'gh repo'
  assert_file_not_contains "W16: no gh label calls" "$cmd" 'gh label'
  assert_file_not_contains "W16: no gh auth calls" "$cmd" 'gh auth'
  # W16e: the engine is invoked DIRECTLY (executable + shebang), never via `bash "$ENGINE"`,
  # so an injection-sensitive cron can scope --allowedTools to the engine path and drop the
  # full-shell `Bash(bash:*)` grant (#89); a hardened narrow-scope cron is documented.
  assert_file_not_contains "W16e: engine invoked directly, not via bash (#89)" "$cmd" 'bash "$ENGINE"'
  assert_file_contains "W16e: documents hardened narrow tool-scope" "$cmd" "Hardened cron"

  # W17: extracted collect block writes a JSONL finding per marker (sanitized kind) to $STATE_FILE.findings
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  printf '2026-06-21 02:00:00 UTC ocr-api down\nconnection refused\n' > "$workdir/.monitor/ocr-api-last-failure.txt"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W17: collect exits 0" "$ec" 0
  assert_file_contains "W17: pattern key from filename" "$workdir/state.json.findings" '"pattern_key":"ops:ocr-api:failure"'
  assert_json_valid "W17: emits valid JSON" "$workdir/state.json.findings"

  # W17b: messy marker filename → sanitized to a valid pattern_key (dot/space/case → dashes)
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  printf 'boom\n' > "$workdir/.monitor/OCR Api.Bad-last-failure.txt"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_file_contains "W17b: sanitized kind" "$workdir/state.json.findings" '"pattern_key":"ops:ocr-api-bad:failure"'
  assert_equals "W17b: key valid per regex" \
    "$(jq -r '.pattern_key' "$workdir/state.json.findings" | grep -cE '^[a-z0-9][a-z0-9:_-]*$')" "1"

  # W18: no markers, no custom-checks → empty findings file, exit 0
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W18: empty collect exits 0" "$ec" 0
  assert_equals "W18: no findings" "$(tr -d '[:space:]' < "$workdir/state.json.findings")" ""

  # W18b: custom-checks script output is merged into the findings file
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  cat > "$workdir/checks.sh" <<'CC'
#!/usr/bin/env bash
echo '{"pattern_key":"feedback:received","severity":"low","entity":"fb-7","title":"T","body":"B"}'
CC
  chmod +x "$workdir/checks.sh"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/checks.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_file_contains "W18b: custom-checks merged" "$workdir/state.json.findings" '"pattern_key":"feedback:received"'

  # W18c: custom-checks exits non-zero → keeps its emitted findings AND appends a tracking finding; collect still exits 0
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  cat > "$workdir/checks.sh" <<'CC'
#!/usr/bin/env bash
echo '{"pattern_key":"feedback:received","severity":"low","entity":"fb-9","title":"T","body":"B"}'
exit 3
CC
  chmod +x "$workdir/checks.sh"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/checks.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W18c: collect survives failing custom-checks" "$ec" 0
  assert_file_contains "W18c: keeps emitted finding" "$workdir/state.json.findings" '"pattern_key":"feedback:received"'
  assert_file_contains "W18c: appends checks-failure finding" "$workdir/state.json.findings" '"pattern_key":"ops:monitor-checks:failure"'

  # W22: the config parser strips YAML-style inline comments (the shipped example uses them)
  # and converts a literal \n escape to a real newline, instead of silently corrupting the
  # value (broken paths / literal `|`) — issue #87.
  workdir=$(make_workdir); mkdir -p "$workdir/.claude"
  cat > "$workdir/.claude/saas-startup-team.local.md" <<'CFG'
---
monitor:
  repo: owner/name                 # default via gh repo view
  state_file: .data/monitor.json   # keep co-located
  labels: [monitor, customer-issue]   # base labels
  repro_recipe: "curl -s https://api/{entity}\necho done"
---
CFG
  extract_md_bash "$cmd" "## Configuration" > "$workdir/cfg.sh"
  printf '\nprintf "REPO=[%%s]\\nSTATE=[%%s]\\nRECIPE<<%%s>>\\n" "$REPO" "$STATE_FILE" "$REPRO_RECIPE"\n' >> "$workdir/cfg.sh"
  ec=0; output=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/cfg.sh" 2>&1) || ec=$?
  assert_exit_code "W22: config block runs" "$ec" 0
  assert_output_contains "W22: repo inline comment stripped" "$output" "REPO=[owner/name]"
  assert_output_contains "W22: state_file inline comment stripped" "$output" "STATE=[.data/monitor.json]"
  assert_output_contains "W22: repro recipe first line" "$output" "curl -s https://api/{entity}"
  assert_output_contains "W22: repro recipe second line kept" "$output" "echo done"
  assert_output_not_contains "W22: \\n converted to a real newline" "$output" 'api/{entity}\necho'
  rm -rf "$workdir"

  # W22b: a QUOTED value preserves an inner ` #` — inline-comment stripping applies to unquoted
  # values only, so a `#` inside quotes is real content, not a comment (#87; codex review).
  workdir=$(make_workdir); mkdir -p "$workdir/.claude"
  cat > "$workdir/.claude/saas-startup-team.local.md" <<'CFG'
---
monitor:
  repro_recipe: "run probe #42 for {entity}"
---
CFG
  extract_md_bash "$cmd" "## Configuration" > "$workdir/cfg.sh"
  printf '\nprintf "RECIPE=[%%s]\\n" "$REPRO_RECIPE"\n' >> "$workdir/cfg.sh"
  ec=0; output=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/cfg.sh" 2>&1) || ec=$?
  assert_output_contains "W22b: quoted inner # preserved" "$output" "RECIPE=[run probe #42 for {entity}]"
  rm -rf "$workdir"

  # W19: config example, README, and versions are consistent
  assert_file_contains "W19: example has monitor block" "$PLUGIN_ROOT/saas-startup-team.local.md.example" "monitor:"
  assert_file_contains "W19: README documents command" "$PLUGIN_ROOT/README.md" "/monitor-nightly"
  assert_file_contains "W19: README custom-checks contract" "$PLUGIN_ROOT/README.md" "monitor-checks.sh"
  assert_file_contains "W19: README documents repro_recipe" "$PLUGIN_ROOT/README.md" "repro_recipe"
  # the dropped `severities` key must not reappear in either doc
  assert_file_not_contains "W19: no severities in example" "$PLUGIN_ROOT/saas-startup-team.local.md.example" "severities"
  assert_file_not_contains "W19: no severities in README" "$PLUGIN_ROOT/README.md" "severities"
  local pv mv
  pv="$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  mv="$(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' "$PLUGIN_ROOT/../../.claude-plugin/marketplace.json")"
  assert_equals "W19: plugin/marketplace versions match" "$pv" "$mv"
}

# ---------------------------------------------------------------------------
# Suite Y: Operate phase, workflow registry, and triggered SaaS gates
# ---------------------------------------------------------------------------

test_operate_workflow_registry_and_gates() {
  echo -e "\n${CYAN}Suite Y: Operate/workflow/gate guidance${NC}"

  # Public command surface.
  assert_file_exists "Y1: /operate command exists" "$PLUGIN_ROOT/commands/operate.md"
  assert_file_exists "Y2: /monitor command exists" "$PLUGIN_ROOT/commands/monitor.md"
  assert_file_exists "Y3: /investigate command exists" "$PLUGIN_ROOT/commands/investigate.md"
  assert_file_exists "Y4: /replay-abandoned command exists" "$PLUGIN_ROOT/commands/replay-abandoned.md"
  assert_file_contains "Y5: /operate uses operate block" "$PLUGIN_ROOT/commands/operate.md" "operate:"
  assert_file_contains "Y6: /operate rejects operate.yml" "$PLUGIN_ROOT/commands/operate.md" ".startup/operate.yml"
  assert_file_contains "Y7: /monitor reuses monitor engine" "$PLUGIN_ROOT/commands/monitor.md" "scripts/monitor-dedup.sh"
  assert_file_contains "Y8: /investigate files dedup issue" "$PLUGIN_ROOT/commands/investigate.md" "deduplicated GitHub issue"
  assert_file_contains "Y9: /replay emits finding schema" "$PLUGIN_ROOT/commands/replay-abandoned.md" "finding.json"

  # Agent surface.
  assert_file_exists "Y10: incident-investigator agent exists" "$PLUGIN_ROOT/agents/incident-investigator.md"
  assert_file_exists "Y11: session-replay agent exists" "$PLUGIN_ROOT/agents/session-replay.md"
  assert_file_exists "Y12: support-triage agent exists" "$PLUGIN_ROOT/agents/support-triage.md"
  assert_file_contains "Y13: support agent config-driven" "$PLUGIN_ROOT/agents/support-triage.md" "operate:"

  # Workflow registry.
  assert_file_exists "Y14: workflow registry template exists" "$PLUGIN_ROOT/templates/workflow-registry.md"
  assert_file_exists "Y15: workflow spec template exists" "$PLUGIN_ROOT/templates/workflow-spec.md"
  assert_file_contains "Y16: bootstrap creates workflow registry" "$PLUGIN_ROOT/commands/bootstrap.md" ".startup/workflows/registry.md"
  assert_file_contains "Y17: startup references the workflow registry (bootstrap scaffolds it)" "$PLUGIN_ROOT/commands/startup.md" ".startup/workflows/"
  assert_file_contains "Y18: improve reads workflow registry" "$PLUGIN_ROOT/references/workflows/improve.md" ".startup/workflows/registry.md"
  assert_file_contains "Y19: orchestration validates workflow specs" "$PLUGIN_ROOT/skills/startup-orchestration/SKILL.md" "WORKFLOW-<slug>.md"

  # Config and README.
  assert_file_contains "Y20: example has operate block" "$PLUGIN_ROOT/saas-startup-team.local.md.example" "operate:"
  assert_file_contains "Y21: README documents operate phase" "$PLUGIN_ROOT/README.md" "Operate phase"
  assert_file_contains "Y22: README documents workflow registry" "$PLUGIN_ROOT/README.md" "Workflow registry"

  # Triggered SaaS gates across roles/templates.
  assert_file_contains "Y23: business founder async paid-flow gate" "$PLUGIN_ROOT/agents/business-founder.md" "Async paid-flow UX gate"
  assert_file_contains "Y24: business founder customer value unit" "$PLUGIN_ROOT/agents/business-founder.md" "customer value unit"
  assert_file_contains "Y25: tech founder display-label registry" "$PLUGIN_ROOT/agents/tech-founder-claude.md" "Display-label registry"
  assert_file_contains "Y26: tech founder LLM gate" "$PLUGIN_ROOT/agents/tech-founder-claude.md" "LLM pipeline quality gate"
  assert_file_contains "Y27: UX tester raw-value scan" "$PLUGIN_ROOT/agents/ux-tester.md" "Structured-result raw-value scan"
  assert_file_contains "Y28: lawyer claim taxonomy" "$PLUGIN_ROOT/agents/lawyer.md" "Compliance/Risk Product Claim Taxonomy"
  assert_file_contains "Y29: handoff template triggered gates" "$PLUGIN_ROOT/templates/handoff-business-to-tech.md" "Triggered gates"
  assert_file_contains "Y30: tech handoff template gate evidence" "$PLUGIN_ROOT/templates/handoff-tech-to-business.md" "Triggered Gate Evidence"
  assert_file_contains "Y31: solution signoff CI/CD readiness" "$PLUGIN_ROOT/templates/solution-signoff.md" "CI/CD Readiness"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Suite Z: session-insights.sh (local-only intervention extractor)
# ---------------------------------------------------------------------------

test_session_insights() {
  echo -e "\n${CYAN}Suite Z: session-insights.sh (local intervention extractor)${NC}"
  local script="$PLUGIN_ROOT/scripts/session-insights.sh"
  local workdir logs state out report ec output

  _si_run() { # logs state out report -> sets ec/output
    ec=0
    output=$(bash "$script" --logs-dir "$1" --state "$2" --out "$3" --report "$4" 2>&1) || ec=$?
  }
  _si_count() { grep -c "\"signal_type\":\"$2\"" "$1" 2>/dev/null || true; }
  _si_total() { grep -c '"signal_type"' "$1" 2>/dev/null || true; }

  # --- Z1: interrupt detection, ignores plain prompts + assistant lines ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/.startup/insights/watermark.json"
  out="$workdir/.startup/insights/records.jsonl"
  report="$workdir/.startup/insights/report.md"
  cat > "$logs/S1.jsonl" <<'JSONL'
{"type":"user","sessionId":"S1","timestamp":"2026-06-20T10:00:00Z","message":{"role":"user","content":"Build the invoice export"}}
{"type":"assistant","sessionId":"S1","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}
{"type":"user","sessionId":"S1","timestamp":"2026-06-20T10:01:00Z","message":{"role":"user","content":"[Request interrupted by user]"}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_exit_code "Z1: scan exits 0" "$ec" 0
  assert_file_exists "Z1: records file created" "$out"
  assert_equals "Z1: one interrupt record" "$(_si_count "$out" interrupt)" "1"
  assert_equals "Z1: no false positives (total=1)" "$(_si_total "$out")" "1"
  assert_file_exists "Z1: report created" "$report"
  rm -rf "$workdir"

  # --- Z2: /nudge detection ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S2.jsonl" <<'JSONL'
{"type":"user","sessionId":"S2","message":{"role":"user","content":"/nudge tech-founder is stuck on the payment form"}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z2: one nudge record" "$(_si_count "$out" nudge)" "1"
  rm -rf "$workdir"

  # --- Z3: correction vocabulary ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S3.jsonl" <<'JSONL'
{"type":"user","sessionId":"S3","message":{"role":"user","content":"No, that's wrong. Use the existing helper instead."}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z3: one correction record" "$(_si_count "$out" correction)" "1"
  rm -rf "$workdir"

  # --- Z4: tool_result-only user line is NOT a false intervention ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S4.jsonl" <<'JSONL'
{"type":"user","sessionId":"S4","message":{"role":"user","content":[{"type":"tool_result","content":"ok done"}]}}
{"type":"assistant","sessionId":"S4","message":{"role":"assistant","content":[{"type":"text","text":"finished"}]}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_exit_code "Z4: scan exits 0" "$ec" 0
  assert_equals "Z4: zero records (no false positive)" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z5: malformed line skipped, valid signal still found, exit 0 ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S5.jsonl" <<'JSONL'
this is not valid json {{{
{"type":"user","sessionId":"S5","message":{"role":"user","content":"[Request interrupted by user]"}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_exit_code "Z5: tolerates malformed line" "$ec" 0
  assert_equals "Z5: still finds interrupt" "$(_si_count "$out" interrupt)" "1"
  rm -rf "$workdir"

  # --- Z6: watermark — second run with no new content adds nothing ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S6.jsonl" <<'JSONL'
{"type":"user","sessionId":"S6","message":{"role":"user","content":"[Request interrupted by user]"}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z6: first run finds 1" "$(_si_total "$out")" "1"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z6: second run adds nothing (still 1)" "$(_si_total "$out")" "1"
  rm -rf "$workdir"

  # --- Z7: watermark — appended complete line is picked up once ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"S7","message":{"role":"user","content":"[Request interrupted by user]"}}' > "$logs/S7.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z7: first run finds 1" "$(_si_total "$out")" "1"
  printf '%s\n' '{"type":"user","sessionId":"S7","message":{"role":"user","content":"/nudge try again"}}' >> "$logs/S7.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z7: append adds exactly 1 (total 2)" "$(_si_total "$out")" "2"
  rm -rf "$workdir"

  # --- Z8: emitted records are valid JSON with required fields ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S8.jsonl" <<'JSONL'
{"type":"user","sessionId":"S8-abc","message":{"role":"user","content":"[Request interrupted by user]"}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  ec=0; jq -e . "$out" >/dev/null 2>&1 || ec=$?
  assert_exit_code "Z8: records are valid JSON" "$ec" 0
  assert_equals "Z8: signal_type present" "$(jq -r '.signal_type' "$out" 2>/dev/null | head -1)" "interrupt"
  assert_equals "Z8: session_id captured" "$(jq -r '.session_id' "$out" 2>/dev/null | head -1)" "S8-abc"
  assert_equals "Z8: confidence captured" "$(jq -r '.confidence' "$out" 2>/dev/null | head -1)" "high"
  rm -rf "$workdir"

  # --- Z9: structural tool_failure (is_error true) ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/S9.jsonl" <<'JSONL'
{"type":"user","sessionId":"S9","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"command failed: exit 2"}]}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z9: one tool_failure record" "$(_si_count "$out" tool_failure)" "1"
  rm -rf "$workdir"

  # --- Z10: no network calls in the script (static safety) ---
  assert_file_not_contains "Z10: no gh in script" "$script" "gh "
  assert_file_not_contains "Z10: no curl in script" "$script" "curl"

  # --- Z11: partial (unterminated) line is not processed until completed ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SB","message":{"role":"user","content":"[Request interrupted by user]"}}' > "$logs/SB.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z11: first run 1" "$(_si_total "$out")" "1"
  printf '%s' '{"type":"user","sessionId":"SB","message":{"role":"user","content":"/nudge incomplete' >> "$logs/SB.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z11: partial line not processed (still 1)" "$(_si_total "$out")" "1"
  printf '%s\n' '"}}' >> "$logs/SB.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z11: completed line processed once (total 2)" "$(_si_total "$out")" "2"
  rm -rf "$workdir"

  # --- Z12: interrupt marker inside ARRAY text block (real-log shape) ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/SC.jsonl" <<'JSONL'
{"type":"user","sessionId":"SC","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z12: interrupt in array text detected" "$(_si_count "$out" interrupt)" "1"
  rm -rf "$workdir"

  # --- Z13: <local-command-caveat> wrapper is NOT an investor correction ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SD","message":{"role":"user","content":"<local-command-caveat>Caveat: messages below were generated by the user. DO NOT respond to these unless asked.</local-command-caveat>"}}' > "$logs/SD.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z13: command-output wrapper not a correction" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z14: long pasted content with a late cue is NOT a correction ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  long="$(printf 'x%.0s' {1..700}) and we should do it instead"
  printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"SE\",\"message\":{\"role\":\"user\",\"content\":\"$long\"}}" > "$logs/SE.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z14: long pasted content not a correction" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z15: a command-doc body mentioning /nudge is NOT a nudge invocation ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SF","message":{"role":"user","content":"# /improve command — execute one cycle; if a founder is stuck, use /nudge to redirect."}}' > "$logs/SF.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z15: /nudge mentioned mid-doc is not a nudge" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z16: budget defers whole files (no data loss across runs) ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"A","message":{"role":"user","content":"[Request interrupted by user]"}}' > "$logs/A.jsonl"
  printf '%s\n' '{"type":"user","sessionId":"B","message":{"role":"user","content":"[Request interrupted by user]"}}' > "$logs/B.jsonl"
  ec=0; bash "$script" --logs-dir "$logs" --state "$state" --out "$out" --report "$report" --max-records 1 2>&1 || ec=$?
  assert_exit_code "Z16: capped run exits 0" "$ec" 0
  assert_equals "Z16: first run captures 1 (one file deferred)" "$(_si_total "$out")" "1"
  bash "$script" --logs-dir "$logs" --state "$state" --out "$out" --report "$report" --max-records 1 >/dev/null 2>&1
  assert_equals "Z16: deferred file picked up next run (total 2, no loss)" "$(_si_total "$out")" "2"
  rm -rf "$workdir"

  # --- Z17: a mid-sentence correction word is NOT a correction (anchored) ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SG","message":{"role":"user","content":"Please use the shared helper instead of the old one."}}' > "$logs/SG.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z17: mid-sentence cue is not a correction" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z18: missing logs dir is tolerated (exit 0, empty, report written) ---
  workdir=$(make_workdir)
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  _si_run "$workdir/does-not-exist" "$state" "$out" "$report"
  assert_exit_code "Z18: missing logs dir exits 0" "$ec" 0
  assert_equals "Z18: zero records" "$(_si_total "$out")" "0"
  assert_file_exists "Z18: report still written" "$report"
  rm -rf "$workdir"

  # --- Z19: corrupt watermark is treated as fresh (exit 0, still scans) ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf 'not json {{{' > "$state"
  printf '%s\n' '{"type":"user","sessionId":"SH","message":{"role":"user","content":"[Request interrupted by user]"}}' > "$logs/SH.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_exit_code "Z19: corrupt watermark tolerated" "$ec" 0
  assert_equals "Z19: still finds interrupt" "$(_si_count "$out" interrupt)" "1"
  rm -rf "$workdir"

  # --- Z20: interrupt across multiple array text blocks ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/SI.jsonl" <<'JSONL'
{"type":"user","sessionId":"SI","message":{"role":"user","content":[{"type":"text","text":"hello there"},{"type":"text","text":"[Request interrupted by user]"}]}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z20: interrupt across joined text blocks" "$(_si_count "$out" interrupt)" "1"
  rm -rf "$workdir"

  # --- Z21: a Stop-hook feedback turn is NOT an investor correction ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SJ","message":{"role":"user","content":"Stop hook feedback: [all issues merged]: only #1017 remains"}}' > "$logs/SJ.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z21: Stop-hook feedback is not a correction" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z22: a <system-reminder> turn is NOT an investor correction ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SK","message":{"role":"user","content":"<system-reminder>Do not respond to this context.</system-reminder>"}}' > "$logs/SK.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z22: system-reminder is not a correction" "$(_si_total "$out")" "0"
  rm -rf "$workdir"

  # --- Z23: tool_failure carries the specific error text, not a constant ---
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  cat > "$logs/SL.jsonl" <<'JSONL'
{"type":"user","sessionId":"SL","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"ENOSPC: no space left on device"}]}}
JSONL
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z23: one tool_failure" "$(_si_count "$out" tool_failure)" "1"
  assert_file_contains "Z23: summary carries the real error text" "$out" "ENOSPC: no space left on device"
  rm -rf "$workdir"

  # --- Z24: a hook-injected turn carrying an error tool_result is still excluded ---
  # (noise exclusion must run BEFORE the tool_failure branch, else it re-admits noise)
  workdir=$(make_workdir); logs="$workdir/logs"; mkdir -p "$logs"
  state="$workdir/wm.json"; out="$workdir/rec.jsonl"; report="$workdir/rep.md"
  printf '%s\n' '{"type":"user","sessionId":"SM","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback: tighten the gate"},{"type":"tool_result","is_error":true,"content":"boom"}]}}' > "$logs/SM.jsonl"
  _si_run "$logs" "$state" "$out" "$report"
  assert_equals "Z24: hook turn with error tool_result excluded" "$(_si_total "$out")" "0"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite H: harvest.sh (dry-run candidate generator — no network, no filing)
# ---------------------------------------------------------------------------

test_harvest() {
  echo -e "\n${CYAN}Suite H: harvest.sh (dry-run candidate generator)${NC}"
  local hscript="$PLUGIN_ROOT/scripts/harvest.sh"
  local workdir in led cand report ec output

  _h_run() { # in ledger cand report [project]
    ec=0
    output=$(bash "$hscript" --in "$1" --ledger "$2" --candidates "$3" --report "$4" --project "${5:-acme}" 2>&1) || ec=$?
  }
  _h_total() { grep -c '"fingerprint"' "$1" 2>/dev/null || true; }
  _rec() { # signal summary ref -> one record JSON line
    jq -cn --arg s "$1" --arg sum "$2" --arg ref "$3" \
      '{signal_type:$s, sanitized_summary:$sum, local_evidence_ref:$ref, confidence:"medium", source_project:"acme"}'
  }

  # --- H1: identical signals cluster into one candidate with aggregated count ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { _rec correction "the checkout total is computed wrong" "/f#L1"; _rec correction "the checkout total is computed wrong" "/f#L2"; _rec correction "the checkout total is computed wrong" "/f#L3"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_exit_code "HV1: exits 0" "$ec" 0
  assert_equals "HV1: one cluster" "$(_h_total "$cand")" "1"
  assert_equals "HV1: count aggregated to 3" "$(jq -r '.count' "$cand" | head -1)" "3"
  rm -rf "$workdir"

  # --- H2: de-identify replaces the project name with a template var ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { _rec correction "acme dashboard layout is wrong" "/f#L1"; _rec correction "acme dashboard layout is wrong" "/f#L2"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report" "acme"
  assert_equals "HV2: correction surfaced (count>=2)" "$(_h_total "$cand")" "1"
  assert_file_contains "HV2: project name templated" "$cand" "{{PROJECT}}"
  assert_file_not_contains "HV2: raw project name removed" "$cand" "acme dashboard"
  rm -rf "$workdir"

  # --- H3: PII/secret in a candidate blocks it from surfacing ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  local sec="sk-""or-v1-""deadbeefdeadbeefdeadbeef"   # fragmented so the repo holds no real-looking secret
  _rec nudge "use key $sec now" "/f#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV3: secret-bearing candidate not surfaced" "$(_h_total "$cand")" "0"
  assert_file_contains "HV3: report notes a blocked candidate" "$report" "blocked"
  rm -rf "$workdir"

  # --- H4: dedup against the ledger (already-surfaced fingerprint) ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _rec interrupt "[Request interrupted by user] stop — wrong migration order" "/f#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV4: first run surfaces it" "$(_h_total "$cand")" "1"
  local fp; fp="$(jq -r '.fingerprint' "$cand" | head -1)"
  jq -n --arg fp "$fp" '{($fp): {}}' > "$led"
  _h_run "$in" "$led" "$workdir/cand2.jsonl" "$report"
  assert_equals "HV4: deduped on second run" "$(_h_total "$workdir/cand2.jsonl")" "0"
  rm -rf "$workdir"

  # --- H5: recurrence threshold (a lone low-confidence signal stays below the bar) ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _rec correction "the totals page is off by one" "/f#L1" > "$in"   # count 1 < correction threshold 2
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV5: single correction below threshold" "$(_h_total "$cand")" "0"
  _rec interrupt "[Request interrupted by user] stop — wrong branch" "/f#L1" > "$in"  # count 1 >= default 1
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV5: single interrupt meets threshold" "$(_h_total "$cand")" "1"
  rm -rf "$workdir"

  # --- H6: candidates are valid JSON; report is written ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _rec interrupt "[Request interrupted by user] stop — wrong migration order" "/f#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  ec=0; jq -e . "$cand" >/dev/null 2>&1 || ec=$?
  assert_exit_code "HV6: candidates valid JSON" "$ec" 0
  assert_file_exists "HV6: report written" "$report"
  rm -rf "$workdir"

  # --- H7: malformed record line tolerated ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { printf 'garbage {{{\n'; _rec interrupt "[Request interrupted by user] stop — wrong migration order" "/f#L2"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_exit_code "HV7: tolerates malformed line" "$ec" 0
  assert_equals "HV7: still surfaces the valid signal" "$(_h_total "$cand")" "1"
  rm -rf "$workdir"

  # --- H8: no network in the script ---
  assert_file_not_contains "HV8: no gh in script" "$hscript" "gh "
  assert_file_not_contains "HV8: no curl in script" "$hscript" "curl"

  # --- H9: empty/missing records tolerated ---
  workdir=$(make_workdir); led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _h_run "$workdir/missing.jsonl" "$led" "$cand" "$report"
  assert_exit_code "HV9: missing input exits 0" "$ec" 0
  assert_equals "HV9: zero candidates" "$(_h_total "$cand")" "0"
  assert_file_exists "HV9: report still written" "$report"
  rm -rf "$workdir"

  # --- HV10: a secret in the evidence_ref (not just the summary) blocks the cluster ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  local akia="AKIA""1234567890ABCD"   # fragmented (no contiguous secret in source)
  _rec interrupt "[Request interrupted by user]" "/logs/${akia}.jsonl#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV10: ref-borne secret blocks the cluster" "$(_h_total "$cand")" "0"
  rm -rf "$workdir"

  # --- HV11: broader token formats are all caught by the PII gate ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  # fragmented so the committed bytes contain no contiguous secret; runtime rebuilds the full string
  local t_ant="sk-""ant-""deadbeefdeadbeefdeadbeef0001"
  local t_strp="sk""_live_""deadbeefdeadbeef0002abcd"
  local t_goog="AIza""SyDeadbeefdeadbeefdeadbeefdeadbeef00"
  local t_jwt="eyJabcdefgh.""eyJpayloadxx.""sigsig0001"
  local t_gen="API""_KEY=""supersecretvalue123"
  {
    _rec interrupt "leak $t_ant here" "/f#L1"
    _rec interrupt "leak $t_strp here" "/f#L2"
    _rec interrupt "leak $t_goog here" "/f#L3"
    _rec interrupt "leak $t_jwt here" "/f#L4"
    _rec interrupt "leak $t_gen here" "/f#L5"
  } > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV11: all token formats blocked (0 surfaced)" "$(_h_total "$cand")" "0"
  assert_file_contains "HV11: report counts 5 blocked" "$report" "blocked (PII/secret detected): 5"
  rm -rf "$workdir"

  # --- HV12: refs with spaces/glob chars do not corrupt output (no word-split/glob) ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _rec interrupt "[Request interrupted by user] stop — wrong migration order" "/tmp/a b*.jsonl#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  ec=0; jq -e . "$cand" >/dev/null 2>&1 || ec=$?
  assert_exit_code "HV12: candidates still valid JSON" "$ec" 0
  assert_equals "HV12: exactly one evidence ref (no split/glob)" "$(jq -r '.evidence_refs | length' "$cand" | head -1)" "1"
  rm -rf "$workdir"

  # --- HV13: project name with regex metacharacters is de-identified ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { _rec correction "acme.app checkout is broken in acme.app" "/f#L1"; _rec correction "acme.app checkout is broken in acme.app" "/f#L2"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report" "acme.app"
  assert_file_contains "HV13: metachar project templated" "$cand" "{{PROJECT}}"
  assert_file_not_contains "HV13: raw metachar project removed" "$cand" "acme.app"
  rm -rf "$workdir"

  # --- HV14: candidate output order is deterministic across runs ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  { _rec interrupt "[Request interrupted by user] stop — wrong migration order" "/f#L1"
    _rec correction "the invoice rounding is wrong" "/f#L2"; _rec correction "the invoice rounding is wrong" "/f#L3"; } > "$in"
  _h_run "$in" "$led" "$workdir/c1.jsonl" "$report"
  _h_run "$in" "$led" "$workdir/c2.jsonl" "$report"
  local dord="same"; diff -q "$workdir/c1.jsonl" "$workdir/c2.jsonl" >/dev/null 2>&1 || dord="diff"
  assert_equals "HV14: deterministic candidate ordering" "$dord" "same"
  rm -rf "$workdir"

  # --- HV15: a bare interrupt marker is low-signal and does NOT surface ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _rec interrupt "[Request interrupted by user]" "/f#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV15: bare interrupt dropped as low-signal" "$(_h_total "$cand")" "0"
  assert_file_contains "HV15: report counts the low-signal drop" "$report" "low-signal (no actionable content): 1"
  rm -rf "$workdir"

  # --- HV16: a recurring tool_failure (even with real error text) is never filed ---
  # tool_failure is agent/environment friction, not a generic plugin lesson.
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { _rec tool_failure "eslint failed: rule no-undef" "/f#L1"; _rec tool_failure "eslint failed: rule no-undef" "/f#L2"; _rec tool_failure "eslint failed: rule no-undef" "/f#L3"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV16: tool_failure not filed (non-intervention)" "$(_h_total "$cand")" "0"
  assert_file_contains "HV16: report counts the non-intervention skip" "$report" "non-intervention signal): 1"
  rm -rf "$workdir"

  # --- HV17: project-specific issue numbers are de-identified ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { _rec correction "the /goal-deliver #864 flow only handled #1017" "/f#L1"; _rec correction "the /goal-deliver #864 flow only handled #1017" "/f#L2"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV17: surfaced" "$(_h_total "$cand")" "1"
  assert_file_contains "HV17: issue numbers templated to #N" "$cand" "#N"
  assert_file_not_contains "HV17: raw issue number removed" "$cand" "#864"
  rm -rf "$workdir"

  # --- HV18: evidence_refs are capped (a high-count cluster doesn't dump all refs) ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  : > "$in"; for i in $(seq 1 25); do _rec correction "the checkout flow validation is wrong" "/f#L$i" >> "$in"; done
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV18: one cluster" "$(_h_total "$cand")" "1"
  assert_equals "HV18: evidence_refs capped at 10" "$(jq -r '.evidence_refs | length' "$cand" | head -1)" "10"
  assert_equals "HV18: occurrence count still full (25)" "$(jq -r '.count' "$cand" | head -1)" "25"
  rm -rf "$workdir"

  # --- HV19: a substantive interrupt (marker + real text) still surfaces ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  _rec interrupt "[Request interrupted by user] stop — do not deploy without migrations" "/f#L1" > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV19: substantive interrupt surfaces" "$(_h_total "$cand")" "1"
  rm -rf "$workdir"

  # --- HV20: a terse but real lesson is NOT dropped by the low-signal floor ---
  workdir=$(make_workdir); in="$workdir/rec.jsonl"; led="$workdir/led.json"; cand="$workdir/cand.jsonl"; report="$workdir/rep.md"
  { _rec correction "use pnpm" "/f#L1"; _rec correction "use pnpm" "/f#L2"; } > "$in"
  _h_run "$in" "$led" "$cand" "$report"
  assert_equals "HV20: terse real lesson surfaces (not low-signal)" "$(_h_total "$cand")" "1"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite F: lesson-file.sh (gated public filing of harvested candidates)
# ---------------------------------------------------------------------------

test_lesson_file() {
  echo -e "\n${CYAN}Suite F: lesson-file.sh (gated public filing)${NC}"
  local script="$PLUGIN_ROOT/scripts/lesson-file.sh"
  local workdir cand led report L ec output

  _cand() { # fingerprint signal observation [domain]
    jq -cn --arg fp "$1" --arg s "$2" --arg o "$3" --arg d "${4:-process}" \
      '{fingerprint:$fp, signal_type:$s, confidence:"high", domain:$d, observation:$o,
        recommendation:"When X happens, the plugin should do Y.", evidence_refs:["sess.jsonl#L1"], count:2}'
  }
  _creates() { grep -c 'issue create' "$1" 2>/dev/null || true; }

  # --- F1: dry-run by default (enable flag absent) — never calls gh issue create ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp1 interrupt "investor interrupted repeatedly during payment work" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=900 \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_exit_code "F1: dry-run exits 0" "$ec" 0
  assert_equals "F1: no gh issue create when not enabled" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F2: enabled + pinned repo -> files one issue, records the fingerprint ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp1 interrupt "investor interrupted repeatedly during payment work" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=901 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_exit_code "F2: enabled run exits 0" "$ec" 0
  assert_equals "F2: exactly one issue created" "$(_creates "$L")" "1"
  assert_file_contains "F2: filed to the pinned repo" "$L" "paat/claude-plugins"
  assert_file_contains "F2: labeled lesson-candidate" "$L" "lesson-candidate"
  ec=0; jq -e '.["fp1"]' "$led" >/dev/null 2>&1 || ec=$?
  assert_exit_code "F2: ledger records the fingerprint" "$ec" 0
  rm -rf "$workdir"

  # --- F3: refuses to file without a pinned repo (even when enabled) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp1 interrupt "obs" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --report "$report" 2>&1) || ec=$?
  assert_exit_code "F3: refuses without repo (exit 2)" "$ec" 2
  assert_equals "F3: no gh create without repo" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F4: idempotent — a fingerprint already in the ledger is not re-filed ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp1 interrupt "obs" process > "$cand"
  jq -n '{"fp1":{"issue":"https://github.com/paat/claude-plugins/issues/1"}}' > "$led"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=902 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_equals "F4: already-filed fingerprint not re-filed" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F5: PII re-gate at the filing boundary blocks a secret-bearing candidate ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  local sec="AKIA""1234567890ABCD"
  _cand fp5 interrupt "leak $sec in the summary" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=903 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_equals "F5: secret-bearing candidate not filed" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F6: budget caps the number filed per run ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  { _cand a interrupt "obs a" process; _cand b correction "obs b" process; _cand c nudge "obs c" process; } > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=910 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" --max-issues 2 2>&1) || ec=$?
  assert_equals "F6: max-issues caps creation at 2" "$(_creates "$L")" "2"
  rm -rf "$workdir"

  # --- F7: advisory dedup — an existing matching issue suppresses creation ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp7 interrupt "obs" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=911 GH_SEARCH_JSON='[{"number":5,"title":"existing"}]' SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_equals "F7: existing issue suppresses create" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F8: malformed candidate line tolerated ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  { printf 'garbage {{{\n'; _cand fp8 interrupt "obs" process; } > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=912 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_exit_code "F8: tolerates malformed line" "$ec" 0
  assert_equals "F8: still files the valid candidate" "$(_creates "$L")" "1"
  rm -rf "$workdir"

  # --- F9: enable flag must be exactly 'true' (a truthy-looking value stays dry-run) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp9 interrupt "obs" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=913 SAAS_LESSON_SYNC_ENABLED=1 \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_equals "F9: non-'true' flag stays dry-run" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F10: fatal (no filing) when the shared PII gate can't be sourced ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  cp "$script" "$workdir/lf.sh"   # copied WITHOUT pii-gate.sh alongside it
  _cand fp interrupt "obs" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=921 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$workdir/lf.sh" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_exit_code "F10: fatal when PII gate not sourceable" "$ec" 2
  assert_equals "F10: nothing filed without the PII gate" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F11: invalid --max-issues is refused (must not disable the budget) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp interrupt "obs" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=922 SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" --max-issues abc 2>&1) || ec=$?
  assert_exit_code "F11: invalid --max-issues refused (exit 2)" "$ec" 2
  assert_equals "F11: no create on invalid budget" "$(_creates "$L")" "0"
  rm -rf "$workdir"

  # --- F12: a dedup-search failure fails CLOSED (no create) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  cand="$workdir/cand.jsonl"; led="$workdir/led.json"; report="$workdir/rep.md"
  _cand fp interrupt "obs" process > "$cand"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=923 GH_FAIL_ON="issue list" SAAS_LESSON_SYNC_ENABLED=true \
    bash "$script" --candidates "$cand" --ledger "$led" --repo paat/claude-plugins --report "$report" 2>&1) || ec=$?
  assert_equals "F12: search failure does not create (fail-closed)" "$(_creates "$L")" "0"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite R: lesson-review.sh (the single human gate — list / approve / close)
# ---------------------------------------------------------------------------

test_lesson_review() {
  echo -e "\n${CYAN}Suite R: lesson-review.sh (human gate)${NC}"
  local script="$PLUGIN_ROOT/scripts/lesson-review.sh"
  local workdir L ec output cnt
  local REPO="paat/claude-plugins"
  local CAND_OPEN='{"state":"OPEN","labels":[{"name":"lesson-candidate"},{"name":"tooling"}]}'
  local APPROVED_OPEN='{"state":"OPEN","labels":[{"name":"lesson-approved"}]}'
  local CLOSED_CAND='{"state":"CLOSED","labels":[{"name":"lesson-candidate"}]}'
  local NONLESSON_OPEN='{"state":"OPEN","labels":[{"name":"bug"}]}'
  local ONE='[{"number":5,"title":"lesson: recurring tool_failure","labels":[{"name":"lesson-candidate"},{"name":"tooling"}],"url":"https://github.com/paat/claude-plugins/issues/5","body":"## Observation\nstuff"}]'
  _edits() { grep -c 'issue edit' "$1" 2>/dev/null || true; }
  _closes() { grep -c 'issue close' "$1" 2>/dev/null || true; }

  # --- R1: --list shows the candidate queue, querying the candidate label ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_LIST_JSON="$ONE" SAAS_PLUGIN_REPO='' \
    bash "$script" --list --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R1: list exits 0" "$ec" 0
  assert_output_contains "R1: lists candidate #5" "$output" "#5"
  assert_file_contains "R1: queries lesson-candidate label" "$L" "--label lesson-candidate"
  rm -rf "$workdir"

  # --- R2: --list without a pinned repo refuses (exit 2) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_PLUGIN_REPO='' \
    bash "$script" --list 2>&1) || ec=$?
  assert_exit_code "R2: list without repo exits 2" "$ec" 2
  rm -rf "$workdir"

  # --- R2b: a malformed repo pin is refused (exit 2) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_PLUGIN_REPO='' \
    bash "$script" --list --repo notaslash 2>&1) || ec=$?
  assert_exit_code "R2b: malformed repo refused (exit 2)" "$ec" 2
  rm -rf "$workdir"

  # --- R3: --approve does a single atomic candidate->approved relabel ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$CAND_OPEN" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R3: approve exits 0" "$ec" 0
  assert_file_contains "R3: adds lesson-approved" "$L" "add-label lesson-approved"
  assert_file_contains "R3: removes lesson-candidate" "$L" "remove-label lesson-candidate"
  assert_equals "R3: exactly one edit call" "$(_edits "$L")" "1"
  rm -rf "$workdir"

  # --- R4: approve refuses an issue that is not a candidate (label guard) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$NONLESSON_OPEN" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 7 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R4: refuse non-candidate (non-zero)" "$ec" 1
  assert_equals "R4: no edit on refusal" "$(_edits "$L")" "0"
  rm -rf "$workdir"

  # --- R5: approve without a pinned repo refuses (exit 2) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 2>&1) || ec=$?
  assert_exit_code "R5: approve without repo exits 2" "$ec" 2
  rm -rf "$workdir"

  # --- R6: approve with a non-integer issue number refuses (exit 2) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve abc --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R6: non-integer issue refused (exit 2)" "$ec" 2
  rm -rf "$workdir"

  # --- R7: --close rejects a candidate as not planned ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$CAND_OPEN" SAAS_PLUGIN_REPO='' \
    bash "$script" --close 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R7: close exits 0" "$ec" 0
  assert_file_contains "R7: closes the issue" "$L" "issue close 5"
  assert_file_contains "R7: closes as not planned" "$L" "not planned"
  rm -rf "$workdir"

  # --- R8: a relabel failure fails CLOSED (non-zero, no false success) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$CAND_OPEN" GH_FAIL_ON="issue edit" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R8: relabel failure is non-zero" "$ec" 1
  rm -rf "$workdir"

  # --- R9: approving an already-approved issue is an idempotent no-op ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$APPROVED_OPEN" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R9: idempotent approve exits 0" "$ec" 0
  assert_equals "R9: no edit on idempotent approve" "$(_edits "$L")" "0"
  rm -rf "$workdir"

  # --- R10: cannot-inspect (issue view fails) fails CLOSED, no mutation ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue view" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R10: view failure is non-zero" "$ec" 1
  assert_equals "R10: no edit when cannot inspect" "$(_edits "$L")" "0"
  rm -rf "$workdir"

  # --- R11: approving a CLOSED candidate is refused (reopen first) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$CLOSED_CAND" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R11: refuse approve on closed (non-zero)" "$ec" 1
  assert_equals "R11: no edit on closed" "$(_edits "$L")" "0"
  rm -rf "$workdir"

  # --- R12: closing an already-closed issue is an idempotent no-op ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$CLOSED_CAND" SAAS_PLUGIN_REPO='' \
    bash "$script" --close 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R12: idempotent close exits 0" "$ec" 0
  assert_equals "R12: no close call when already closed" "$(_closes "$L")" "0"
  rm -rf "$workdir"

  # --- R13: an empty queue lists cleanly (exit 0, not an error) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_LIST_JSON='[]' SAAS_PLUGIN_REPO='' \
    bash "$script" --list --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R13: empty queue exits 0" "$ec" 0
  assert_output_contains "R13: reports empty queue" "$output" "No lesson candidates"
  rm -rf "$workdir"

  # --- R14: a list failure (cannot determine the queue) is non-zero ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue list" SAAS_PLUGIN_REPO='' \
    bash "$script" --list --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R14: list gh failure is non-zero" "$ec" 1
  rm -rf "$workdir"

  # --- R15: --list --json passes structured data through for the command ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_LIST_JSON="$ONE" SAAS_PLUGIN_REPO='' \
    bash "$script" --list --json --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R15: json list exits 0" "$ec" 0
  cnt="$(printf '%s' "$output" | jq 'length' 2>/dev/null || echo bad)"
  assert_equals "R15: json passthrough is parseable array" "$cnt" "1"
  rm -rf "$workdir"

  # --- R16: closing a non-lesson issue is refused (is-a-lesson guard) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$NONLESSON_OPEN" SAAS_PLUGIN_REPO='' \
    bash "$script" --close 9 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R16: refuse close non-lesson (non-zero)" "$ec" 1
  assert_equals "R16: no close call on refusal" "$(_closes "$L")" "0"
  rm -rf "$workdir"

  # --- R17: --note on approve posts an annotation comment ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON="$CAND_OPEN" SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --note "clearly generic" --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R17: approve with note exits 0" "$ec" 0
  assert_file_contains "R17: posts the note as a comment" "$L" "issue comment 5"
  rm -rf "$workdir"

  # --- R18: a value-taking flag with no value errors (no infinite loop) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_PLUGIN_REPO='' \
    timeout 10 bash "$script" --approve 2>&1) || ec=$?
  assert_exit_code "R18: missing --approve value exits 2 (no hang)" "$ec" 2
  rm -rf "$workdir"

  # --- R19: a malformed issue list fails CLOSED (not "empty queue") ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_LIST_JSON='not json {{' SAAS_PLUGIN_REPO='' \
    bash "$script" --list --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R19: unparseable list fails closed (non-zero)" "$ec" 1
  rm -rf "$workdir"

  # --- R20: approving a CLOSED+approved issue is refused (no silent resurrect) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    GH_VIEW_JSON='{"state":"CLOSED","labels":[{"name":"lesson-approved"}]}' SAAS_PLUGIN_REPO='' \
    bash "$script" --approve 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R20: refuse approve on closed+approved" "$ec" 1
  assert_equals "R20: no edit on closed+approved" "$(_edits "$L")" "0"
  rm -rf "$workdir"

  # --- R21: a malformed issue-view fails CLOSED on close (no false no-op success) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_JSON='garbage {{' SAAS_PLUGIN_REPO='' \
    bash "$script" --close 5 --repo "$REPO" 2>&1) || ec=$?
  assert_exit_code "R21: unparseable view fails closed on close" "$ec" 1
  assert_equals "R21: no close call on unparseable view" "$(_closes "$L")" "0"
  rm -rf "$workdir"

  # --- R22: --limit 0 is rejected (must be >= 1) ---
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"; : > "$L"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" SAAS_PLUGIN_REPO='' \
    bash "$script" --list --repo "$REPO" --limit 0 2>&1) || ec=$?
  assert_exit_code "R22: --limit 0 refused (exit 2)" "$ec" 2
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite Z: Convergence governor integration
# ---------------------------------------------------------------------------

test_convergence_governor() {
  echo -e "\n${CYAN}Convergence governor integration${NC}"
  assert_output_contains "reachability convention exists" "$(cat "$PLUGIN_ROOT/skills/tech-founder/references/reachability-convention.md" 2>/dev/null)" "last-verified"
  assert_output_contains "tech-founder DoD has step-back" "$(cat "$PLUGIN_ROOT/agents/tech-founder-claude-maintain.md")" "Tribunal step-back"
  assert_output_contains "goal-deliver caps at 20" "$(cat "$PLUGIN_ROOT/references/workflows/goal-deliver.md")" "Round 20:"
  assert_output_contains "goal-deliver stops on no crit/high" "$(cat "$PLUGIN_ROOT/references/workflows/goal-deliver.md")" "zero critical and zero high"
}

test_learnings_style_block() {
  echo -e "\n${CYAN}== Learnings house-style block ==${NC}"
  local f="$PLUGIN_ROOT/templates/learnings-style.md"
  assert_file_exists "L1: learnings-style.md exists" "$f"
  assert_file_contains "L2: defines the line shape"        "$f" "<Label>: <imperative rule>"
  assert_file_contains "L3: mandates terse why"            "$f" "terse why"
  assert_file_contains "L4: Fix is conditional"            "$f" "include only when there is a concrete reusable action"
  assert_file_contains "L5: rations emphasis"              "$f" "catastrophic landmine, never for routine rules"
  assert_file_contains "L6: names Critical Landmines"      "$f" "Critical Landmines"
  assert_file_contains "L7: canonical vs overloaded terms" "$f" "the model silently picks a sense — spell out"
  assert_file_contains "L8: novelty/delta gate"            "$f" "surprising to a competent model"
  assert_file_contains "L9: calibration guard"             "$f" "provenance"
  assert_file_contains "L10: three-tier routing"           "$f" "agent prompt"
  assert_file_contains "L11: exact routine line shape"     "$f" "- <Label>: <imperative rule> — <terse why>. Fix: <reusable pattern>. (ref)"
  assert_file_contains "L12: when-unsure-keep rule"        "$f" "When unsure, keep it"
}

test_founder_standards_routing() {
  echo -e "\n${CYAN}== founder prompts are tier-2 standards home ==${NC}"
  for a in tech-founder-claude business-founder; do
    assert_file_contains "S1:$a declares standards-vs-learnings routing" \
      "$PLUGIN_ROOT/agents/$a.md" "Standards live here"
    assert_file_contains "S2:$a warns off version-specific promotion" \
      "$PLUGIN_ROOT/agents/$a.md" "docs/learnings/"
  done
  # ration: model-default lines removed
  assert_file_not_contains "S3: drops model-default polished-UI guideline" \
    "$PLUGIN_ROOT/agents/tech-founder-claude.md" "build aesthetic, polished UI"
  # capability constraints MUST survive (regression guard)
  assert_file_contains "S4: tech no-web constraint survives" \
    "$PLUGIN_ROOT/agents/tech-founder-claude.md" "tools (you have no web access)"
  assert_file_contains "S5: handoff-split constraint survives" \
    "$PLUGIN_ROOT/agents/tech-founder-claude.md" "handoff with 3+ features — reject it and ask the business founder to split"
}

test_learnings_migrate_house_style() {
  echo -e "\n${CYAN}== learnings-migrate house style ==${NC}"
  local f="$PLUGIN_ROOT/commands/learnings-migrate.md"
  assert_file_contains "M1: references the house-style block" "$f" "learnings-style.md"
  assert_file_contains "M2: bootstraps Critical Landmines"    "$f" "Critical Landmines"
  assert_file_contains "M3: routes routine to failure-mode sections" "$f" "failure-mode"
  assert_file_contains "M4: carries calibration guard"        "$f" "when unsure, keep"
}

test_maintain_agents_reference_style() {
  echo -e "\n${CYAN}== maintain agents reference house style ==${NC}"
  for a in business-founder-maintain tech-founder-claude-maintain tech-founder-codex-maintain; do
    assert_file_contains "N:$a references house style" \
      "$PLUGIN_ROOT/agents/$a.md" "learnings-style.md"
  done
}

test_compress_golden_sample() {
  echo -e "\n${CYAN}== compress golden sample ==${NC}"
  local f="$PLUGIN_ROOT/templates/learnings-compress-golden.md"
  assert_file_exists "G1: golden sample exists" "$f"
  assert_file_contains "G2: has before sections"   "$f" "BEFORE"
  assert_file_contains "G3: has after sections"    "$f" "AFTER"
  assert_file_contains "G4: has reviewer checklist" "$f" "Reviewer checklist"
  local count; count="$(grep -c '^## Transformation ' "$f" || true)"
  assert_equals "G5: >=8 transformations" "$([ "$count" -ge 8 ] && echo ok || echo "only-$count")" "ok"
  assert_file_contains "G6: DELETE-obvious transform" "$f" "DELETE: pure ingrained knowledge"
  assert_file_contains "G7: KEEP calibration transform" "$f" "library-version-specific"
  assert_file_contains "G8: overloaded-term transform" "$f" "overloaded"
  assert_file_contains "G9: merge transform" "$f" "MERGED"
}

test_learnings_compress_command() {
  echo -e "\n${CYAN}== learnings-compress command ==${NC}"
  local f="$PLUGIN_ROOT/commands/learnings-compress.md"
  assert_file_exists "C1: command exists" "$f"
  assert_file_contains "C2: user_invocable"        "$f" "user_invocable: true"
  assert_file_contains "C3: references golden"      "$f" "learnings-compress-golden.md"
  assert_file_contains "C4: emits a changelog"      "$f" "changelog"
  assert_file_contains "C5: gates critical rules"   "$f" "Critical Landmines"
  assert_file_contains "C6: 30KB split rule"        "$f" "30"
  assert_file_contains "C7: one doc per run"        "$f" "one topic"
  assert_file_contains "C8: promotes tier-2 standards" "$f" "PROMOTE"
  assert_file_contains "C9: gates obvious drops"    "$f" "DROP-as-obvious"
  assert_file_contains "C10: calibration guard"     "$f" "calibration guard"
  assert_file_contains "C11: requires approval"     "$f" "approve critical"
  assert_file_contains "C12: exact-duplicate drop"  "$f" "exact duplicate"
}

test_handoff_secret_redaction() {
  echo -e "\n${CYAN}Suite SR: Handoff Secret Redaction Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/check-handoff-secrets.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  assert_file_exists "SR1: check-handoff-secrets.sh exists" "$script"

  # SR2: wired into PostToolUse
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "SR2: hooks.json references check-handoff-secrets.sh" "$hook_refs" "check-handoff-secrets.sh"

  local workdir ec out
  # Fragmented so this repo's bytes hold no contiguous real-looking secret
  local OR="sk-""or-v1-""abcdef0123456789abcdef0123456789"

  # SR3: non-handoff file ignored, exit 0
  ec=0; out=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "SR3: exits 0 for non-handoff file" "$ec" 0

  # SR4–SR7: secret-bearing handoff is REDACTED in place (not blocked), exit 0
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  local hf="$workdir/.startup/handoffs/020-tech-to-business.md"
  printf 'curl -H "Authorization: Bearer %s" x\nOPENROUTER_API_KEY=%s\n' "$OR" "$OR" > "$hf"
  ec=0; out=$(echo '{"tool_input":{"file_path":"'"$hf"'"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "SR4: redacting handoff still exits 0 (never blocks)" "$ec" 0
  assert_output_contains "SR5: emits redaction systemMessage" "$out" "auto-redacted"
  assert_file_contains "SR6: secret replaced with marker" "$hf" "***REDACTED***"
  assert_file_not_contains "SR7: literal key scrubbed from disk" "$hf" "$OR"
  rm -rf "$workdir"

  # SR8: env-var REFERENCES are preserved untouched, exit 0 silent (no message)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  hf="$workdir/.startup/handoffs/018-tech-to-business.md"
  printf 'Use $OPENROUTER_API_KEY (see .env)\ncurl -H "Authorization: Bearer $OPENROUTER_API_KEY"\nADMIN_API_KEY=<configured-in-env>\n' > "$hf"
  local sha_before; sha_before=$(cksum < "$hf")
  ec=0; out=$(echo '{"tool_input":{"file_path":"'"$hf"'"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "SR8: exits 0 for env-var references" "$ec" 0
  assert_output_not_contains "SR9: no redaction message for clean refs" "$out" "auto-redacted"
  assert_equals "SR10: reference-only handoff left unchanged" "$(cksum < "$hf")" "$sha_before"
  rm -rf "$workdir"

  # SR11: emitted systemMessage is valid JSON
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  hf="$workdir/.startup/handoffs/021-tech-to-business.md"
  printf 'OPENROUTER_API_KEY=%s\n' "$OR" > "$hf"
  out=$(echo '{"tool_input":{"file_path":"'"$hf"'"}}' | bash "$script" 2>/dev/null)
  ec=0; echo "$out" | jq -e .systemMessage >/dev/null 2>&1 || ec=$?
  assert_exit_code "SR11: redaction message is valid JSON" "$ec" 0
  rm -rf "$workdir"

  # SR12: missing file is a quiet no-op (exit 0)
  ec=0; out=$(echo '{"tool_input":{"file_path":"/nonexistent/.startup/handoffs/099-x.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "SR12: exits 0 for missing handoff file" "$ec" 0

  # SR13: quoted secret values are redacted (double + single quote)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  hf="$workdir/.startup/handoffs/022-tech-to-business.md"
  printf 'ADMIN_PASSWORD="hunter2plaintextvalue"\nDB_PASSWORD='\''s3cr3tLongValue'\''\n' > "$hf"
  out=$(echo '{"tool_input":{"file_path":"'"$hf"'"}}' | bash "$script" 2>/dev/null)
  assert_file_not_contains "SR13a: double-quoted secret scrubbed" "$hf" "hunter2plaintextvalue"
  assert_file_not_contains "SR13b: single-quoted secret scrubbed" "$hf" "s3cr3tLongValue"
  rm -rf "$workdir"

  # SR14: lowercase 'authorization: bearer' header is redacted (case-insensitive)
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  hf="$workdir/.startup/handoffs/023-tech-to-business.md"
  printf 'curl -H "authorization: bearer eyJhbGciOiJIUzI1NiwidHlwIn0longjwtvalue"\n' > "$hf"
  out=$(echo '{"tool_input":{"file_path":"'"$hf"'"}}' | bash "$script" 2>/dev/null)
  assert_file_not_contains "SR14: lowercase bearer token scrubbed" "$hf" "eyJhbGciOiJIUzI1NiwidHlwIn0longjwtvalue"
  assert_file_contains "SR14b: redaction marker present" "$hf" "***REDACTED***"
  rm -rf "$workdir"

  # SR15: quoted empty value and ${VAR} reference are preserved
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  hf="$workdir/.startup/handoffs/024-tech-to-business.md"
  printf 'KEY=""\nTOKEN="${MY_TOKEN}"\nPASSWORD="$PW"\n' > "$hf"
  local sha2; sha2=$(cksum < "$hf")
  ec=0; out=$(echo '{"tool_input":{"file_path":"'"$hf"'"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "SR15: exits 0 for quoted refs/empty" "$ec" 0
  assert_equals "SR15b: quoted refs/empty left unchanged" "$(cksum < "$hf")" "$sha2"
  rm -rf "$workdir"
}

test_autonomous_demand_infra() {
  echo -e "\n${CYAN}Suite AD: autonomous demand/preflight/single-flight infrastructure${NC}"
  local health="$PLUGIN_ROOT/scripts/health-preflight.sh"
  local lease="$PLUGIN_ROOT/scripts/single-flight.sh"
  local packs="$PLUGIN_ROOT/scripts/acceptance-packs.sh"
  local demand="$PLUGIN_ROOT/scripts/demand-discovery.sh"
  local market="$PLUGIN_ROOT/scripts/market-scout.sh"
  local closure="$PLUGIN_ROOT/scripts/issue-closure-audit.sh"
  local workdir ec output count

  assert_file_exists "AD1: health-preflight exists" "$health"
  assert_file_exists "AD2: single-flight exists" "$lease"
  assert_file_exists "AD3: acceptance-packs exists" "$packs"
  assert_file_exists "AD4: demand-discovery exists" "$demand"
  assert_file_exists "AD4b: market-scout exists" "$market"
  assert_file_exists "AD4c: issue-closure-audit exists" "$closure"
  assert_file_contains "AD4d: Codex smoke uses supported permission flag" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" "--permission-profile"
  assert_file_not_contains "AD4e: Codex smoke drops obsolete plural flag" "$health" "--permissions-profile"
  assert_file_contains "AD4f: shell smoke enables the limited network proxy" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" "--enable network_proxy"
  assert_file_contains "AD4f1: shell smoke declares no outbound destinations" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" 'network.mode="limited"'
  assert_file_not_contains "AD4f2: shell smoke preserves anonymous socketpairs" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" "--sandbox-state-disable-network"
  for s in "$health" "$lease" "$packs" "$demand" "$market" "$closure" \
    "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" \
    "$PLUGIN_ROOT/scripts/supervisor-check-container.sh"; do
    ec=0; bash -n "$s" || ec=$?
    assert_exit_code "AD syntax: $(basename "$s")" "$ec" 0
  done

  # A start-only smoke was a false green (issues #260/#261): the smoke must also
  # prove out-of-sandbox candidate staging and in-sandbox Python thread wakeups.
  assert_file_contains "AD4g: smoke probes trusted staging outside the sandbox" \
    "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" 'core.hooksPath=/dev/null add -A'
  assert_file_contains "AD4h: smoke probes in-sandbox thread wakeups" \
    "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" 'asyncio.to_thread'
  assert_file_contains "AD4h1: smoke probes supervisor process inspection" \
    "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" 'ps -o pid='
  if command -v python3 >/dev/null 2>&1; then
    workdir=$(make_workdir)
    mkdir -p "$workdir/bin"
    cat > "$workdir/bin/codex" <<'SH'
#!/bin/sh
[ "$1" = sandbox ] || exit 2
for a in "$@"; do
  [ "$a" = python3 ] && sleep 5
done
exit 0
SH
    chmod +x "$workdir/bin/codex"
    ec=0; output=$(PATH="$workdir/bin:$PATH" SAAS_CODEX_PREFLIGHT_TIMEOUT=1 \
      bash "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" --root "$workdir" 2>&1) || ec=$?
    assert_exit_code "AD4i: hung in-sandbox thread wakeup blocks" "$ec" 4
    assert_output_contains "AD4j: wakeup diagnosis names the deadlock" "$output" "cross-thread wakeup"
    cat > "$workdir/bin/codex" <<'SH'
#!/bin/sh
[ "$1" = sandbox ] || exit 2
exit 0
SH
    cat > "$workdir/bin/check-driver" <<'SH'
#!/bin/sh
if [ "${1:-}" = --metadata ]; then
  printf '%s\n' '{"docker":{"path":"/usr/bin/false"},"daemon_id":"test","image_id":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
fi
exit 0
SH
    chmod +x "$workdir/bin/codex" "$workdir/bin/check-driver"
    ec=0; output=$(PATH="$workdir/bin:$PATH" SAAS_SUPERVISOR_CHECK_DRIVER="$workdir/bin/check-driver" \
      bash "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" --root "$workdir" 2>&1) || ec=$?
    assert_exit_code "AD4k: healthy sandbox passes staging and wakeup probes" "$ec" 0
    assert_output_contains "AD4l: success names the added probes" "$output" "thread-wakeup probes"

    cat > "$workdir/bin/check-driver" <<'SH'
#!/bin/sh
if [ "${1:-}" = --metadata ]; then
  printf '%s\n' '{"docker":{"path":"/usr/bin/false"},"daemon_id":"test","image_id":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
  exit 0
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C|--docker-bin|--image-id|--daemon-id|--checkout-alias) shift 2 ;;
    --) shift; exec "$@" ;;
    *) exit 2 ;;
  esac
done
exit 2
SH
    chmod +x "$workdir/bin/check-driver"
    ec=0; output=$(PATH="$workdir/bin:$PATH" SAAS_SUPERVISOR_CHECK_DRIVER="$workdir/bin/check-driver" \
      bash "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh" --root "$workdir" 2>&1) || ec=$?
    assert_exit_code "AD4m: writable outside path blocks supervisor smoke" "$ec" 4
    assert_output_contains "AD4n: supervisor isolation failure is explicit" "$output" "Supervisor process check failed"
    rm -rf "$workdir"
  fi

  workdir=$(make_workdir)
  mkdir -p "$workdir/plugin/hooks"
  printf '{"hooks":{}}\n' > "$workdir/plugin/hooks/hooks.json"
  ec=0; output=$(SAAS_PREFLIGHT_MISSING=jq bash "$health" --json --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD5: missing jq is blocking" "$ec" 1
  assert_output_contains "AD5b: reports missing jq" "$output" '"check": "tool:jq"'
  rm -rf "$workdir"

  workdir=$(make_workdir)
  mkdir -p "$workdir/plugin/hooks"
  cat > "$workdir/plugin/hooks/hooks.json" <<'JSON'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"p=scripts/missing.sh; \"$p\""}]}]}}
JSON
  ec=0; output=$(bash "$health" --json --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6: broken hook target blocks" "$ec" 1
  assert_output_contains "AD6b: names missing hook target" "$output" "missing hook target"
  rm -rf "$workdir"

  workdir=$(make_workdir)
  mkdir -p "$workdir/plugin/hooks" "$workdir/bin"
  printf '{"hooks":{}}\n' > "$workdir/plugin/hooks/hooks.json"
  cat > "$workdir/bin/codex" <<'SH'
#!/bin/sh
if [ "$1" = "sandbox" ] && [ "${2:-}" = "--help" ]; then exit 0; fi
if [ "$1" = "sandbox" ]; then
  profile=""
  root=""
  proxy_enabled=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --permission-profile) profile="$2"; shift 2 ;;
      --enable) [ "${2:-}" = network_proxy ] && proxy_enabled=1; shift 2 ;;
      -c) shift 2 ;;
      -C|--cd) root="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$profile" = ":danger-full-access" ] && [ "$proxy_enabled" -eq 1 ]; then
    printf '%s\n' "$root"
    exit 0
  fi
  printf '%s\n' "bwrap: No permissions to create a new namespace" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$workdir/bin/codex"
  cat > "$workdir/bin/sysctl" <<'SH'
#!/bin/sh
shift $(( $# - 1 ))
case "$1" in
  kernel.unprivileged_userns_clone) echo 1 ;;
  user.max_user_namespaces) echo 2059994 ;;
  kernel.apparmor_restrict_unprivileged_userns) echo 1 ;;
  *) exit 1 ;;
esac
SH
  cat > "$workdir/bin/unshare" <<'SH'
#!/bin/sh
echo "unshare: unshare failed: Operation not permitted" >&2
exit 1
SH
  chmod +x "$workdir/bin/sysctl" "$workdir/bin/unshare"
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6c: default workspace-write sandbox blocks when unusable" "$ec" 1
  assert_output_contains "AD6d: reports worker shell smoke" "$output" '"check": "codex:worker-shell"'
  assert_output_contains "AD6e: bwrap failure is surfaced" "$output" "bwrap:"
  assert_output_contains "AD6f: enabled sysctl points at outer runtime/LSM denial" "$output" "outer runtime/LSM"
  assert_output_contains "AD6f2: apparmor restriction is named" "$output" "apparmor_restrict_unprivileged_userns=1"
  assert_output_not_contains "AD6f3: remedy never suggests the already-enabled sysctl" "$output" "set kernel.unprivileged_userns_clone=1"
  assert_output_not_contains "AD6f4: remedy never suggests weakening the writer boundary" "$output" "danger-full-access"
  ec=0; output=$(SAAS_PREFLIGHT_CONTAINER=1 CODEX_SANDBOX=danger-full-access PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6g: danger sandbox is rejected inside containers" "$ec" 1
  assert_output_contains "AD6h: danger rejection names isolated writer mode" "$output" "isolated CODEX_SANDBOX=workspace-write"
  ec=0; output=$(SAAS_PREFLIGHT_CONTAINER=0 CODEX_SANDBOX=danger-full-access PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6i: danger sandbox outside container also blocks" "$ec" 1
  assert_output_contains "AD6j: danger rejection is invariant" "$output" "danger-full-access are not valid writer modes"
  ec=0; output=$(CODEX_SANDBOX=read-only PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6k: read-only worker sandbox blocks" "$ec" 1
  assert_output_contains "AD6l: read-only rejection names writer isolation" "$output" "read-only and danger-full-access"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  ec=0; output=$(bash "$lease" --acquire issue/42 --state-dir "$workdir" --owner one 2>&1) || ec=$?
  assert_exit_code "AD7: lease acquire exits 0" "$ec" 0
  ec=0; output=$(bash "$lease" --acquire issue/42 --state-dir "$workdir" --owner two 2>&1) || ec=$?
  assert_exit_code "AD8: second active owner refused" "$ec" 1
  assert_output_contains "AD8b: active owner reported" "$output" "active owner"
  printf '1\n' > "$workdir/issue-42/heartbeat"
  ec=0; output=$(bash "$lease" --acquire issue/42 --state-dir "$workdir" --owner two --ttl-seconds 1 2>&1) || ec=$?
  assert_exit_code "AD9: stale owner needs explicit replace" "$ec" 2
  ec=0; output=$(bash "$lease" --acquire issue/42 --state-dir "$workdir" --owner two --ttl-seconds 1 --replace-stale --reason "heartbeat expired" 2>&1) || ec=$?
  assert_exit_code "AD10: stale owner replaced with reason" "$ec" 0
  assert_file_contains "AD10b: replacement audited" "$workdir/issue-42/audit.log" "heartbeat expired"
  ec=0; output=$(bash "$lease" --status issue/42 --state-dir "$workdir" --json 2>&1) || ec=$?
  assert_exit_code "AD11: lease status exits 0" "$ec" 0
  assert_output_contains "AD11b: status has owner two" "$output" '"owner":"two"'
  rm -rf "$workdir"

  ec=0; output=$(bash "$packs" --select --category report_output_quality --text "customer report has citations and remedies" --json 2>&1) || ec=$?
  assert_exit_code "AD12: pack select exits 0" "$ec" 0
  assert_output_contains "AD12b: selects report pack" "$output" "report_output_product"
  assert_output_not_contains "AD12c: does not match Estonian pack through generic words" "$output" "estonian_saas_context"
  workdir=$(mktemp -d)
  printf 'Finding: STATUS_PENDING\nNo citation.\n' > "$workdir/bad.md"
  ec=0; output=$(bash "$packs" --verify-report "$workdir/bad.md" 2>&1) || ec=$?
  assert_exit_code "AD13: bad report fixture fails" "$ec" 1
  cat > "$workdir/good.md" <<'MD'
Finding: Payment status is still pending.
Citation: https://example.invalid/source
Recommendation: Next step is to retry the payment status check in the dashboard.
MD
  ec=0; output=$(bash "$packs" --verify-report "$workdir/good.md" 2>&1) || ec=$?
  assert_exit_code "AD14: good report fixture passes" "$ec" 0
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/codex.jsonl" <<'JSONL'
{"message":{"content":"Customers abandon onboarding because the generated report shows raw STATUS_PENDING, has no citation, and gives no next step."}}
JSONL
  ec=0; output=$(bash "$demand" --project "demo-product" --codex-jsonl "$workdir/codex.jsonl" --out "$workdir/candidates.jsonl" --report "$workdir/report.md" 2>&1) || ec=$?
  assert_exit_code "AD15: demand discovery exits 0" "$ec" 0
  count=$(wc -l < "$workdir/candidates.jsonl" | tr -d ' ')
  assert_equals "AD15b: one demand candidate emitted" "$count" "1"
  assert_file_contains "AD15c: includes Codex evidence" "$workdir/candidates.jsonl" "codex-session"
  assert_file_contains "AD15d: includes acceptance packs" "$workdir/candidates.jsonl" "acceptance_packs"
  assert_file_contains "AD15e: report notes no external research" "$workdir/report.md" "external research: not used"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/sources.json" <<'JSON'
[
  {
    "source_type": "public-review",
    "title": "Micro-OÜ owners complain about manual VAT evidence collection",
    "url": "https://example.invalid/reviews/vat-gap",
    "date": "2026-06-30",
    "snippet": "Estonian e-resident micro-OÜ operators say pricing is unclear, report collection is too manual, and exports leak /srv/customer/data.csv paths."
  }
]
JSON
  ec=0; output=$(bash "$market" --project "demo-product" --source-json "$workdir/sources.json" --out "$workdir/market.jsonl" --report "$workdir/market.md" 2>&1) || ec=$?
  assert_exit_code "AD16: market scout external source exits 0" "$ec" 0
  count=$(wc -l < "$workdir/market.jsonl" | tr -d ' ')
  assert_equals "AD16b: one market candidate emitted" "$count" "1"
  assert_file_contains "AD16c: candidate includes source link" "$workdir/market.jsonl" "https://example.invalid/reviews/vat-gap"
  assert_file_contains "AD16d: candidate includes source date" "$workdir/market.jsonl" "2026-06-30"
  assert_file_contains "AD16e: candidate includes confidence" "$workdir/market.jsonl" "confidence"
  assert_file_contains "AD16f: report notes external research used" "$workdir/market.md" "external research: used"
  assert_file_contains "AD16g: de-identifies path placeholders cleanly" "$workdir/market.jsonl" "{{PATH}}"
  assert_file_not_contains "AD16h: no stray bracket before path placeholder" "$workdir/market.jsonl" "[ {{PATH}}"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  ec=0; output=$(cd "$workdir" && bash "$market" --project "demo-product" --out "$workdir/fallback.jsonl" --report "$workdir/fallback.md" 2>&1) || ec=$?
  assert_exit_code "AD17: market scout fallback exits 0" "$ec" 0
  assert_file_contains "AD17b: fallback report notes unavailable external research" "$workdir/fallback.md" "external research: unavailable"
  assert_file_contains "AD17c: fallback report notes internal discovery" "$workdir/fallback.md" "fallback: internal demand discovery"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/pr.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Changes\nFrontend default selection only."}
JSON
  cat > "$workdir/issue.json" <<'JSON'
{"number":55,"title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  printf 'frontend/step2.tsx\n' > "$workdir/files.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD18: closure audit fails missing named surfaces" "$ec" 1
  assert_output_contains "AD18b: closure audit names missing backend path" "$output" "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-ok.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\n#55 frontend scope shipped here; remaining scope has follow-up #56 for backend date emission."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19: closure audit accepts explicit follow-up" "$ec" 0
  mkdir -p "$workdir/bin"
  printf '#!/bin/sh\nexit 1\n' > "$workdir/bin/gh"
  chmod +x "$workdir/bin/gh"
  cat > "$workdir/issue-mismatch.json" <<'JSON'
{"number":54,"title":"Different issue","body":"Acceptance requires `frontend/step2.tsx`."}
JSON
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue-mismatch.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD20: closure audit rejects mismatched single fixture" "$ec" 1
  assert_output_contains "AD20b: mismatched fixture does not stand in for closed issue" "$output" "cannot inspect closing issue #55"
  cat > "$workdir/issue-anon.json" <<'JSON'
{"title":"Anonymous fixture","body":"Acceptance requires `frontend/step2.tsx`."}
JSON
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue-anon.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD21: closure audit accepts anonymous single fixture" "$ec" 0
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/pr-bracket.json" <<'JSON'
{"title":"fix: download flow","body":"Closes #200\n\n## Changes\nUpdated dynamic route page and step component."}
JSON
  cat > "$workdir/issue-bracket.json" <<'JSON'
{"number":200,"title":"Fix download","body":"Acceptance requires `frontend/src/app/[locale]/download/[token]/page.tsx` and `frontend/src/app/[locale]/report/components/Step6Download.tsx`."}
JSON
  printf 'frontend/src/app/[locale]/download/[token]/page.tsx\nfrontend/src/app/[locale]/report/components/Step6Download.tsx\n' > "$workdir/files-bracket.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bracket.json" --issue-json "$workdir/issue-bracket.json" --changed-files "$workdir/files-bracket.txt" 2>&1) || ec=$?
  assert_exit_code "AD22: bracketed Next.js dynamic-route path does not false-fail" "$ec" 0
  rm -rf "$workdir"
}

test_autonomous_workflow_alignment() {
  echo -e "\n${CYAN}Suite AE: autonomous workflow alignment${NC}"
  local repo_root; repo_root="$(cd "$PLUGIN_ROOT/../.." && pwd)"
  assert_file_contains "AE1: startup calls health preflight" "$PLUGIN_ROOT/commands/startup.md" "health-preflight.sh"
  assert_file_contains "AE2: startup uses market scout" "$PLUGIN_ROOT/commands/startup.md" "market-scout.sh"
  assert_file_contains "AE3: startup uses single-flight" "$PLUGIN_ROOT/commands/startup.md" "single-flight.sh"
  assert_file_not_contains "AE4: startup no broad stale pkill command" "$PLUGIN_ROOT/commands/startup.md" "pkill -f 'agent-type saas-startup-team'"
  assert_file_contains "AE5: improve calls health preflight" "$PLUGIN_ROOT/references/workflows/improve.md" "health-preflight.sh"
  assert_file_contains "AE6: goal-deliver calls market scout" "$PLUGIN_ROOT/references/workflows/goal-deliver.md" "market-scout.sh"
  assert_file_contains "AE7: goal-deliver requires acceptance packs" "$PLUGIN_ROOT/references/workflows/goal-deliver.md" "acceptance-packs.sh"
  assert_file_contains "AE8: goal-deliver completion artifact" "$PLUGIN_ROOT/references/workflows/goal-deliver.md" "completion artifact"
  assert_file_contains "AE9: lessons-review points to lessons-deliver" "$PLUGIN_ROOT/commands/lessons-review.md" "/lessons-deliver"
  assert_file_not_contains "AE10: lessons-review no longer routes to goal-deliver command" "$PLUGIN_ROOT/commands/lessons-review.md" "/goal-deliver #<number>"
  assert_file_contains "AE11: lessons-deliver documents Codex host behavior" "$PLUGIN_ROOT/commands/lessons-deliver.md" "Codex surface"
  assert_file_contains "AE12: README documents health preflight" "$PLUGIN_ROOT/README.md" "health-preflight.sh"
  assert_file_contains "AE13: README documents market scout" "$PLUGIN_ROOT/README.md" "market-scout.sh"
  assert_file_contains "AE14: README documents acceptance packs" "$PLUGIN_ROOT/README.md" "acceptance-packs.sh"
  assert_file_contains "AE15: README documents single-flight" "$PLUGIN_ROOT/README.md" "single-flight.sh"
  assert_file_contains "AE16: improve runs closure audit" "$PLUGIN_ROOT/references/workflows/improve.md" "issue-closure-audit.sh"
  assert_file_contains "AE17: goal-deliver runs closure audit" "$PLUGIN_ROOT/references/workflows/goal-deliver.md" "issue-closure-audit.sh"
  assert_file_contains "AE18: goal-deliver asks material promise question" "$PLUGIN_ROOT/references/workflows/goal-deliver.md" "material promise"
  assert_file_contains "AE19: growth detects lifecycle" "$PLUGIN_ROOT/commands/growth.md" "growth_lifecycle"
  assert_file_contains "AE20: growth prelive forbids outreach" "$PLUGIN_ROOT/commands/growth.md" "do not contact prospects"
  assert_file_contains "AE21: growth uses autonomous operations gates" "$PLUGIN_ROOT/commands/growth.md" "owner authorization gates"
  assert_file_not_contains "AE22: growth no longer creates recurring human tasks" "$PLUGIN_ROOT/commands/growth.md" "### 2e: Create human tasks"
  local ec
  ec=0; (cd "$repo_root" && python3 scripts/sync-codex-marketplace.py --check >/dev/null) || ec=$?
  assert_exit_code "AE23: Codex marketplace surfaces in sync" "$ec" 0
}

main() {
  echo -e "${YELLOW}=== saas-startup-team Plugin Tests ===${NC}"
  echo "Plugin root: $PLUGIN_ROOT"
  echo ""

  # Check prerequisites
  if ! command -v jq &>/dev/null; then
    echo -e "${RED}ERROR: jq is required but not found${NC}"
    exit 1
  fi

  test_check_task_complete
  test_status_script
  test_templates
  test_check_sh_template
  test_bootstrap_safety_net
  test_canonical_entrypoint_wiring
  test_plugin_config
  test_stop_hook
  test_startup_init
  test_cross_file_consistency
  test_post_tool_use_hook
  test_plugin_issues
  test_maintain
  test_maintain_loop
  test_auto_commit_hook
  test_check_staged_size
  test_tone_enforcement_hook
  test_json_validation_hook
  test_delegation_enforcement_hook
  test_duplicate_handoff_hook
  test_handoff_secret_redaction
  test_compact_state
  test_migrate_state
  test_index_handoff_hook
  test_enforce_handoff_naming_hook
  test_migrate_handoff_names
  test_goal_deliver
  test_ads_delegation
  test_lawyer_lifecycle
  test_monitor_dedup
  test_operate_workflow_registry_and_gates
  test_session_insights
  test_harvest
  test_autonomous_demand_infra
  test_autonomous_workflow_alignment
  test_lesson_file
  test_lesson_review
  test_lessons_deliver
  test_convergence_governor
  test_learnings_style_block
  test_founder_standards_routing
  test_learnings_migrate_house_style
  test_maintain_agents_reference_style
  test_compress_golden_sample
  test_learnings_compress_command

  # Discovered suites: tests/*.tests.sh are sourced here so contributors add
  # tests as new files without editing this harness (which the lessons-deliver
  # firewall protects). Sourced files use the assert_* helpers above.
  local suite
  for suite in "$PLUGIN_ROOT"/tests/*.tests.sh; do
    [ -e "$suite" ] || continue
    echo ""
    echo -e "${CYAN}Discovered suite: $(basename "$suite")${NC}"
    # shellcheck source=/dev/null
    . "$suite"
  done

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

# ---------------------------------------------------------------------------
# Suite T: /goal-deliver command
# ---------------------------------------------------------------------------

test_goal_deliver() {
  echo -e "\n${CYAN}Suite T: /goal-deliver command${NC}"
  local cmd="$PLUGIN_ROOT/references/workflows/goal-deliver.md"

  assert_file_exists "T1: goal-deliver.md exists" "$cmd"
  assert_file_contains "T2: name frontmatter" "$cmd" "^name: goal-deliver"
  assert_file_contains "T3: user_invocable" "$cmd" "user_invocable: true"
  assert_file_contains "T4: references /improve flow" "$cmd" "/improve"
  assert_file_contains "T5: references tribunal-loop" "$cmd" "tribunal-loop"
  assert_file_contains "T6: references closing-tribunal-loop" "$cmd" "closing-tribunal-loop"
  assert_file_contains "T7: resets active_role" "$cmd" '.active_role ='
  assert_file_contains "T8: warns against team-lead" "$cmd" "team-lead"
  assert_file_contains "T9: documents /goal autonomy pairing" "$cmd" "/goal "
  assert_file_contains "T10: monitors GitHub Actions deploy" "$cmd" "gh run"
}

# ---------------------------------------------------------------------------
# Suite U: /ads command + growth→ads delegation
# ---------------------------------------------------------------------------

test_ads_delegation() {
  echo -e "\n${CYAN}Suite U: /ads command + growth→ads delegation${NC}"
  local cmd="$PLUGIN_ROOT/commands/ads.md"

  # U1–U8: the new /ads command
  assert_file_exists "U1: ads.md exists" "$cmd"
  assert_file_contains "U2: name frontmatter" "$cmd" "^name: ads"
  assert_file_contains "U3: user_invocable" "$cmd" "user_invocable: true"
  assert_file_contains "U4: spawns ads-strategist by scoped registered type" "$cmd" 'subagent_type: "google-ads-strategist:ads-strategist"'
  assert_file_contains "U5: resets active_role" "$cmd" '.active_role ='
  assert_file_contains "U6: creates PAUSED / investor enables" "$cmd" "PAUSED"
  assert_file_contains "U7: hard-dependency install message" "$cmd" "google-ads-strategist"
  # U8: must NOT use the saas read-md idiom (would resolve to the wrong plugin root)
  assert_file_not_contains "U8: no read-md idiom for the strategist" "$cmd" 'agents/ads-strategist.md'

  # U9–U11: the /growth loop auto-delegation branch
  local growth="$PLUGIN_ROOT/commands/growth.md"
  assert_file_contains "U9: growth.md has Google Ads request branch" "$growth" "Google Ads request"
  assert_file_contains "U10: growth loop spawns ads-strategist by scoped type" "$growth" 'subagent_type: "google-ads-strategist:ads-strategist"'
  assert_file_not_contains "U11: growth loop uses no read-md idiom for strategist" "$growth" 'agents/ads-strategist.md'

  # U12–U15: growth-hacker flags Google Ads instead of doing it
  local gh="$PLUGIN_ROOT/agents/growth-hacker.md"
  assert_file_contains "U12: boundary forbids designing/creating/spawning Google Ads" "$gh" "NEVER design, create, or spawn Google Ads"
  assert_file_contains "U13: growth-hacker writes a Google Ads request flag" "$gh" "Google Ads request"
  assert_file_contains "U14: ads.md index retains budget summary lines" "$gh" "Approved budget:"
  assert_file_not_contains "U15: no inline 'create the Google Ads campaign in the dashboard'" "$gh" "the Google Ads campaign in the dashboard"
}

# ---------------------------------------------------------------------------
# Suite V: /lawyer lifecycle guard (in_force / status) — issue #37
#
# A 200 + text from /laws/{act_id}/citation does NOT mean the law is in force.
# These tests run the scripts/lawyer-*.sh helpers against a mock curl, asserting
# the guard refuses / flags correctly, plus the pure text-processing helpers.
# ---------------------------------------------------------------------------

# Extract the first ```bash fenced block within a "## <heading>" section of a
# markdown command file.
extract_md_bash() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    $0 == h { inseg=1; next }
    inseg && /^## / { inseg=0 }
    inseg && /^```bash$/ && !done { cap=1; next }
    cap && /^```$/ { done=1; cap=0; next }
    cap { print }
  ' "$file"
}

# Install a mock `curl` under $1/bin that answers datalake calls from env vars
# FAKE_GRAPH / FAKE_CITATION / FAKE_FEED. Emits a trailing HTTP-code line only
# when the caller passed -w (matching the command body's `-w '\n%{http_code}'`).
make_mock_curl() {
  local bindir="$1/bin"
  mkdir -p "$bindir"
  cat > "$bindir/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
emit_code=0
for a in "$@"; do [ "$a" = "-w" ] && emit_code=1; done
case "$url" in
  *"/graph"*)        body="$FAKE_GRAPH" ;;
  *"/citation"*)     body="$FAKE_CITATION" ;;
  *"/changes/feed"*) body="$FAKE_FEED" ;;
  *)                 body="{}" ;;
esac
[ -n "$body" ] || body="{}"
if [ "$emit_code" = 1 ]; then printf '%s\n%s' "$body" "${FAKE_CODE:-200}"; else printf '%s' "$body"; fi
MOCK
  chmod +x "$bindir/curl"
}

# Mock `gh` under $1/bin. Logs argv (one line/call) to $GH_CALLS_LOG. Env knobs:
#   GH_CREATE_NUMBER  number echoed (as URL) by `gh issue create`
#   GH_VIEW_STATE     value for `gh issue view --json state` (OPEN/CLOSED)
#   GH_VIEW_BODY      value for `gh issue view --json body`   (recovery verification)
#   GH_SEARCH_JSON    JSON for `gh issue list ... --json number` (default [])
#   GH_FAIL_ON        if argv contains this substring, exit 1 (simulate gh failure)
make_mock_gh() {
  local bindir="$1/bin"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'MOCK'
#!/usr/bin/env bash
_args="$*"; printf '%s\n' "${_args//$'\n'/ }" >> "${GH_CALLS_LOG:?}"  # one line/call (flatten bodies)
if [ -n "${GH_FAIL_ON:-}" ] && [[ "$*" == *"$GH_FAIL_ON"* ]]; then
  echo "mock gh: forced failure" >&2; exit 1
fi
case "$1 $2" in
  "repo view")   echo "${GH_REPO:-o/r}" ;;
  "issue create") echo "https://github.com/o/r/issues/${GH_CREATE_NUMBER:?GH_CREATE_NUMBER unset}" ;;
  "issue comment") echo "https://github.com/o/r/issues/commented" ;;
  "issue view")
     if [[ "$*" == *"--json"* ]] && [ -n "${GH_VIEW_JSON:-}" ]; then echo "$GH_VIEW_JSON";
     elif [[ "$*" == *"body"* ]]; then echo "${GH_VIEW_BODY:-}";
     else echo "${GH_VIEW_STATE:-OPEN}"; fi ;;
  "issue list")  echo "${GH_LIST_JSON:-${GH_SEARCH_JSON:-[]}}" ;;
  "issue edit")  : ;;
  "issue close") : ;;
  "label create") : ;;
  "pr create")   echo "https://github.com/o/r/pull/${GH_PR_NUMBER:-999}" ;;
  "pr merge")    : ;;
  "pr list")     echo "${GH_PR_LIST_JSON:-[]}" ;;
  "pr view")     echo "${GH_PR_VIEW_JSON:-{}}" ;;
  *) : ;;
esac
MOCK
  chmod +x "$bindir/gh"
}

test_lessons_deliver() {
  echo -e "\n${CYAN}Suite L: lessons-deliver.sh (autonomous lesson implementer)${NC}"
  local script="$PLUGIN_ROOT/scripts/lessons-deliver.sh"
  local workdir ec output

  # L1: script exists
  assert_file_exists "L1: lessons-deliver.sh exists" "$script"

  # L2: no repo pin -> exit 2
  ec=0; output=$(bash "$script" --list 2>&1) || ec=$?
  assert_exit_code "L2: no repo pin refuses" "$ec" 2
  assert_output_contains "L2: pin message" "$output" "no repo pinned"

  # L3: malformed pin -> exit 2
  ec=0; output=$(bash "$script" --list --repo "not-a-repo" 2>&1) || ec=$?
  assert_exit_code "L3: malformed pin refuses" "$ec" 2

  # L4: lists only lesson-approved, excludes blocked/claimed/needs-human/linked-PR
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_LIST_JSON='[
    {"number":10,"title":"good lesson","labels":[{"name":"lesson-approved"}],"url":"u10","createdAt":"2026-01-01T00:00:00Z","closedByPullRequestsReferences":[]},
    {"number":11,"title":"blocked","labels":[{"name":"lesson-approved"},{"name":"lessons:blocked"}],"url":"u11","createdAt":"2026-01-02T00:00:00Z","closedByPullRequestsReferences":[]},
    {"number":12,"title":"claimed","labels":[{"name":"lesson-approved"},{"name":"lessons:claimed"}],"url":"u12","createdAt":"2026-01-03T00:00:00Z","closedByPullRequestsReferences":[]},
    {"number":13,"title":"has PR","labels":[{"name":"lesson-approved"}],"url":"u13","createdAt":"2026-01-04T00:00:00Z","closedByPullRequestsReferences":[{"number":5}]}
  ]'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --list --json --repo o/r 2>&1) || ec=$?
  assert_exit_code "L4: list exits 0" "$ec" 0
  assert_output_contains "L4: includes eligible #10" "$output" '"number": 10'
  assert_output_not_contains "L4: excludes blocked #11" "$output" '"number": 11'
  assert_output_not_contains "L4: excludes claimed #12" "$output" '"number": 12'
  assert_output_not_contains "L4: excludes linked-PR #13" "$output" '"number": 13'
  unset GH_LIST_JSON; rm -rf "$workdir"

  # L5: unparseable list -> fail closed (exit 1), not "empty queue"
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_LIST_JSON='not json'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --list --repo o/r 2>&1) || ec=$?
  assert_exit_code "L5: unparseable list fails closed" "$ec" 1
  unset GH_LIST_JSON; rm -rf "$workdir"

  # --- firewall ---
  # L10: path outside plugins/ -> blocked
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/etc/passwd b/etc/passwd
+++ b/etc/passwd
+pwn
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L10: out-of-tree path blocked" "$ec" 3
  assert_output_contains "L10: names path violation" "$output" "BLOCKED"
  rm -rf "$workdir"

  # L11: self-mod of the loop's own safety infra -> blocked
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/plugins/saas-startup-team/scripts/lessons-deliver.sh b/plugins/saas-startup-team/scripts/lessons-deliver.sh
+++ b/plugins/saas-startup-team/scripts/lessons-deliver.sh
+# sneaky
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11: self-mod blocked" "$ec" 3
  assert_output_contains "L11: self-mod reason" "$output" "self-mod"

  cat > "$workdir/d.diff" <<'EOF'
diff --git a/plugins/saas-startup-team/scripts/supervisor-commit.sh b/plugins/saas-startup-team/scripts/supervisor-commit.sh
--- a/plugins/saas-startup-team/scripts/supervisor-commit.sh
+++ b/plugins/saas-startup-team/scripts/supervisor-commit.sh
@@ -1 +1 @@
-safe
+worker-controlled
EOF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11a: supervisor trust code self-mod blocked" "$ec" 3

  cat > "$workdir/d.diff" <<'EOF'
diff --git a/plugins/x b/plugins/decoy b/plugins/saas-startup-team/scripts/lessons-deliver.sh
--- a/plugins/x b/plugins/decoy
+++ b/plugins/saas-startup-team/scripts/lessons-deliver.sh
@@ -1 +1 @@
-safe
+worker-controlled
EOF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11aa: whitespace header cannot hide protected destination" "$ec" 3

  {
    echo 'diff --git a/plugins/x b/plugins/decoy b/plugins/saas-startup-team/scripts/lessons-deliver.sh'
    for n in $(seq 1 10000); do
      printf 'diff --git a/plugins/example/file-%s b/plugins/example/file-%s\n' "$n" "$n"
    done
  } > "$workdir/d.diff"
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11aaa: large header stream cannot bypass strict parsing" "$ec" 3

  cat > "$workdir/d.diff" <<'EOF'
diff --git a/plugins/saas-startup-team/tests/runtime-safety.tests.sh b/plugins/saas-startup-team/tests/runtime-safety.tests.sh
deleted file mode 100644
--- a/plugins/saas-startup-team/tests/runtime-safety.tests.sh
+++ /dev/null
@@ -1 +0,0 @@
-assert_equals "safety" yes yes
EOF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11ab: discovered test deletion is blocked" "$ec" 3

  cat > "$workdir/d.diff" <<'EOF'
diff --git a/plugins/example/component.spec.ts b/plugins/example/component.spec.ts
deleted file mode 100644
--- a/plugins/example/component.spec.ts
+++ /dev/null
@@ -1 +0,0 @@
-export const fixture = true
EOF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11aba: spec-file deletion is blocked without assertion text" "$ec" 3

  cat > "$workdir/d.diff" <<'EOF'
diff --git a/plugins/example/tests/security.test.ts b/plugins/example/archive/security.test.ts
similarity index 100%
rename from plugins/example/tests/security.test.ts
rename to plugins/example/archive/security.test.ts
EOF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11abb: test removal by rename is blocked" "$ec" 3

  cat > "$workdir/d.diff" <<'EOF'
diff --git a/plugins/example/tests/unit.sh b/plugins/example/tests/unit.sh
--- a/plugins/example/tests/unit.sh
+++ b/plugins/example/tests/unit.sh
@@ -1,2 +1 @@
-assert_equals "one" yes yes
 assert_equals "two" yes yes
EOF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11ac: assertion-count reduction is blocked" "$ec" 3
  rm -rf "$workdir"

  # L11b: self-mod of the deliverer's OWN command playbook -> blocked
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/plugins/saas-startup-team/commands/lessons-deliver.md b/plugins/saas-startup-team/commands/lessons-deliver.md
+++ b/plugins/saas-startup-team/commands/lessons-deliver.md
+weaken the gate
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L11b: self-mod of playbook blocked" "$ec" 3
  rm -rf "$workdir"

  # L12: test-harness change -> blocked (self-mod)
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/plugins/saas-startup-team/tests/run-tests.sh b/plugins/saas-startup-team/tests/run-tests.sh
+++ b/plugins/saas-startup-team/tests/run-tests.sh
-  assert_exit_code "X" "$ec" 0
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L12: test-harness change blocked (self-mod)" "$ec" 3
  rm -rf "$workdir"

  # L13: clean in-tree plugin change -> passes
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/plugins/saas-startup-team/commands/status.md b/plugins/saas-startup-team/commands/status.md
+++ b/plugins/saas-startup-team/commands/status.md
+a harmless documentation line
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L13: clean change passes" "$ec" 0
  rm -rf "$workdir"

  # L14: root marketplace.json is allowed
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/.claude-plugin/marketplace.json b/.claude-plugin/marketplace.json
+++ b/.claude-plugin/marketplace.json
+  "version": "0.58.0"
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L14: marketplace.json allowed" "$ec" 0
  rm -rf "$workdir"

  # L15: a secret in the diff body -> blocked by pii_hit
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/plugins/saas-startup-team/commands/status.md b/plugins/saas-startup-team/commands/status.md
+++ b/plugins/saas-startup-team/commands/status.md
+export TOKEN=sk-abcdefghijklmnopqrstuvwxyz0123
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L15: secret in diff blocked" "$ec" 3
  assert_output_contains "L15: secret reason" "$output" "secret/PII"
  rm -rf "$workdir"

  # L16: quoted-path diff header -> blocked (fail closed)
  workdir=$(make_workdir)
  printf 'diff --git "a/plugins/x y.md" "b/plugins/x y.md"\n+a\n' > "$workdir/d.diff"
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L16: quoted path blocked" "$ec" 3
  rm -rf "$workdir"

  # L17: rename from OUT-OF-TREE into plugins/ -> blocked (the a/ side fails the allowlist)
  workdir=$(make_workdir)
  cat > "$workdir/d.diff" <<'DIFF'
diff --git a/secrets/key.txt b/plugins/saas-startup-team/commands/key.txt
rename from secrets/key.txt
rename to plugins/saas-startup-team/commands/key.txt
DIFF
  ec=0; output=$(bash "$script" --firewall "$workdir/d.diff" 2>&1) || ec=$?
  assert_exit_code "L17: out-of-tree rename source blocked" "$ec" 3
  rm -rf "$workdir"

  # --- claim ---
  # L20: claim an eligible issue edits labels
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --claim 10 --repo o/r --run-id RUN1 2>&1) || ec=$?
  assert_exit_code "L20: claim exits 0" "$ec" 0
  assert_file_contains "L20: adds claimed label" "$GH_CALLS_LOG" "lessons:claimed"
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # L21: claim refuses when a linked PR exists (fail closed)
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"}],"closedByPullRequestsReferences":[{"number":7}]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --claim 10 --repo o/r 2>&1) || ec=$?
  assert_exit_code "L21: claim with linked PR refuses" "$ec" 1
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # L22: claim fails closed when issue cannot be inspected
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"; export GH_FAIL_ON="issue view"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --claim 10 --repo o/r 2>&1) || ec=$?
  assert_exit_code "L22: claim fails closed on view error" "$ec" 1
  unset GH_FAIL_ON; rm -rf "$workdir"

  # L23b: claim refuses when already claimed (not a no-op)
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"},{"name":"lessons:claimed"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --claim 10 --repo o/r 2>&1) || ec=$?
  assert_exit_code "L23b: already-claimed refuses" "$ec" 1
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # L23c: claim refuses a closed issue
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"CLOSED","labels":[{"name":"lesson-approved"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --claim 10 --repo o/r 2>&1) || ec=$?
  assert_exit_code "L23c: closed issue refused" "$ec" 1
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # --- block ---
  # L23: block removes lesson-approved and adds lessons:blocked
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"},{"name":"lessons:claimed"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --block 10 --reason "tribunal stuck" --repo o/r 2>&1) || ec=$?
  assert_exit_code "L23: block exits 0" "$ec" 0
  assert_file_contains "L23: adds blocked label" "$GH_CALLS_LOG" "lessons:blocked"
  assert_file_contains "L23: removes approved label" "$GH_CALLS_LOG" "remove-label lesson-approved"
  assert_file_contains "L23: removes claimed label" "$GH_CALLS_LOG" "remove-label lessons:claimed"
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # L23d: block fails closed when the label edit fails
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"; export GH_FAIL_ON="issue edit"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --block 10 --reason x --repo o/r 2>&1) || ec=$?
  assert_exit_code "L23d: block edit failure -> exit 1" "$ec" 1
  unset GH_VIEW_JSON GH_FAIL_ON; rm -rf "$workdir"

  # --- needs-human ---
  # L23e: needs-human relabels and drops approved+claimed
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"},{"name":"lessons:claimed"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --needs-human 10 --reason "self-mod" --repo o/r 2>&1) || ec=$?
  assert_exit_code "L23e: needs-human exits 0" "$ec" 0
  assert_file_contains "L23e: adds needs-human label" "$GH_CALLS_LOG" "lessons:needs-human"
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # --- ship ---
  # L24: ship adds lesson-shipped, removes claimed
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"OPEN","labels":[{"name":"lesson-approved"},{"name":"lessons:claimed"}],"closedByPullRequestsReferences":[]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --ship 10 --pr "https://github.com/o/r/pull/3" --repo o/r 2>&1) || ec=$?
  assert_exit_code "L24: ship exits 0" "$ec" 0
  assert_file_contains "L24: adds shipped label" "$GH_CALLS_LOG" "lesson-shipped"
  assert_file_contains "L24: removes claimed label" "$GH_CALLS_LOG" "remove-label lessons:claimed"
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # L24b: ship is idempotent — already shipped is a no-op (no duplicate comment)
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_VIEW_JSON='{"state":"CLOSED","labels":[{"name":"lesson-shipped"}],"closedByPullRequestsReferences":[{"number":3}]}'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --ship 10 --pr "https://github.com/o/r/pull/3" --repo o/r 2>&1) || ec=$?
  assert_exit_code "L24b: re-ship no-op exits 0" "$ec" 0
  assert_output_contains "L24b: reports no-op" "$output" "already shipped"
  unset GH_VIEW_JSON; rm -rf "$workdir"

  # --- version bump ---
  # L30: bumps BOTH plugin.json and marketplace.json in sync
  workdir=$(make_workdir)
  mkdir -p "$workdir/plugins/saas-startup-team/.claude-plugin" "$workdir/.claude-plugin"
  echo '{"name":"saas-startup-team","version":"1.2.3"}' > "$workdir/plugins/saas-startup-team/.claude-plugin/plugin.json"
  echo '{"plugins":[{"name":"saas-startup-team","version":"1.2.3"}]}' > "$workdir/.claude-plugin/marketplace.json"
  ec=0; output=$(cd "$workdir" && bash "$script" --bump-version minor 2>&1) || ec=$?
  assert_exit_code "L30: bump exits 0" "$ec" 0
  assert_json_field "L30: plugin.json bumped" "$workdir/plugins/saas-startup-team/.claude-plugin/plugin.json" '.version' "1.3.0"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' "$workdir/.claude-plugin/marketplace.json")" = "1.3.0" ]; then
    echo -e "  ${GREEN}PASS${NC} L31: marketplace.json bumped in sync"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} L31: marketplace.json not bumped"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("L31")
  fi
  rm -rf "$workdir"

  # --- gh error classification ---
  # L32: rate limit is retriable
  output=$(bash "$script" --classify-gh-error "API rate limit exceeded" 2>&1)
  assert_equals "L32: rate limit retriable" "$output" "retriable"
  # L33: merge conflict is terminal
  output=$(bash "$script" --classify-gh-error "merge conflict between base and head" 2>&1)
  assert_equals "L33: conflict terminal" "$output" "terminal"
  # L34: HTTP 503 is retriable
  output=$(bash "$script" --classify-gh-error "HTTP 503 service unavailable" 2>&1)
  assert_equals "L34: 503 retriable" "$output" "retriable"
  # L35: auth failure is terminal
  output=$(bash "$script" --classify-gh-error "HTTP 401: Bad credentials" 2>&1)
  assert_equals "L35: auth terminal" "$output" "terminal"
  # L36: protected-branch denial is terminal
  output=$(bash "$script" --classify-gh-error "Protected branch update failed (403)" 2>&1)
  assert_equals "L36: protected branch terminal" "$output" "terminal"
  # L37: HTTP 500 is retriable (any 5xx)
  output=$(bash "$script" --classify-gh-error "HTTP 500: internal server error" 2>&1)
  assert_equals "L37: 500 retriable" "$output" "retriable"

  # --- reconcile ---
  # L40: a claimed issue whose lesson PR merged is repaired to shipped
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_LIST_JSON='[{"number":10,"labels":[{"name":"lessons:claimed"}]}]'
  export GH_PR_LIST_JSON='[{"number":3,"state":"MERGED","headRefName":"lesson/10-foo","body":"Closes #10"}]'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --reconcile --repo o/r 2>&1) || ec=$?
  assert_exit_code "L40: reconcile exits 0" "$ec" 0
  assert_file_contains "L40: repaired to shipped" "$GH_CALLS_LOG" "lesson-shipped"
  unset GH_LIST_JSON GH_PR_LIST_JSON; rm -rf "$workdir"

  # L41: reconcile fails closed on a gh issue-list error (no mass relabel)
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"; export GH_FAIL_ON="issue list"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --reconcile --repo o/r 2>&1) || ec=$?
  assert_exit_code "L41: reconcile fails closed on issue list" "$ec" 1
  unset GH_FAIL_ON; rm -rf "$workdir"

  # L42: reconcile fails closed on a gh pr-list error (transient != 'nothing merged')
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_LIST_JSON='[{"number":10,"labels":[{"name":"lessons:claimed"}]}]'
  export GH_FAIL_ON="pr list"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --reconcile --repo o/r 2>&1) || ec=$?
  assert_exit_code "L42: reconcile fails closed on pr list" "$ec" 1
  unset GH_LIST_JSON GH_FAIL_ON; rm -rf "$workdir"

  # L43: Closes #N boundary — claimed #1 with a PR closing #10 is NOT repaired
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_LIST_JSON='[{"number":1,"labels":[{"name":"lessons:claimed"}]}]'
  export GH_PR_LIST_JSON='[{"number":3,"state":"MERGED","headRefName":"lesson/10-foo","body":"Closes #10"}]'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --reconcile --repo o/r 2>&1) || ec=$?
  assert_exit_code "L43: reconcile exits 0" "$ec" 0
  assert_output_contains "L43: repaired 0" "$output" "repaired 0"
  assert_file_not_contains "L43: #1 not relabelled shipped" "$GH_CALLS_LOG" "lesson-shipped"
  unset GH_LIST_JSON GH_PR_LIST_JSON; rm -rf "$workdir"

  # L44: reconcile lists claimed with --state all (a Closes-#N merge auto-closed the issue)
  workdir=$(make_workdir); make_mock_gh "$workdir"
  export GH_CALLS_LOG="$workdir/gh.log"; : > "$GH_CALLS_LOG"
  export GH_LIST_JSON='[{"number":10,"labels":[{"name":"lessons:claimed"}]}]'
  export GH_PR_LIST_JSON='[{"number":3,"state":"MERGED","headRefName":"lesson/10-foo","body":"Closes #10"}]'
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --reconcile --repo o/r 2>&1) || ec=$?
  assert_exit_code "L44: reconcile exits 0" "$ec" 0
  assert_file_contains "L44: lists claimed with --state all" "$GH_CALLS_LOG" "issue list --repo o/r --label lessons:claimed --state all"
  assert_file_contains "L44: repaired closed-but-claimed to shipped" "$GH_CALLS_LOG" "lesson-shipped"
  unset GH_LIST_JSON GH_PR_LIST_JSON; rm -rf "$workdir"

  # --- command playbook ---
  local cmd="$PLUGIN_ROOT/commands/lessons-deliver.md"
  assert_file_exists "L50: command exists" "$cmd"
  assert_file_contains "L50a: user_invocable" "$cmd" "user_invocable: true"
  assert_file_contains "L51: pins repo via SAAS_PLUGIN_REPO" "$cmd" "SAAS_PLUGIN_REPO"
  assert_file_contains "L52: dedicated worktree" "$cmd" ".worktrees/lessons-deliver"
  assert_file_contains "L53: reconcile on startup" "$cmd" "--reconcile"
  assert_file_contains "L54: calls firewall before merge" "$cmd" "--firewall"
  assert_file_contains "L55: tribunal gate" "$cmd" "tribunal"
  assert_file_contains "L56: runs the test suite" "$cmd" "run-tests.sh"
  assert_file_contains "L57: bumps version" "$cmd" "--bump-version"
  assert_file_contains "L58: PR carries Closes #N" "$cmd" "Closes #"
  assert_file_contains "L59: merge on green only" "$cmd" "gh pr merge"
  assert_file_contains "L60: dispatches implementer agent" "$cmd" "tech-founder-claude-maintain"
  assert_file_contains "L61: dry-run is read-only" "$cmd" "--dry-run"
  assert_file_contains "L62: injection firewall note" "$cmd" "informs requirements only"
  assert_file_contains "L63: self-mod escalates to needs-human" "$cmd" "lessons:needs-human"
}

test_lawyer_lifecycle() {
  echo -e "\n${CYAN}Suite V: /lawyer lifecycle guard (in_force/status)${NC}"
  local skill="$PLUGIN_ROOT/skills/lawyer/SKILL.md"
  local ref="$PLUGIN_ROOT/skills/lawyer/references/law-registry.md"
  local scr="$PLUGIN_ROOT/scripts"
  local reg="$scr/lawyer-register.sh"
  local chk="$scr/lawyer-check.sh"
  local ackscr="$scr/lawyer-ack.sh"
  local ackall="$scr/lawyer-ack-all.sh"
  local workdir ec output has

  # --- Spec assertions: guard present on each script + docs ---
  assert_file_contains "V1: register parses in_force" "$reg" 'CITE_IN_FORCE='
  assert_file_contains "V2: register refuses non-valid (message)" "$reg" "not in force"
  assert_file_contains "V3: register honours --force" "$reg" 'FORCE=1'
  assert_file_contains "V4: change detection lifecycle re-check" "$chk" 'lc_notvalid'
  assert_file_contains "V5: check lifecycle re-check" "$chk" 'elutsükli-kontrolliga'
  assert_file_contains "V6: ack refuses non-valid" "$ackscr" 'Refusing to ack'
  assert_file_contains "V7: ack-all skips non-valid" "$ackall" 'flag kept'
  assert_file_contains "V8: SKILL documents in_force/status" "$skill" 'in_force'
  assert_file_contains "V9: SKILL workflow 200 caution" "$skill" 'A 200 does not mean the law is in force'
  assert_file_contains "V10: law-registry doc 200 caution" "$ref" '200 ≠ in force'

  # --- Executable: register MUST REFUSE a repealed act ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup"  # /lawyer pre-flight guarantees .startup/ exists
  assert_file_exists "V11: register script present" "$reg"
  export FAKE_GRAPH='{"act":{"rt_id":"1061448","title":"Julgeolekumaksu seadus","act_type":"seadus"}}'
  export FAKE_CITATION='{"act_id":34398,"act_title":"Julgeolekumaksu seadus","paragraph":"18","text":"Maksumäär on 2%.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"repealed","in_force":false,"redaktsioon_date":"2026-01-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$reg" julgeolekumaks 34398 "§ 18" "phantom tax" 2>&1) || ec=$?
  assert_exit_code "V12: register refuses repealed (non-zero)" "$ec" 1
  assert_output_contains "V13: refusal explains not in force" "$output" "not in force"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -f "$workdir/.startup/laws/julgeolekumaks.txt" ]; then
    echo -e "  ${GREEN}PASS${NC} V14: no snapshot written for refused register"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} V14: snapshot written despite refusal"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("V14: snapshot written despite refusal")
  fi
  if [ -f "$workdir/.startup/law-registry.json" ]; then
    has=$(jq -r '.entries | has("julgeolekumaks")' "$workdir/.startup/law-registry.json" 2>/dev/null || echo "true")
  else
    has="false"
  fi
  assert_equals "V15: no registry entry for refused register" "$has" "false"
  rm -rf "$workdir"

  # --- Executable: --force overrides the guard ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup"  # /lawyer pre-flight guarantees .startup/ exists
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$reg" julgeolekumaks 34398 "§ 18" "phantom tax" --force 2>&1) || ec=$?
  assert_exit_code "V16: register --force on repealed exits 0" "$ec" 0
  assert_file_exists "V17: --force writes snapshot" "$workdir/.startup/laws/julgeolekumaks.txt"
  assert_json_field "V18: --force stores status=repealed" "$workdir/.startup/law-registry.json" '.entries.julgeolekumaks.status' "repealed"
  rm -rf "$workdir"

  # --- Executable: a VALID act registers and stores lifecycle fields ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup"  # /lawyer pre-flight guarantees .startup/ exists
  export FAKE_GRAPH='{"act":{"rt_id":"1045568","title":"Isikuandmete kaitse seadus","act_type":"seadus"}}'
  export FAKE_CITATION='{"act_id":30087,"act_title":"Isikuandmete kaitse seadus","paragraph":"10","text":"Töötlemine on lubatud.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"valid","in_force":true,"redaktsioon_date":"2026-03-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$reg" consent 30087 "§ 10" "lawful basis" 2>&1) || ec=$?
  assert_exit_code "V19: register valid act exits 0" "$ec" 0
  assert_json_field "V20: valid act stored status=valid" "$workdir/.startup/law-registry.json" '.entries.consent.status' "valid"
  assert_json_field "V21: valid act stored redaktsioon_date" "$workdir/.startup/law-registry.json" '.entries.consent.redaktsioon_date' "2026-03-01"
  rm -rf "$workdir"

  # --- Executable: `check` flags an act that flipped to repealed (no feed event) ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup/laws"
  cat > "$workdir/.startup/law-registry.json" <<'REG'
{"version":2,"last_feed_check_at":null,"entries":{
  "phantom":{"act_id":34398,"rt_id":"1061448","redaktsioon_id":"106032026010","redaktsioon_date":"2026-01-01","status":"valid","act_title":"Julgeolekumaksu seadus","act_type":"seadus","citation":"§ 18","citation_parts":{"paragraph":"18","paragraph_qualifier":"","section":"","section_qualifier":"","point":"","point_qualifier":""},"rt_url":"https://www.riigiteataja.ee/akt/106032026010","registered_at":"2026-01-01T00:00:00Z","verified_at":"2026-01-01T00:00:00Z","registered_by":"lawyer","purpose":"x","needs_review":false,"change_detected_at":null,"change":null,"gh_issue_url":null}
}}
REG
  export FAKE_FEED='{"items":[],"total":0}'
  export FAKE_CITATION='{"act_id":34398,"act_title":"Julgeolekumaksu seadus","paragraph":"18","text":"Maksumäär on 2%.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"repealed","in_force":false,"redaktsioon_date":"2026-01-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$chk" 2>&1) || ec=$?
  assert_exit_code "V23: check exits 0" "$ec" 0
  assert_json_field "V24: repealed entry flagged needs_review" "$workdir/.startup/law-registry.json" '.entries.phantom.needs_review' "true"
  assert_json_field "V25: change.type is lifecycle" "$workdir/.startup/law-registry.json" '.entries.phantom.change.type' "lifecycle"
  assert_json_field "V26: status updated to repealed" "$workdir/.startup/law-registry.json" '.entries.phantom.status' "repealed"
  unset FAKE_FEED FAKE_CITATION FAKE_GRAPH
  rm -rf "$workdir"

  # --- Executable: `ack` MUST REFUSE to re-bless a repealed redaction ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup/laws"
  printf 'OLD TEXT\n' > "$workdir/.startup/laws/phantom.txt"
  cat > "$workdir/.startup/law-registry.json" <<'REG'
{"version":2,"last_feed_check_at":null,"entries":{
  "phantom":{"act_id":34398,"rt_id":"1061448","redaktsioon_id":"106032026010","redaktsioon_date":"2026-01-01","status":"valid","act_title":"Julgeolekumaksu seadus","act_type":"seadus","citation":"§ 18","citation_parts":{"paragraph":"18","paragraph_qualifier":"","section":"","section_qualifier":"","point":"","point_qualifier":""},"rt_url":"https://www.riigiteataja.ee/akt/106032026010","registered_at":"2026-01-01T00:00:00Z","verified_at":"2026-01-01T00:00:00Z","registered_by":"lawyer","purpose":"x","needs_review":true,"change_detected_at":"2026-05-01T00:00:00Z","change":{"feed_event_id":null,"type":"lifecycle","summary":"x","effective_date":null},"gh_issue_url":null}
}}
REG
  export FAKE_CITATION='{"act_id":34398,"act_title":"Julgeolekumaksu seadus","paragraph":"18","text":"Maksumäär on 2%.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"repealed","in_force":false,"redaktsioon_date":"2026-01-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$ackscr" phantom 2>&1) || ec=$?
  assert_exit_code "V27: ack refuses repealed (non-zero)" "$ec" 1
  assert_output_contains "V28: ack refusal message" "$output" "Refusing to ack"
  assert_json_field "V29: ack kept needs_review=true" "$workdir/.startup/law-registry.json" '.entries.phantom.needs_review' "true"
  assert_equals "V30: ack did not overwrite snapshot" "$(cat "$workdir/.startup/laws/phantom.txt")" "OLD TEXT"
  unset FAKE_CITATION
  rm -rf "$workdir"

  # --- Pure text-processing helpers (no network) ---
  # V31: citation parser preserves the superscript qualifier (§ 14 lõige 1¹ punkt 3)
  output=$(bash -c 'source "$1/lawyer-common.sh"; lawyer_parse_citation "§ 14 lõige 1¹ punkt 3"' _ "$scr")
  assert_equals "V31: parse_citation pipes parts + qualifier" "$output" "14||1|1|3|"
  # V32: citation-URL builder re-attaches + URL-encodes the superscript
  output=$(bash -c 'source "$1/lawyer-common.sh"; lawyer_cite_url 30087 14 "" 1 1 "" ""' _ "$scr")
  assert_equals "V32: cite_url encodes section=1¹" "$output" "https://datalake.r-53.com/api/v1/laws/30087/citation?paragraph=14&section=1%C2%B9"
  # V33: DATALAKE_URL override is honoured by the builder
  output=$(DATALAKE_URL="https://example.test" bash -c 'source "$1/lawyer-common.sh"; lawyer_cite_url 30087 10 "" "" "" "" ""' _ "$scr")
  assert_output_contains "V33: cite_url honours DATALAKE_URL override" "$output" "https://example.test/api/v1/laws/30087/citation"
  # V34: marker scan maps every comma-separated slug to file:line, skips docs/legal/
  workdir=$(make_workdir)
  mkdir -p "$workdir/src" "$workdir/docs/legal"
  printf '// LAW: consent-basis, cookie-x\n' > "$workdir/src/a.ts"
  printf '<!-- LAW: should-not-appear -->\n' > "$workdir/docs/legal/out.md"
  output=$(cd "$workdir" && bash "$scr/lawyer-marker-scan.sh")
  assert_output_contains "V34a: marker scan finds first slug" "$output" $'consent-basis\tsrc/a.ts:1'
  assert_output_contains "V34b: marker scan splits comma slug" "$output" $'cookie-x\tsrc/a.ts:1'
  assert_output_not_contains "V34c: marker scan excludes docs/legal/" "$output" "should-not-appear"
  rm -rf "$workdir"
}

main "$@"
