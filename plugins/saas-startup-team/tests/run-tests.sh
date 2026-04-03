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
# Suite J: PLUGIN_ISSUES.md
# ---------------------------------------------------------------------------

test_plugin_issues() {
  echo -e "\n${CYAN}Suite J: PLUGIN_ISSUES.md${NC}"
  local issues_file="$PLUGIN_ROOT/PLUGIN_ISSUES.md"

  # J1: PLUGIN_ISSUES.md exists at plugin root
  assert_file_exists "J1: PLUGIN_ISSUES.md exists" "$issues_file"

  # J2: contains ## Issues section
  assert_file_contains "J2: has Issues section" "$issues_file" "## Issues"

  # J3: contains ## What Goes Here section
  assert_file_contains "J3: has What Goes Here section" "$issues_file" "## What Goes Here"

  # J4: contains ## What Does NOT Go Here section
  assert_file_contains "J4: has What Does NOT Go Here section" "$issues_file" "## What Does NOT Go Here"

  # J5: business-founder.md mentions PLUGIN_ISSUES.md
  assert_file_contains "J5: business-founder.md mentions PLUGIN_ISSUES.md" \
    "$PLUGIN_ROOT/agents/business-founder.md" "PLUGIN_ISSUES.md"

  # J6: tech-founder.md mentions PLUGIN_ISSUES.md
  assert_file_contains "J6: tech-founder.md mentions PLUGIN_ISSUES.md" \
    "$PLUGIN_ROOT/agents/tech-founder.md" "PLUGIN_ISSUES.md"
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

  # K7: hooks.json PostToolUse has 2 entries
  local ptu_count
  ptu_count=$(jq '.hooks.PostToolUse | length' "$hooks_file" 2>/dev/null)
  assert_equals "K7: PostToolUse has 11 entries" "$ptu_count" "11"

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

  # L10: hooks.json PostToolUse has 6 entries
  local ptu_count
  ptu_count=$(jq '.hooks.PostToolUse | length' "$hooks_file" 2>/dev/null)
  assert_equals "L10: PostToolUse has 11 entries" "$ptu_count" "11"

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

main "$@"
