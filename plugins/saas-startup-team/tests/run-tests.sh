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
  assert_json_field "E3: plugin.json has version" "$PLUGIN_ROOT/.claude-plugin/plugin.json" ".version" "0.1.0"
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
# Suite F: Stop Hook
# ---------------------------------------------------------------------------

test_stop_hook() {
  echo -e "\n${CYAN}Suite F: Stop Hook${NC}"
  local workdir ec

  # The Stop hook command is: test -f .startup/go-live/solution-signoff.md

  # F1: no .startup → exit 1
  workdir=$(make_workdir)
  ec=0; (cd "$workdir" && test -f .startup/go-live/solution-signoff.md) || ec=$?
  assert_exit_code "F1: no .startup dir → stop blocked" "$ec" 1
  rm -rf "$workdir"

  # F2: empty go-live → exit 1
  workdir=$(make_workdir)
  mkdir -p "$workdir/.startup/go-live"
  ec=0; (cd "$workdir" && test -f .startup/go-live/solution-signoff.md) || ec=$?
  assert_exit_code "F2: empty go-live → stop blocked" "$ec" 1
  rm -rf "$workdir"

  # F3: signoff exists → exit 0
  workdir=$(make_workdir)
  mkdir -p "$workdir/.startup/go-live"
  echo "signed off" > "$workdir/.startup/go-live/solution-signoff.md"
  ec=0; (cd "$workdir" && test -f .startup/go-live/solution-signoff.md) || ec=$?
  assert_exit_code "F3: signoff exists → stop allowed" "$ec" 0
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
}

# ---------------------------------------------------------------------------
# Suite I: PostToolUse Hook
# ---------------------------------------------------------------------------

test_post_tool_use_hook() {
  echo -e "\n${CYAN}Suite I: PostToolUse Hook${NC}"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # I1: hooks.json has PostToolUse key
  local hooks_keys
  hooks_keys=$(jq -r '.hooks | keys[]' "$hooks_file" 2>/dev/null)
  assert_output_contains "I1: hooks.json has PostToolUse key" "$hooks_keys" "PostToolUse"

  # I2: PostToolUse matcher covers Edit|Write
  local matcher
  matcher=$(jq -r '.hooks.PostToolUse[0].matcher' "$hooks_file" 2>/dev/null)
  assert_output_contains "I2: PostToolUse matcher covers Edit" "$matcher" "Edit"
  assert_output_contains "I2b: PostToolUse matcher covers Write" "$matcher" "Write"

  # I3: PostToolUse hook type is "prompt"
  assert_json_field "I3: PostToolUse hook type is prompt" "$hooks_file" \
    '.hooks.PostToolUse[0].hooks[0].type' "prompt"

  # I4: prompt references .startup/ path check
  local prompt
  prompt=$(jq -r '.hooks.PostToolUse[0].hooks[0].prompt' "$hooks_file" 2>/dev/null)
  assert_output_contains "I4: prompt references .startup/ path check" "$prompt" ".startup/"

  # I5: prompt references ## Learnings section
  assert_output_contains "I5: prompt references Learnings section" "$prompt" "## Learnings"

  # I6: prompt contains duplicate-skip instruction
  assert_output_contains "I6: prompt contains duplicate-skip instruction" "$prompt" "semantically equivalent"
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
