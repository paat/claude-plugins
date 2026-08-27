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
  if grep -qF -- "$expected" <<< "$output"; then
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
  if grep -qF -- "$unexpected" <<< "$output"; then
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
# Helpers: exact lease fingerprints and temporary .startup/ fixtures
# ---------------------------------------------------------------------------

lease_state_fingerprint() {
  local state_file=$1 rows kind key state_dir owner_file slug artifact fingerprint rc=0
  rows=$(mktemp) || return 1
  if ! jq -er '.leases[] | [.kind,.key,.state_dir,.owner_file] | @tsv' \
    "$state_file" > "$rows"; then
    rm -f -- "$rows"
    return 1
  fi
  fingerprint=$(
    while IFS=$'\t' read -r kind key state_dir owner_file; do
      slug=$(printf '%s' "$key" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-')
      [ -n "$slug" ] || slug=lease
      for artifact in "$state_dir/$slug/heartbeat" "$state_dir/$slug/key" \
        "$state_dir/$slug/owner" "$state_dir/$slug/audit.log" \
        "$owner_file" "${owner_file}.key"; do
        [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1
        stat -c '%n\t%i\t%s\t%y\t%z' -- "$artifact"
        sha256sum -- "$artifact"
      done
    done < "$rows" | LC_ALL=C sort | sha256sum | awk '{print $1}'
  ) || rc=$?
  rm -f -- "$rows"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$fingerprint"
}

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
  echo -e "
${CYAN}Suite B: check-task-complete removed (#391)${NC}"
  assert_file_not_exists "B1: check-task-complete.sh removed" "$PLUGIN_ROOT/scripts/check-task-complete.sh"
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
  assert_output_contains "C1: shows no-session message" "$output" "No project artifacts found"
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
  assert_file_contains "D10c1: handoff names Done explicitly" \
    "$tmpl_dir/handoff-business-to-tech.md" "### Done / Feature Requirements"
  assert_file_contains "D10d: handoff declares preserved behavior" \
    "$tmpl_dir/handoff-business-to-tech.md" "### Preserve"
  assert_file_contains "D10e: handoff declares explicit exclusions" \
    "$tmpl_dir/handoff-business-to-tech.md" "### Out of Scope"
  assert_file_contains "D10f: return handoff quarantines adjacent findings" \
    "$tmpl_dir/handoff-tech-to-business.md" "### Not Addressed"
  assert_file_contains "D10g: Claude build role loads shared scope contract" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10g1: Claude architecture planning applies shared scope" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Before architecture planning or implementation"
  assert_file_contains "D10h: Claude maintenance role loads shared scope contract" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10h1: Claude maintenance planning applies shared scope" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Before architecture planning or implementation"
  assert_file_contains "D10i: Codex-native tech skill loads shared scope contract" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "../../templates/delivery-scope-contract.md"
  assert_file_contains "D10i1: Codex-native architecture planning applies shared scope" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Before architecture planning or implementation"
  assert_file_exists "D10j: Codex-native scope contract path resolves" \
    "$PLUGIN_ROOT/skills/tech-founder/../../templates/delivery-scope-contract.md"
  assert_file_contains "D10k: scope stop preserves required handoff" \
    "$tmpl_dir/delivery-scope-contract.md" "complete the required handoff or report, then exit"
  assert_file_contains "D10k1: shared scope requires a finished solo-founder product" \
    "$tmpl_dir/delivery-scope-contract.md" "finished production product operated by one founder"
  assert_file_contains "D10k2: KISS preserves product completeness" \
    "$tmpl_dir/delivery-scope-contract.md" "KISS trims operational complexity, never product completeness"
  assert_file_contains "D10k2a: shared scope rejects MVP delivery" \
    "$tmpl_dir/delivery-scope-contract.md" "never an MVP"
  assert_file_contains "D10k2b: enterprise exceptions allow preventive controls" \
    "$tmpl_dir/delivery-scope-contract.md" "concrete documented security, legal, reliability, or operability need"
  assert_file_contains "D10k3: Codex-native skill applies solo-founder KISS" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Solo-Founder KISS Rule"
  assert_file_contains "D10k4: architecture reference keeps solo-operator defaults" \
    "$PLUGIN_ROOT/references/tech-founder/architecture.md" \
    "one deployable application, one primary datastore"
  assert_file_contains "D10l: maintenance founder writes explicit brief scope" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" '`Done`, `Preserve`, and `Out of Scope`'
  assert_file_contains "D10m: Codex-native founder writes explicit brief scope" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" '`Done`, `Preserve`, and `Out of Scope`'
  assert_file_contains "D10n: quality gate distinguishes unrelated failures" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" \
    "Report unrelated or pre-existing failures as blockers"
  assert_file_exists "D10o: lean planning golden eval exists" \
    "$tmpl_dir/lean-planning-golden.md"
  assert_file_contains "D10o1: lean eval is a scheduled-report feature" \
    "$tmpl_dir/lean-planning-golden.md" "weekly internal operations report"
  assert_file_contains "D10o2: lean eval requires reuse-first planning" \
    "$tmpl_dir/lean-planning-golden.md" "Reuse the existing scheduled-job ritual"
  assert_file_contains "D10o3: lean eval needs no mandatory questions" \
    "$tmpl_dir/lean-planning-golden.md" "No mandatory user questions are needed"
  assert_file_exists "D10p0: planner-only scope file exists" \
    "$tmpl_dir/delivery-scope-planning.md"
  assert_file_contains "D10p: shared scope defines direct feature planning" \
    "$tmpl_dir/delivery-scope-planning.md" "# Direct Feature Planning"
  assert_file_contains "D10p1: shared scope defaults to one discovery pass" \
    "$tmpl_dir/delivery-scope-planning.md" "one targeted repository-discovery pass"
  assert_file_contains "D10p2: shared scope asks only material blockers" \
    "$tmpl_dir/delivery-scope-planning.md" "Ask only when a missing choice would materially change"
  assert_file_contains "D10p3: shared scope requires reuse before new machinery" \
    "$tmpl_dir/delivery-scope-planning.md" "scheduler, delivery framework, evidence store, or control plane"
  assert_file_contains "D10p4: shared scope bounds topic evidence" \
    "$tmpl_dir/delivery-scope-planning.md" "not a product-wide audit"
  assert_file_contains "D10p5: direct Why does not force new research" \
    "$tmpl_dir/delivery-scope-planning.md" "do not require a new research artifact"
  assert_file_contains "D10p6: implement contract omits planner-only Direct Feature Planning" \
    "$tmpl_dir/delivery-scope-contract.md" "Delivery Scope Contract"
  assert_file_not_contains "D10p7: implement contract has no Direct Feature Planning section" \
    "$tmpl_dir/delivery-scope-contract.md" "Direct Feature Planning"
  assert_file_contains "D10q: Claude business founder loads shared scope" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10q1: Claude maintenance founder loads shared scope" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10q2: Codex-native business skill loads shared scope" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "../../templates/delivery-scope-contract.md"
  assert_file_contains "D10q3: lifecycle scopes planning before discovery expansion" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "Skip broad market research"
  assert_file_contains "D10q4: goal delivery defaults to its primary planner" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" "Do not dispatch a planning role by default"
  assert_file_contains "D10q5: improve brief applies scope before research" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" "Before reading product or research docs, read and apply"
  assert_file_contains "D10q6: project guidance exposes lean direct planning" \
    "$tmpl_dir/claude-md-workflow-guidance.md" "Lean direct-feature planning"
  assert_file_contains "D10q6a: project guidance stops after file-only issue asks" \
    "$tmpl_dir/claude-md-workflow-guidance.md" "Do not auto-start delivery when filing issues"
  assert_file_exists "D10q6b: engineering principles template exists" \
    "$tmpl_dir/claude-md-engineering-principles.md"
  assert_file_contains "D10q6c: principles name KISS" \
    "$tmpl_dir/claude-md-engineering-principles.md" "**KISS**"
  assert_file_contains "D10q6d: principles name YAGNI" \
    "$tmpl_dir/claude-md-engineering-principles.md" "**YAGNI**"
  assert_file_contains "D10q6e: principles name DRY" \
    "$tmpl_dir/claude-md-engineering-principles.md" "**DRY**"
  assert_file_contains "D10q6f: bootstrap installs engineering principles" \
    "$PLUGIN_ROOT/skills/bootstrap/SKILL.md" "Engineering principles"
  assert_file_contains "D10q6g: bootstrap calls shared helper" \
    "$PLUGIN_ROOT/skills/bootstrap/SKILL.md" "scripts/ensure-engineering-principles.sh"
  assert_file_contains "D10q6h: lifecycle ensures engineering principles" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "ensure-engineering-principles.sh"
  assert_file_exists "D10q6i: ensure-engineering-principles script exists" \
    "$PLUGIN_ROOT/scripts/ensure-engineering-principles.sh"
  assert_file_contains "D10q6j: SessionStart hook ensures principles" \
    "$PLUGIN_ROOT/hooks/hooks.json" "ensure-engineering-principles.sh"
  assert_file_contains "D10q7: Claude tech gate points at brief acceptance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "D10q8: maintenance tech gate points at brief acceptance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "D10q9: Codex-native tech skill points at brief acceptance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "D10q9b: brief acceptance accepts direct request evidence" \
    "$PLUGIN_ROOT/references/brief-acceptance-gate.md" "does not require a new research document"
  assert_file_contains "D10q10: handoff template accepts direct request evidence" \
    "$tmpl_dir/handoff-business-to-tech.md" "For a direct feature"
  assert_file_contains "D10q11: delivery-scope planning accepts direct request evidence" \
    "$tmpl_dir/delivery-scope-planning.md" \
    "do not require a new research artifact"

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
  # Experimental Agent Teams disabled (#381): startup forbids TeamCreate; do not
  # enable a conflicting experimental team surface by default.
  assert_json_valid "E6: settings.json remains valid after team-flag removal" "$PLUGIN_ROOT/settings.json"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$PLUGIN_ROOT/settings.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} E6b: experimental agent teams must stay disabled"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("E6b: experimental agent teams must stay disabled")
  else
    echo -e "  ${GREEN}PASS${NC} E6b: experimental agent teams disabled"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi

  # E6a-E6b: Claude print mode must load the browser MCP before the first turn.
  assert_json_valid "E6a: .mcp.json is valid JSON" "$PLUGIN_ROOT/.mcp.json"
  # #391: unconditional alwaysLoad removed
  al=$(jq -r '.mcpServers.playwright.alwaysLoad // "absent"' "$PLUGIN_ROOT/.mcp.json")
  assert_equals "E6b: Playwright not alwaysLoad" "$al" "absent"

  # E7-E12: hooks.json
  assert_json_valid "E7: hooks.json is valid JSON" "$PLUGIN_ROOT/hooks/hooks.json"
  local hooks_keys
  hooks_keys=$(jq -r '.hooks | keys[]' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_contains "E8: hooks.json has PreToolUse" "$hooks_keys" "PreToolUse"
  assert_output_contains "E9: hooks.json has PostToolUse" "$hooks_keys" "PostToolUse"
  assert_output_not_contains "E10: hooks.json has no Stop (lifecycle #386)" "$hooks_keys" "Stop"
  assert_output_not_contains "E11: hooks.json omits Codex-unsupported TeammateIdle" "$hooks_keys" "TeammateIdle"
  assert_output_not_contains "E12: hooks.json omits Codex-unsupported TaskCompleted" "$hooks_keys" "TaskCompleted"

  # C-enforce: PreToolUse hooks/dispatch.sh is registered
  local enforce_cmd
  enforce_cmd=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$PLUGIN_ROOT/hooks/hooks.json" | grep -F "hooks/dispatch.sh" || true)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$enforce_cmd" ]; then
    echo -e "  ${GREEN}PASS${NC} C-enforce: PreToolUse hook registers hooks/dispatch.sh"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} C-enforce: PreToolUse hook does not register hooks/dispatch.sh"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("C-enforce: missing hooks/dispatch.sh in PreToolUse")
  fi

  # C-enforce-matcher: the entry uses matcher "Write"
  local enforce_matcher
  enforce_matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | test("hooks/dispatch.sh")) | select(.matcher | test("Write")) | .matcher // empty' "$PLUGIN_ROOT/hooks/hooks.json" | head -1)
  assert_output_contains "C-dispatch-matcher: Write matcher" "$enforce_matcher" "Write"
}

# ---------------------------------------------------------------------------
# Suite F: Stop Hook (check-stop.sh)
# ---------------------------------------------------------------------------

test_stop_hook() {
  echo -e "\n${CYAN}Suite F: Stop Hook removed (#386)${NC}"
  assert_file_not_exists "F1: check-stop.sh removed" "$PLUGIN_ROOT/scripts/check-stop.sh"
  assert_file_not_exists "F2: mark-yield.sh removed" "$PLUGIN_ROOT/scripts/mark-yield.sh"
  local hooks_blob
  hooks_blob=$(cat "$PLUGIN_ROOT/hooks/hooks.json")
  assert_output_not_contains "F3: hooks.json has no Stop entry" "$hooks_blob" '"Stop"'
  assert_output_not_contains "F4: hooks.json has no check-stop" "$hooks_blob" 'check-stop.sh'
  local post_matchers
  post_matchers=$(jq -r '.hooks.PostToolUse[]?.matcher // empty' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_not_contains "F5: PostToolUse omits ScheduleWakeup matcher" "$post_matchers" "ScheduleWakeup"
}


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
  "active_role": "product-discovery",
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
  assert_json_field "G10: active_role capability label" "$workdir/.startup/state.json" ".active_role" "product-discovery"
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

  # H3-H4: Capability skills replace founder personas (#385); nested Codex controllers removed (#387).
  assert_file_exists "H3: product-discovery skill" "$PLUGIN_ROOT/skills/product-discovery/SKILL.md"
  assert_file_exists "H4a: tech-founder standards skill" "$PLUGIN_ROOT/skills/tech-founder/SKILL.md"
  assert_file_not_exists "H4b: business-founder persona deleted" "$PLUGIN_ROOT/agents/business-founder.md"
  assert_file_not_exists "H4c: tech-founder-claude persona deleted" "$PLUGIN_ROOT/agents/tech-founder-claude.md"
  assert_file_not_exists "H4d: tech-founder-codex controller deleted" "$PLUGIN_ROOT/agents/tech-founder-codex.md"
  assert_file_exists "H4e: codex-cast adapter" "$PLUGIN_ROOT/scripts/codex-cast.sh"

  # H7: Template filenames match the patterns that scripts expect
  assert_file_exists "H7: handoff-business-to-tech template exists" \
    "$PLUGIN_ROOT/templates/handoff-business-to-tech.md"
  assert_file_exists "H8: handoff-tech-to-business template exists" \
    "$PLUGIN_ROOT/templates/handoff-tech-to-business.md"

  # H10-H11: Scripts are executable
  assert_file_not_exists "H10: check-task-complete.sh removed (#391)" "$PLUGIN_ROOT/scripts/check-task-complete.sh"

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
  assert_file_contains "H12: deliver skill does not require personas or state.json" \
    "$PLUGIN_ROOT/skills/deliver/SKILL.md" 'require founder personas'
  assert_file_contains "H13: /lawyer preflight" \
    "$PLUGIN_ROOT/skills/lawyer/SKILL.md" 'lawyer-preflight'
  assert_file_contains "H14: /ux-test loads ux-review" \
    "$PLUGIN_ROOT/commands/ux-test.md" 'skills/ux-review'
  assert_file_contains "H14a: ux-review browser evidence" \
    "$PLUGIN_ROOT/skills/ux-review/SKILL.md" 'Browser Evidence Contract'
  assert_file_contains "H14b: design-review leg ref" \
    "$PLUGIN_ROOT/skills/ux-review/SKILL.md" 'design-review-leg.md'
  assert_file_contains "H14c: post-deploy visual smoke" \
    "$PLUGIN_ROOT/skills/ux-review/SKILL.md" 'Post-deploy visual smoke'
  assert_file_contains "H14d: ux must not write product source" \
    "$PLUGIN_ROOT/skills/ux-review/SKILL.md" 'Must not write'
  assert_file_contains "H14e: direct UX baseline preserves the caller checkout" \
    "$PLUGIN_ROOT/references/ux-review/design-review-leg.md" 'never switch or'
  assert_file_contains "H15: /growth state update sets active_role" \
    "$PLUGIN_ROOT/skills/growth/SKILL.md" 'skills/growth'

  # H16-H17: Orchestrator is warned never to write active_role=team-lead.
  assert_file_contains "H16: lifecycle bans active_role" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" 'No `active_role`'
  assert_file_contains "H17: lifecycle bans state.json loop fields" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" 'state.json'

  # H18-H20: pause is legacy/optional; lifecycle cancels via lease release (#386).
  assert_file_exists "H18: /pause command exists" "$PLUGIN_ROOT/skills/pause/SKILL.md"
  assert_file_contains "H18b: /pause parks human work" \
    "$PLUGIN_ROOT/skills/pause/SKILL.md" 'human-tasks.md'
  assert_file_contains "H19: lifecycle documents cancellation" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" '`cancelled`'
  assert_file_contains "H20: lifecycle releases lease on cancel/fail" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" '--release'
}

# ---------------------------------------------------------------------------
# Suite I: PostToolUse Hook
# ---------------------------------------------------------------------------

test_post_tool_use_hook() {
  echo -e "\n${CYAN}Suite I: PostToolUse dispatcher (#391)${NC}"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
  assert_json_valid "I1: hooks.json valid" "$hooks_file"
  local ptu
  ptu=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$hooks_file")
  assert_output_contains "I2: PostToolUse uses dispatch" "$ptu" "dispatch.sh"
  assert_file_not_exists "I3: auto-commit gone" "$PLUGIN_ROOT/scripts/auto-commit.sh"
  # dispatcher drains stdin
  ec=0
  dd if=/dev/zero bs=1024 count=64 2>/dev/null | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/hooks/dispatch.sh" post-write >/dev/null 2>&1 || ec=$?
  assert_exit_code "I4: dispatch post-write drains large stdin" "$ec" 0
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
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [[ ! -f "$PLUGIN_ROOT/PLUGIN_ISSUES.md" ]]; then
    echo -e "  ${GREEN}PASS${NC} J1: PLUGIN_ISSUES.md removed from plugin root"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} J1: PLUGIN_ISSUES.md still exists at plugin root"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("J1: PLUGIN_ISSUES.md still exists at plugin root")
  fi

  # J2-J5: the shared reference routes through the dry-funnel filing helper; remaining
  # agents point at that reference (stated once, referenced elsewhere).
  assert_file_contains "J-gh-ref: reference files through the issue funnel" \
    "$PLUGIN_ROOT/templates/plugin-issue-reporting.md" 'scripts/issue-file.sh'
  assert_file_contains "J-gh-ref: issue funnel receives the pinned repo" \
    "$PLUGIN_ROOT/templates/plugin-issue-reporting.md" '--repo "${SAAS_PLUGIN_REPO}"'
  for agent in lawyer.md; do
    assert_file_contains "J-gh: $agent references the plugin-issue-reporting doc" \
      "$PLUGIN_ROOT/agents/$agent" "templates/plugin-issue-reporting.md"
  done

  # J-bootstrap: bootstrap no longer seeds .startup/PLUGIN_ISSUES.md
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if ! grep -q "PLUGIN_ISSUES" "$PLUGIN_ROOT/skills/bootstrap/SKILL.md"; then
    echo -e "  ${GREEN}PASS${NC} J-bootstrap: bootstrap skill no longer seeds PLUGIN_ISSUES.md"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} J-bootstrap: bootstrap skill still references PLUGIN_ISSUES"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("J-bootstrap: bootstrap skill still references PLUGIN_ISSUES")
  fi

  # J-startup: startup no longer seeds .startup/PLUGIN_ISSUES.md either
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if ! grep -q "PLUGIN_ISSUES" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md"; then
    echo -e "  ${GREEN}PASS${NC} J-startup: startup.md no longer seeds PLUGIN_ISSUES.md"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} J-startup: startup.md still references PLUGIN_ISSUES"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("J-startup: startup.md still references PLUGIN_ISSUES")
  fi
}

# ---------------------------------------------------------------------------
# Suite K: /maintain command
# ---------------------------------------------------------------------------

test_maintain() {
  echo -e "\n${CYAN}== /maintain command (v3 + legacy-drain) ==${NC}"
  local cmd="$PLUGIN_ROOT/references/workflows/maintain.md"
  local entry="$PLUGIN_ROOT/commands/maintain.md"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local drain="$PLUGIN_ROOT/scripts/legacy-drain.sh"
  local skill="$PLUGIN_ROOT/skills/maintain/SKILL.md"
  local contract="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  local goal="$PLUGIN_ROOT/references/delivery-playbook.md"
  local codex_cmd="$PLUGIN_ROOT/skills/saas-startup-team-maintain-workflow/SKILL.md"

  assert_file_exists "M1: maintain.md exists" "$cmd"
  assert_file_exists "M2: maintain-v3 engine" "$v3"
  assert_file_exists "M3: legacy-drain" "$drain"
  assert_file_exists "M4: maintain skill" "$skill"
  assert_file_exists "M5: maintain command" "$entry"
  assert_file_contains "M6: command loads skill" "$entry" 'skills/maintain'
  assert_file_contains "M7: shadow default" "$skill" '--shadow'
  assert_file_contains "M8: no claims" "$skill" 'No claims'
  assert_file_contains "M9: short locks" "$contract" 'scheduler'
  assert_file_contains "M10: worktree preferred" "$contract" 'git worktree'
  assert_file_contains "M11: no primary reset on cancel" "$contract" 'never hard-reset'
  assert_file_contains "M12: tribunal hard dep" "$goal" "tribunal-review"
  assert_file_contains "M13: human-tasks for unresolved" "$cmd" "human-tasks.md"
  assert_file_contains "M14: legacy drain inventory" "$cmd" "legacy-drain.sh"
  assert_file_contains "M15: source intact until verify" "$cmd" "stay intact until verify"
  assert_file_not_contains "M16: no maintain-leases on normal path" "$cmd" "maintain-leases.sh"
  assert_file_not_contains "M17: no single-flight on normal path" "$cmd" "single-flight.sh"
  assert_file_not_contains "M18: no lease-guardian" "$cmd" "lease-guardian.sh"
  assert_file_not_exists "M19: maintain-delivery deleted" "$PLUGIN_ROOT/scripts/maintain-delivery.sh"
  assert_file_not_exists "M20: maintain-leases deleted" "$PLUGIN_ROOT/scripts/maintain-leases.sh"
  assert_file_not_exists "M21: single-flight deleted" "$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_not_exists "M22: lease-guardian deleted" "$PLUGIN_ROOT/scripts/lease-guardian.sh"
  assert_file_not_exists "M23: maintain-attempt deleted" "$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  assert_file_not_exists "M24: maintain-self-heal deleted" "$PLUGIN_ROOT/scripts/maintain-self-heal.sh"
  assert_file_not_exists "M25: maintain-escalation deleted" "$PLUGIN_ROOT/scripts/maintain-escalation.sh"
  assert_file_not_exists "M26: trace-containment deleted" "$PLUGIN_ROOT/scripts/trace-containment.py"
  assert_file_exists "M27: Codex maintain workflow exists" "$codex_cmd"
  assert_file_contains "M28: maintain uses queue builder" "$PLUGIN_ROOT/scripts/maintain-v3.sh" "maintain-queue.sh"
  assert_file_contains "M29: WIP-first" "$contract" "WIP"
  assert_file_contains "M30: release-facts" "$contract" "release-facts"
  assert_file_contains "M31: empty claims array" "$v3" 'claims:\[\]'
  assert_file_contains "M32: only three lock kinds" "$v3" 'scheduler|issue|release'
  assert_file_contains "M45a41: WIP-first contract rejects claim ownership" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" 'claim comments as ownership'
  assert_file_contains "M45a42: auto-merge when gates pass" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" 'exact-head merge'
  assert_file_contains "M45a10: resume re-proves current-head gates" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" \
    'Do not trust an earlier green check'
  assert_file_contains "M45a11: resume never creates a replacement PR" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" \
    'Never open a replacement PR'
  assert_file_contains "M45a27: active merge atomically pins the reviewed PR head" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" \
    'gh pr merge --match-head-commit'

  # Queue builder regression: no-dependency issues must survive dependency parsing.
  local queue_script issues_file prs_file resume_candidate_file race_issues_file race_prs_file blocked_file active_blocked_file expired_blocked_file legacy_blocked_file bad_blocked_file bad_blocked_err dep_issues_file dep_status_file serial_dep_issues_file serial_dep_status_file closed_issues_file fake_bin live_out repo_live_out closed_status closed_err missing_status missing_err fixture_closed_status fixture_closed_err zero_status zero_err bad_blocked_status resume_status out race_out filtered single_issue cooled active_blocked expired_blocked dual_blocked dep_out serial_dep_out queue_numbers live_repo gh_calls unbound_dir unbound_status unbound_err
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
  },
  {
    "number": 112,
    "title": "Linked by GitHub closing reference",
    "body": "No dependency markers.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-11T00:00:00Z",
    "updatedAt": "2026-01-11T00:00:00Z"
  },
  {
    "number": 113,
    "state": "OPEN",
    "title": "Claimed PR interrupted after push",
    "body": "Resume the existing delivery.",
    "labels": [{"name": "maintain:claimed"}, {"name": "high"}],
    "assignees": [],
    "closedByPullRequestsReferences": [],
    "createdAt": "2026-01-12T00:00:00Z",
    "updatedAt": "2026-01-12T00:00:00Z"
  },
  {
    "number": 114,
    "title": "Ambiguous claimed PRs",
    "body": "Two PRs claim this issue.",
    "labels": [{"name": "maintain:claimed"}],
    "createdAt": "2026-01-13T00:00:00Z",
    "updatedAt": "2026-01-13T00:00:00Z"
  },
  {
    "number": 115,
    "title": "Claimed PR needs a human",
    "body": "Do not resume automatically.",
    "labels": [{"name": "maintain:claimed"}, {"name": "needs-human"}],
    "createdAt": "2026-01-14T00:00:00Z",
    "updatedAt": "2026-01-14T00:00:00Z"
  },
  {
    "number": 116,
    "title": "Claimed PR waits for dependency",
    "body": "Blocked by #101.",
    "labels": [{"name": "maintain:claimed"}],
    "createdAt": "2026-01-15T00:00:00Z",
    "updatedAt": "2026-01-15T00:00:00Z"
  }
]
JSON
  cat > "$prs_file" <<'JSON'
[
  {
    "number": 20,
    "title": "Fix linked issue",
    "body": "Closes #103",
    "closingIssuesReferences": []
  },
  {
    "number": 21,
    "title": "WIP for #109",
    "body": "Implementation notes only; no closing keyword.",
    "closingIssuesReferences": []
  },
  {
    "number": 22,
    "title": "Fix through GitHub reference",
    "body": "No textual issue reference.",
    "closingIssuesReferences": [{"number": 112}]
  },
  {
    "number": 23,
    "title": "Resume claimed work",
    "body": "Fixes #113",
    "closingIssuesReferences": []
  },
  {
    "number": 24,
    "title": "First ambiguous claim",
    "body": "Fixes #114",
    "closingIssuesReferences": []
  },
  {
    "number": 25,
    "title": "Second ambiguous claim",
    "body": "Resolves #114",
    "closingIssuesReferences": []
  },
  {
    "number": 26,
    "title": "Human-gated claim",
    "body": "Fixes #115",
    "closingIssuesReferences": []
  },
  {
    "number": 27,
    "title": "Dependency-gated claim",
    "body": "Fixes #116",
    "closingIssuesReferences": []
  }
]
JSON
  out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file")
  queue_numbers=$(jq -r '.queue[].number' <<<"$out")
  assert_equals "M45c: queue preserves no-dependency issues and orders by severity" \
    "$queue_numbers" $'102\n109\n110\n111\n108\n101\n106'
  assert_equals "M45d: no-dependency issue has empty deps" \
    "$(jq -r '.queue[] | select(.number == 101) | (.deps | length)' <<<"$out")" "0"
  assert_equals "M45e: explicit closing keyword makes open PR resumable (no claim needed)" \
    "$(jq -r '.resumable[] | select(.number == 103) | .pr_number' <<<"$out")" "20"
  assert_equals "M45e1: GitHub closing reference makes open PR resumable" \
    "$(jq -r '.resumable[] | select(.number == 112) | .pr_number' <<<"$out")" "22"
  assert_equals "M45e2: bare open PR mention remains eligible" \
    "$(jq -r '.queue | map(.number) | index(109) != null' <<<"$out")" "true"
  assert_equals "M45e3: bare open PR mention is not a linked PR" \
    "$(jq -r '.excluded.linked_pr | index(109) == null' <<<"$out")" "true"
  assert_equals "M45e4: one linked PR is resumable without requiring claim label" \
    "$(jq -r '.resumable[] | select(.number == 113) | .pr_number' <<<"$out")" "23"
  assert_equals "M45e4a: resumable row retains the triaged issue version" \
    "$(jq -r '.resumable[] | select(.number == 113) | .updatedAt' <<<"$out")" \
    "2026-01-12T00:00:00Z"
  assert_equals "M45e5: resumable work is not also excluded" \
    "$(jq -r '.excluded.linked_pr | index(113) == null' <<<"$out")" "true"
  resume_candidate_file="$workdir/resume-candidate.json"
  jq '.resumable[] | select(.number == 113)' <<<"$out" > "$resume_candidate_file"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file") || resume_status=$?
  assert_exit_code "M45e5a: exact unchanged resume candidate passes its live guard" \
    "$resume_status" 0
  assert_equals "M45e5b: successful guard returns the exact queued PR" \
    "$(jq -r .pr_number <<<"$race_out")" "23"
  assert_equals "M45e6: unclaimed linked PR is resumable (WIP-first, no claims)" \
    "$(jq -r '.resumable | map(.number) | index(103) != null' <<<"$out")" "true"
  assert_equals "M45e7: multiple claimed PRs fail closed as ambiguous" \
    "$(jq -r '.excluded.linked_pr | index(114) != null' <<<"$out")" "true"
  assert_equals "M45e8: needs-human still excludes a claimed PR" \
    "$(jq -r '.excluded.needs_human | index(115) != null' <<<"$out")" "true"
  assert_equals "M45e9: claimed PR waits for unmet dependencies" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 116) | (.deps | join(","))' <<<"$out")" "101"
  race_issues_file="$workdir/race-issues.json"
  jq 'map(if .number == 113 then
      .updatedAt = "2026-01-16T00:00:00Z"
    else . end)' "$issues_file" > "$race_issues_file"
  resume_status=0
  bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e10: changed issue version fails the exact resume guard" \
    "$resume_status" 3
  jq 'map(if .number == 113 then
      .assignees = [{"login":"investor"}]
    else . end)' "$issues_file" > "$race_issues_file"
  race_out=$(bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file")
  assert_equals "M45e11a: rebuilt queue explicitly excludes assigned work" \
    "$(jq -r '.excluded.assigned | index(113) != null' <<<"$race_out")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e11: later assignment fails the exact resume guard" \
    "$resume_status" 3
  jq 'map(if .number == 113 then
      .updatedAt = "2026-01-16T00:00:00Z"
      | .labels += [{"name":"needs-human"}]
    else . end)' "$issues_file" > "$race_issues_file"
  race_out=$(bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file")
  assert_equals "M45e12: later needs-human drift removes a resumable candidate" \
    "$(jq -r '.resumable | map(.number) | index(113) == null' <<<"$race_out")" "true"
  assert_equals "M45e13: rebuilt queue parks the drifted candidate" \
    "$(jq -r '.excluded.needs_human | index(113) != null' <<<"$race_out")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e14: later needs-human drift fails the exact resume guard" \
    "$resume_status" 3
  race_prs_file="$workdir/race-prs.json"
  jq '. + [{"number":28,"title":"Competing claim","body":"Fixes #113","closingIssuesReferences":[]}]' \
    "$prs_file" > "$race_prs_file"
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$race_prs_file")
  assert_equals "M45e15: later second linked PR invalidates resumable identity" \
    "$(jq -r '.resumable | map(.number) | index(113) == null' <<<"$race_out")" "true"
  assert_equals "M45e16: ambiguous replacement stays excluded" \
    "$(jq -r '.excluded.linked_pr | index(113) != null' <<<"$race_out")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$race_prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e17: later second linked PR fails the exact resume guard" \
    "$resume_status" 3
  jq 'map(if .number == 113 then .assignees = "invalid" else . end)' \
    "$issues_file" > "$race_issues_file"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" 2>&1) || resume_status=$?
  assert_exit_code "M45e18: malformed live assignees fail the resume guard" \
    "$resume_status" 3
  assert_output_contains "M45e19: malformed issue data has a precise guard diagnostic" \
    "$race_out" 'live resume issue data is malformed'
  jq 'map(if .number == 23 then .closingIssuesReferences = "invalid" else . end)' \
    "$prs_file" > "$race_prs_file"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$race_prs_file" \
    --resume-candidate-file "$resume_candidate_file" 2>&1) || resume_status=$?
  assert_exit_code "M45e20: malformed live PR schema fails the resume guard" \
    "$resume_status" 3
  assert_output_contains "M45e21: malformed PR data has a precise guard diagnostic" \
    "$race_out" 'live resume PR data is malformed'
  printf '%s\n' '{"number":113,"updatedAt":7,"pr_number":23}' \
    > "$workdir/malformed-resume-candidate.json"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$workdir/malformed-resume-candidate.json" 2>&1) || resume_status=$?
  assert_exit_code "M45e22: malformed candidate schema fails closed" "$resume_status" 3
  assert_output_contains "M45e23: malformed candidate has a precise diagnostic" \
    "$race_out" 'resume candidate is malformed'
  assert_equals "M45f: explicit dependencies defer dependent issue" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 104) | (.deps | join(","))' <<<"$out")" "101,102"
  assert_equals "M45g: needs-human label is excluded" \
    "$(jq -r '.excluded.needs_human | index(105) != null' <<<"$out")" "true"
  assert_equals "M45h: blocked label without durable cooldown remains eligible" \
    "$(jq -r '.queue | map(.number) | index(106) != null' <<<"$out")" "true"
  assert_equals "M45h1: blocked label without durable cooldown requests cleanup" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) != null' <<<"$out")" "true"
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
  printf '%s\n' \
    '{"number":101,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' \
    '{"number":113,"reason":"resume race","cooldown_until":"2099-01-01T00:00:00Z"}' \
    > "$blocked_file"
  cooled=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$blocked_file")
  assert_equals "M45n: blocked-file cooldown excludes issue" \
    "$(jq -r '.excluded.cooldown | index(101) != null' <<<"$cooled")" "true"
  assert_equals "M45n0a: later cooldown removes a resumable candidate" \
    "$(jq -r '.resumable | map(.number) | index(113) == null' <<<"$cooled")" "true"
  assert_equals "M45n0b: rebuilt queue records the resumable cooldown" \
    "$(jq -r '.excluded.cooldown | index(113) != null' <<<"$cooled")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$blocked_file" --resume-candidate-file "$resume_candidate_file" \
    >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45n0c: later cooldown fails the exact resume guard" \
    "$resume_status" 3
  active_blocked_file="$workdir/active-blocked.jsonl"
  printf '%s\n' '{"number":106,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' > "$active_blocked_file"
  active_blocked=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$active_blocked_file")
  assert_equals "M45n1: active durable cooldown excludes blocked-labelled issue" \
    "$(jq -r '.excluded.cooldown | index(106) != null' <<<"$active_blocked")" "true"
  assert_equals "M45n2: active blocked label is not stale" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) == null' <<<"$active_blocked")" "true"
  expired_blocked_file="$workdir/expired-blocked.jsonl"
  printf '%s\n' '{"number":106,"reason":"cooldown","cooldown_until":"2026-01-01T00:00:00Z"}' > "$expired_blocked_file"
  expired_blocked=$(MAINTAIN_QUEUE_NOW=2026-01-02T00:00:00Z bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$expired_blocked_file")
  assert_equals "M45n3: expired durable cooldown restores eligibility" \
    "$(jq -r '.queue | map(.number) | index(106) != null' <<<"$expired_blocked")" "true"
  assert_equals "M45n4: expired durable cooldown requests blocked-label cleanup" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) != null' <<<"$expired_blocked")" "true"
  legacy_blocked_file="$workdir/legacy-blocked.jsonl"
  printf '%s\n' '{"number":106,"reason":"legacy cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' > "$legacy_blocked_file"
  dual_blocked=$(MAINTAIN_QUEUE_NOW=2026-01-02T00:00:00Z bash "$queue_script" \
    --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$expired_blocked_file" --blocked-file "$legacy_blocked_file")
  assert_equals "M45n5: active legacy cooldown survives dual-read migration" \
    "$(jq -r '.excluded.cooldown | index(106) != null' <<<"$dual_blocked")" "true"
  assert_equals "M45n6: active legacy cooldown prevents stale-label cleanup" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) == null' <<<"$dual_blocked")" "true"
  bad_blocked_file="$workdir/bad-blocked.jsonl"
  bad_blocked_err="$workdir/bad-blocked.err"
  printf '%s\n' '{"number":101,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' 'not-json' > "$bad_blocked_file"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$bad_blocked_file" > /dev/null 2> "$bad_blocked_err"
  bad_blocked_status=$?
  set -e
  assert_exit_code "M45n7: malformed blocked-file fails loudly" "$bad_blocked_status" 3
  assert_file_contains "M45n8: malformed blocked-file names file" "$bad_blocked_err" "invalid blocked file: $bad_blocked_file"
  printf '%s\n' '{"number":101,"cooldown_until":"2099-01-01T00:00:00Z"}' > "$bad_blocked_file"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$bad_blocked_file" > /dev/null 2> "$bad_blocked_err"
  bad_blocked_status=$?
  set -e
  assert_exit_code "M45n9: parseable but invalid cooldown schema fails before queue cleanup" \
    "$bad_blocked_status" 3
  resume_status=0
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$bad_blocked_file" --resume-candidate-file "$resume_candidate_file" \
    >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45n9a: malformed cooldown also fails the exact resume guard" \
    "$resume_status" 3
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
for name in GH_REPO GH_HOST GH_CONFIG_DIR; do
  [ "${!name+x}" != x ] || { printf 'poisoned queue gh environment: %s\n' "$name" >&2; exit 90; }
done
printf '%s\n' "$*" >> "$GH_QUEUE_CALLS"
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
  chmod 755 "$fake_bin/gh"
  live_repo="$workdir/live-repo"; gh_calls="$workdir/queue-gh-calls"
  unbound_dir="$workdir/unbound"; unbound_err="$workdir/unbound.err"; mkdir "$unbound_dir"
  : > "$gh_calls"; unbound_status=0
  (cd "$unbound_dir" && GH_QUEUE_CALLS="$gh_calls" PATH="$fake_bin:$PATH" \
    bash "$queue_script" > /dev/null 2> "$unbound_err") || unbound_status=$?
  assert_exit_code "M45o3: an implicit live query without canonical origin fails closed" \
    "$unbound_status" 3
  assert_file_contains "M45o4: unbound live query requests an explicit repository" \
    "$unbound_err" 'pass --repo OWNER/REPO'
  assert_equals "M45o5: repository resolution fails before any gh query" \
    "$(wc -l < "$gh_calls" | tr -d ' ')" 0
  git -C "$workdir" init -q -b main live-repo
  git -C "$live_repo" remote add origin git@github.com:owner/implicit-repo.git
  live_out=$(cd "$live_repo" && GH_QUEUE_CALLS="$gh_calls" GH_REPO=attacker/wrong \
    GH_HOST=attacker.invalid GH_CONFIG_DIR="$workdir/attacker-config" \
    PATH="$fake_bin:$PATH" bash "$queue_script")
  assert_equals "M45p: live gh dependency lookup marks closed PR-backed prerequisite satisfied" \
    "$(jq -r '.queue[].number' <<<"$live_out")" "201"
  assert_equals "M45p1: implicit live queries bind every gh call to canonical remote.origin" \
    "$(awk '$1=="repo" && $2=="view" {if ($3!="owner/implicit-repo") bad=1; next}
      index($0,"--repo github.com/owner/implicit-repo")==0 {bad=1}
      END {print (NR>0 && !bad ? "true" : "false")}' "$gh_calls")" true
  : > "$gh_calls"
  repo_live_out=$(GH_QUEUE_CALLS="$gh_calls" GH_REPO=attacker/wrong GH_HOST=attacker.invalid \
    PATH="$fake_bin:$PATH" bash "$queue_script" --repo owner/repo)
  assert_equals "M45p2: live --repo default-branch lookup uses gh repo view owner/repo" \
    "$(jq -r '.queue[].number' <<<"$repo_live_out")" "201"
  assert_equals "M45p3: explicit live queries bind every gh call to --repo" \
    "$(awk '$1=="repo" && $2=="view" {if ($3!="owner/repo") bad=1; next}
      index($0,"--repo github.com/owner/repo")==0 {bad=1}
      END {print (NR>0 && !bad ? "true" : "false")}' "$gh_calls")" true
  closed_err="$workdir/closed.err"
  set +e
  GH_QUEUE_CALLS="$gh_calls" PATH="$fake_bin:$PATH" bash "$queue_script" \
    --repo owner/repo --issue 202 > /dev/null 2> "$closed_err"
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
  local command="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  local cmd_alias="$PLUGIN_ROOT/commands/maintain-loop.md"
  local coordinator="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local codex_cmd="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  local old_codex_cmd="$PLUGIN_ROOT/skills/saas-startup-team-maintain-loop-workflow/SKILL.md"

  assert_file_exists "ML1: maintain-loop command exists" "$cmd_alias"
  assert_file_contains "ML2: command is user invocable" "$cmd_alias" "user_invocable: true"
  assert_file_contains "ML3: concise Codex skill name" "$command" "name: maintain-loop"
  assert_file_exists "ML3b: maintain-v3 engine exists" "$v3"
  assert_file_contains "ML4: parent stays context-thin" "$command" "never read issue bodies"
  assert_file_contains "ML5: parent probes maintain model-free" "$command" 'workflow-probe.sh maintain'
  assert_file_not_contains "ML6: old maintain-loop probe is unused" "$command" \
    'workflow-probe.sh maintain-loop'
  assert_file_contains "ML7: each child runs a bounded maintain pass" "$command" \
    '/saas-startup-team:maintain --once'
  assert_file_contains "ML7b: v3 tick preferred" "$command" 'maintain-v3.sh'
  assert_file_contains "ML8: maintain keeps its own policy" "$command" \
    'Normal triage, ordering, batching, limits, implementation'
  assert_file_contains "ML9: dispatch is exactly one fresh subagent" "$command" \
    'launch exactly one fresh isolated subagent'
  assert_file_contains "ML10: passes are sequential" "$command" \
    'never run two passes concurrently'
  assert_file_contains "ML10a: coordinator forbids noisy wait polling" "$command" \
    'Empty timeouts are not progress'
  assert_file_contains "ML10b: empty waits do not produce status noise" "$command" \
    'or immediately retry them'
  assert_file_contains "ML11: completed subagents are not reused" "$command" \
    'Completed subagent'
  assert_file_contains "ML12: inline fallback is forbidden" "$command" \
    'no inline as a fallback'
  assert_file_contains "ML13: result is compact" "$command" \
    "Keep only the child's compact terminal result"
  assert_file_contains "ML14: no-work exits before dispatch" "$coordinator" \
    'exit 3 is `no-op`'
  assert_file_contains "ML15: outer once bounds child count" "$coordinator" \
    '`--once` launches at most one child'
  assert_file_contains "ML16: dry-run is bounded" "$command" '--dry-run'
  if [ -f "$codex_cmd" ]; then
    assert_file_contains "ML19: Codex requires fresh subagent" "$codex_cmd" \
      'fresh Codex subagents'
  fi
  assert_file_exists "ML30: generated Codex maintain workflow alias exists" \
    "$PLUGIN_ROOT/skills/saas-startup-team-maintain-workflow/SKILL.md"
  assert_file_exists "ML30b: maintain-loop skill exists" "$codex_cmd"
}




test_auto_commit_hook() {
  echo -e "\n${CYAN}Suite K: Auto-Commit removed (#391)${NC}"
  assert_file_not_exists "K1: auto-commit.sh removed" "$PLUGIN_ROOT/scripts/auto-commit.sh"
  assert_file_not_exists "K2: auto-commit-growth.sh removed" "$PLUGIN_ROOT/scripts/auto-commit-growth.sh"
  local ptu_count
  ptu_count=$(jq '.hooks.PostToolUse | length' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_equals "K7: PostToolUse has 1 dispatcher entry" "$ptu_count" "1"
  local cmd
  cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_contains "K8: PostToolUse uses dispatch.sh" "$cmd" "dispatch.sh"
  # Hooks must never commit
  assert_file_not_contains "K13: dispatch never git commits" "$PLUGIN_ROOT/hooks/dispatch.sh" "git commit"
  assert_file_not_contains "K13b: gate never git commits" "$PLUGIN_ROOT/scripts/gate.sh" "git commit"
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
  local bootstrap="$PLUGIN_ROOT/skills/bootstrap/SKILL.md"
  local gitignore_block="$PLUGIN_ROOT/templates/gitignore-block.txt"
  assert_file_contains "G8-ref: bootstrap applies the gitignore block" "$bootstrap" "templates/gitignore-block.txt"
  assert_file_contains "G8a: gitignore block has node_modules/" "$gitignore_block" "node_modules/"
  assert_file_contains "G8b: gitignore block has .pnpm-store/" "$gitignore_block" ".pnpm-store/"
  assert_file_contains "G8c: gitignore block has build output (dist/)" "$gitignore_block" "dist/"

  # G9: the guard is wired into the bootstrap commit and the /improve catch-all commit
  assert_file_contains "G9a: bootstrap runs the guard before commit" "$bootstrap" "check-staged-size.sh"
  assert_file_contains "G9b: improve uses supervisor commit guard" "$PLUGIN_ROOT/references/delivery-playbook.md" "supervisor-commit.sh"
  assert_file_contains "G9c: tweak uses trapped commit guard" "$PLUGIN_ROOT/references/delivery-playbook.md" "tweak-run.sh"
  assert_file_contains "G9d: lifecycle ensures engineering principles" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "ensure-engineering-principles.sh"

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

  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'candidate\n' > "$workdir/README.md"; git -C "$workdir" add README.md
  fake_bin="$workdir/fake-bin"; mkdir "$fake_bin"; real_git=$(command -v git)
  cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
is_diff=0; is_cached=0; is_names=0; is_z=0
for arg in "$@"; do
  [ "$arg" != diff ] || is_diff=1
  [ "$arg" != --cached ] || is_cached=1
  [ "$arg" != --name-only ] || is_names=1
  [ "$arg" != -z ] || is_z=1
done
if [ "$is_diff$is_cached$is_names$is_z" = 1111 ]; then
  printf 'README.md\0'
  exit 73
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  ec=0; output=$(cd "$workdir" && REAL_GIT="$real_git" PATH="$fake_bin:$PATH" \
    bash "$script" 2>&1) || ec=$?
  assert_exit_code "G11: partial staged inventory fails closed" "$ec" 1
  assert_output_contains "G11a: staged inventory failure is explicit" "$output" \
    'Cannot inspect the staged path inventory'
  assert_file_not_contains "G11b: staged inventory avoids process-substitution status loss" \
    "$script" 'done < <(git diff'
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite L: Tone Enforcement Hook
# ---------------------------------------------------------------------------

test_tone_enforcement_hook() {
  echo -e "\n${CYAN}Suite: enforce-tone removed (#391)${NC}"
  assert_file_not_exists "tone: script removed" "$PLUGIN_ROOT/scripts/enforce-tone.sh"
}

# ---------------------------------------------------------------------------
# Suite M: JSON Validation Hook
# ---------------------------------------------------------------------------

test_json_validation_hook() {
  echo -e "\n${CYAN}Suite M: JSON Validation Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/validate-json.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # M1: dispatch.sh exists
  assert_file_exists "M1: validate-json.sh exists" "$script"

  # M2: dispatch.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} M2: dispatch.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} M2: dispatch.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("M2: dispatch.sh is not executable")
  fi

  # M3: hooks.json references dispatch.sh
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "M3: hooks.json references dispatch.sh" "$hook_refs" "dispatch.sh"

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
  echo -e "\n${CYAN}Suite: enforce-delegation removed (#391)${NC}"
  assert_file_not_exists "delegation: script removed" "$PLUGIN_ROOT/scripts/enforce-delegation.sh"
}

# ---------------------------------------------------------------------------
# Suite O: Duplicate Handoff Prevention Hook
# ---------------------------------------------------------------------------

test_duplicate_handoff_hook() {
  echo -e "\n${CYAN}Suite: check-duplicate-handoff removed (#391)${NC}"
  assert_file_not_exists "dup: script removed" "$PLUGIN_ROOT/scripts/check-duplicate-handoff.sh"
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
  echo -e "\n${CYAN}Suite P: compact-state.sh removed (#386)${NC}"
  assert_file_not_exists "P1: compact-state.sh removed" "$PLUGIN_ROOT/scripts/compact-state.sh"
}


test_migrate_state() {
  echo -e "\n${CYAN}Suite Q: migrate-state.sh removed (#386)${NC}"
  assert_file_not_exists "Q1: migrate-state.sh removed" "$PLUGIN_ROOT/scripts/migrate-state.sh"
}


test_enforce_handoff_naming_hook() {
  echo -e "\n${CYAN}Suite R: handoff naming hook removed (#391)${NC}"
  assert_file_not_exists "R1: hooks/dispatch.sh removed" "$PLUGIN_ROOT/scripts/hooks/dispatch.sh"
  assert_file_exists "R2: dispatch.sh present" "$PLUGIN_ROOT/hooks/dispatch.sh"
  assert_file_exists "R3: gate.sh present" "$PLUGIN_ROOT/scripts/gate.sh"
}

# ---------------------------------------------------------------------------
# Suite S: Migrate Handoff Names (migrate-handoff-names.sh)
# ---------------------------------------------------------------------------

test_migrate_handoff_names() {
  echo -e "\n${CYAN}Suite: handoff migration removed (#391)${NC}"
  assert_file_not_exists "migrate: enforce-handoff removed" "$PLUGIN_ROOT/scripts/enforce-handoff-naming.sh"
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
  local cmd="$PLUGIN_ROOT/skills/bootstrap/SKILL.md"
  local workdir ec output

  # Scaffold lives in scripts/bootstrap-scaffold.sh (#391)
  local script
  workdir=$(mktemp -d)
  cp "$PLUGIN_ROOT/scripts/bootstrap-scaffold.sh" "$workdir/scaffold.sh"
  chmod +x "$workdir/scaffold.sh"

  # X1: the script is non-empty
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
  assert_equals "X20: scaffold script has no markdown fences" "$fence_cnt" "0"

  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite Y: canonical entrypoint wiring (plugin-self drift guard)
# ---------------------------------------------------------------------------

test_canonical_entrypoint_wiring() {
  echo -e "\n${CYAN}Suite Y: canonical entrypoint wiring${NC}"
  assert_file_contains "Y1: improve.md names check.sh" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" "check.sh"
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
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" "Single source of truth"
  assert_file_contains "Y9: quality-standards warns about re-derived rules" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" "re-derive"
  assert_file_contains "Y10: maintain agent has independent spot-check" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "independent source"
  assert_file_contains "Y11: build agent has independent spot-check" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "independent source"
  assert_file_contains "Y12: maintain agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "another layer"
  assert_file_contains "Y13: build agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "another layer"
  assert_file_contains "Y14: quality-standards handoff checklist names check.sh" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" "check.sh"
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

  local cmd="$PLUGIN_ROOT/skills/monitor-nightly/SKILL.md"
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
  assert_file_exists "Y1: /operate command exists" "$PLUGIN_ROOT/skills/operate/SKILL.md"
  assert_file_exists "Y2: /monitor command exists" "$PLUGIN_ROOT/skills/operate/SKILL.md"
  assert_file_exists "Y3: /investigate command exists" "$PLUGIN_ROOT/skills/operate/SKILL.md"
  assert_file_exists "Y4: /replay-abandoned command exists" "$PLUGIN_ROOT/skills/operate/SKILL.md"
  assert_file_contains "Y5: /operate uses operate block" "$PLUGIN_ROOT/skills/operate/SKILL.md" "operate:"
  assert_file_contains "Y6: /operate rejects operate.yml" "$PLUGIN_ROOT/skills/operate/SKILL.md" ".startup/operate.yml"
  assert_file_contains "Y7: /monitor reuses monitor engine" "$PLUGIN_ROOT/skills/operate/SKILL.md" "scripts/monitor-dedup.sh"
  assert_file_contains "Y8: /investigate files dedup issue" "$PLUGIN_ROOT/skills/operate/SKILL.md" "deduplicated GitHub issue"
  assert_file_contains "Y9: /replay emits finding schema" "$PLUGIN_ROOT/skills/operate/SKILL.md" "finding.json"

  # Agent surface.
  assert_file_exists "Y10: incident-investigator agent exists" "$PLUGIN_ROOT/agents/incident-investigator.md"
  assert_file_exists "Y11: session-replay agent exists" "$PLUGIN_ROOT/agents/session-replay.md"
  assert_file_exists "Y12: support-triage agent exists" "$PLUGIN_ROOT/agents/support-triage.md"
  assert_file_contains "Y13: support agent config-driven" "$PLUGIN_ROOT/agents/support-triage.md" "operate:"

  # Workflow registry.
  assert_file_exists "Y14: workflow registry template exists" "$PLUGIN_ROOT/templates/workflow-registry.md"
  assert_file_exists "Y15: workflow spec template exists" "$PLUGIN_ROOT/templates/workflow-spec.md"
  assert_file_contains "Y16: bootstrap creates workflow registry" "$PLUGIN_ROOT/skills/bootstrap/SKILL.md" ".startup/workflows/registry.md"
  assert_file_contains "Y17: lifecycle uses bootstrap scaffold" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "/bootstrap"
  assert_file_contains "Y18: improve reads workflow registry" "$PLUGIN_ROOT/references/delivery-playbook.md" ".startup/workflows/registry.md"
  assert_file_contains "Y19: lifecycle does not force numbered handoffs" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "numbered conversational handoffs"

  # Config and README.
  assert_file_contains "Y20: example has operate block" "$PLUGIN_ROOT/saas-startup-team.local.md.example" "operate:"
  assert_file_contains "Y21: README documents operate phase" "$PLUGIN_ROOT/README.md" "Operate phase"
  assert_file_contains "Y22: README documents workflow registry" "$PLUGIN_ROOT/README.md" "Workflow registry"

  # Triggered SaaS gates across roles/templates (canonical body + pointers).
  assert_file_contains "Y23: canonical async paid-flow gate" "$PLUGIN_ROOT/references/triggered-saas-gates.md" "Async paid-flow UX gate"
  assert_file_contains "Y23p: business founder points at triggered gates" "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "triggered-saas-gates.md"
  assert_file_contains "Y24: business founder customer value unit" "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "customer value unit"
  assert_file_contains "Y25: canonical display-label registry" "$PLUGIN_ROOT/references/triggered-saas-gates.md" "Display-label registry"
  assert_file_contains "Y25p: tech founder points at triggered gates" "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "triggered-saas-gates.md"
  assert_file_contains "Y26: canonical LLM gate" "$PLUGIN_ROOT/references/triggered-saas-gates.md" "LLM pipeline quality gate"
  assert_file_contains "Y27: canonical structured-result scan" "$PLUGIN_ROOT/references/triggered-saas-gates.md" "structured-result raw-value scan"
  assert_file_contains "Y27p: UX tester points at triggered gates" "$PLUGIN_ROOT/skills/ux-review/SKILL.md" "triggered-saas-gates.md"
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
  echo -e "\n${CYAN}Suite Z: session-insights removed (#390)${NC}"
  assert_file_not_exists "Z1: session-insights.sh deleted" "$PLUGIN_ROOT/scripts/session-insights.sh"
  assert_file_not_exists "Z2: session-insights command deleted" "$PLUGIN_ROOT/commands/session-insights.md"
}

# ---------------------------------------------------------------------------
# Suite H: harvest.sh (dry-run candidate generator — no network, no filing)
# ---------------------------------------------------------------------------

test_harvest() {
  echo -e "\n${CYAN}Suite H: harvest removed (#390)${NC}"
  assert_file_not_exists "HV1: harvest.sh deleted" "$PLUGIN_ROOT/scripts/harvest.sh"
  assert_file_not_exists "HV2: harvest command deleted" "$PLUGIN_ROOT/commands/harvest.md"
}

# ---------------------------------------------------------------------------
# Suite F: lesson-file.sh (gated public filing of harvested candidates)
# ---------------------------------------------------------------------------

test_lesson_file() {
  echo -e "\n${CYAN}Suite F: lesson-file removed (#390)${NC}"
  assert_file_not_exists "F1: lesson-file.sh deleted" "$PLUGIN_ROOT/scripts/lesson-file.sh"
}

# ---------------------------------------------------------------------------
# Suite R: lesson-review.sh (manual/automated guarded transitions)
# ---------------------------------------------------------------------------

test_lesson_review() {
  echo -e "\n${CYAN}Suite R: lesson-review removed (#390)${NC}"
  assert_file_not_exists "R1: lesson-review.sh deleted" "$PLUGIN_ROOT/scripts/lesson-review.sh"
  assert_file_not_exists "R2: lessons-review command deleted" "$PLUGIN_ROOT/commands/lessons-review.md"
}

# ---------------------------------------------------------------------------
# Suite Z: Convergence governor integration
# ---------------------------------------------------------------------------

test_convergence_governor() {
  echo -e "\n${CYAN}Convergence governor integration${NC}"
  assert_output_contains "reachability convention exists" "$(cat "$PLUGIN_ROOT/references/tech-founder/reachability-convention.md" 2>/dev/null)" "last-verified"
  assert_file_contains "tech-founder DoD points at maintain checklist" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "check.sh"
  assert_file_contains "tech-founder DoD has step-back" \
    "$PLUGIN_ROOT/references/maintain-dod-checklist.md" "Tribunal step-back"
  assert_output_contains "goal-deliver caps at 5" "$(cat "$PLUGIN_ROOT/references/delivery-playbook.md")" "Round 5:"
  assert_output_contains "goal-deliver stops on no crit/high" "$(cat "$PLUGIN_ROOT/references/delivery-playbook.md")" "zero critical and zero high"
}

test_learnings_style_block() {
  echo -e "\n${CYAN}== learnings-style removed (#390) ==${NC}"
  assert_file_not_exists "L1: learnings-style.md deleted" "$PLUGIN_ROOT/templates/learnings-style.md"
}

test_founder_standards_routing() {
  echo -e "\n${CYAN}== capability skills hold implementation standards (#385) ==${NC}"
  assert_file_contains "S1: tech-founder skill is standards not persona" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Not a founder persona"
  assert_file_contains "S2: deliver owns technical delivery graph" \
    "$PLUGIN_ROOT/skills/deliver/SKILL.md" "Canonical delivery"
  assert_file_contains "S3: tech-founder points at deliver Build" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "skills/deliver"
  assert_file_contains "S4: Brief Acceptance Gate survives" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "S5: product-discovery bounds unconditional research" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "unconditional market research"
}

test_learnings_migrate_house_style() {
  echo -e "\n${CYAN}== learnings-migrate removed (#390) ==${NC}"
  assert_file_not_exists "M1: learnings-migrate command deleted" "$PLUGIN_ROOT/commands/learnings-migrate.md"
}

test_maintain_agents_reference_style() {
  echo -e "\n${CYAN}== maintain controllers removed; cast adapter owns Codex workers (#387) ==${NC}"
  assert_file_not_exists "N: codex maintain controller deleted" \
    "$PLUGIN_ROOT/agents/tech-founder-codex-maintain.md"
  assert_file_not_exists "N: claude maintain persona deleted" \
    "$PLUGIN_ROOT/agents/tech-founder-claude-maintain.md"
  assert_file_exists "N: codex-cast adapter" "$PLUGIN_ROOT/scripts/codex-cast.sh"
  assert_file_contains "N: product-acceptance for maintain product verdicts" \
    "$PLUGIN_ROOT/references/workflows/maintain.md" "skills/product-acceptance"
}

test_compress_golden_sample() {
  echo -e "\n${CYAN}== compress golden removed (#390) ==${NC}"
  assert_file_not_exists "G1: learnings-compress-golden deleted" "$PLUGIN_ROOT/templates/learnings-compress-golden.md"
}

test_learnings_compress_command() {
  echo -e "\n${CYAN}== learnings-compress removed (#390) ==${NC}"
  assert_file_not_exists "C1: learnings-compress command deleted" "$PLUGIN_ROOT/commands/learnings-compress.md"
}

test_handoff_secret_redaction() {
  echo -e "\n${CYAN}Suite: handoff secret redaction removed (#391)${NC}"
  assert_file_not_exists "secrets: script removed" "$PLUGIN_ROOT/scripts/check-handoff-secrets.sh"
  # Pre-write secret block via gate
  ec=0
  printf '%s' '{"tool_input":{"file_path":"x.md","content":"token sk-abcdefghijklmnopqrstuv"}}' \
    | bash "$PLUGIN_ROOT/scripts/gate.sh" pii --hook-stdin --mode secrets >/dev/null 2>&1 || ec=$?
  assert_exit_code "secrets: gate blocks secret token pre-write" "$ec" 2
}

test_autonomous_demand_infra() {
  echo -e "\n${CYAN}Suite AD: autonomous demand/preflight infrastructure${NC}"
  local health="$PLUGIN_ROOT/scripts/health-preflight.sh"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local packs="$PLUGIN_ROOT/scripts/acceptance-packs.sh"
  local demand="$PLUGIN_ROOT/scripts/demand-discovery.sh"
  local market="$PLUGIN_ROOT/scripts/market-scout.sh"
  local closure="$PLUGIN_ROOT/scripts/issue-closure-audit.sh"
  local workdir ec output count fault_bin real_mktemp real_sort real_tr
  local bad_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-destination-only.md"
  local empty_locale_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-empty-locale.md"
  local good_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-entry-path.md"
  local partial_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-partial-locale.md"

  assert_file_exists "AD1: health-preflight exists" "$health"
  assert_file_exists "AD2: maintain-v3 exists" "$v3"
  assert_file_not_exists "AD2b: single-flight deleted" "$PLUGIN_ROOT/scripts/single-flight.sh"
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
  assert_file_contains "AD4g: Codex capability check is bounded" \
    "$health" 'timeout 10 codex exec --help'
  assert_file_contains "AD4h: Codex capability check requires sandbox modes" \
    "$health" 'workspace-write'
  assert_file_contains "AD4i: Codex authentication check is bounded" \
    "$health" 'timeout 10 codex login status'
  assert_file_not_contains "AD4j: health preflight ignores stale sandbox configuration" \
    "$health" 'CODEX_SANDBOX'
  for s in "$health" "$v3" "$packs" "$demand" "$market" "$closure" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" \
    "$PLUGIN_ROOT/scripts/supervisor-commit.sh" \
    "$PLUGIN_ROOT/scripts/hooks-paused.sh" \
    "$PLUGIN_ROOT/scripts/legacy-drain.sh"; do
    ec=0; bash -n "$s" || ec=$?
    assert_exit_code "AD syntax: $(basename "$s")" "$ec" 0
  done

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
printf '%s\n' "$*" >> "$CODEX_CALL_LOG"
if [ "${1:-}" = exec ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: codex exec [OPTIONS]'
  if [ "${FAKE_CODEX_SANDBOX_HELP:-1}" -eq 1 ]; then
    printf '%s\n' '  -s, --sandbox <SANDBOX_MODE>'
    printf '%s\n' '          [possible values: read-only, workspace-write, danger-full-access]'
    printf '%s\n' '  -o, --output-last-message <FILE>'
  fi
  exit 0
fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  if [ "${FAKE_CODEX_AUTH_OK:-1}" -eq 1 ]; then
    printf '%s\n' 'Logged in'
    exit 0
  fi
  printf '%s\n' 'Not logged in' >&2
  exit 1
fi
exit 64
SH
  chmod +x "$workdir/bin/codex"
  : > "$workdir/codex-calls.log"
  ec=0; output=$(CODEX_CALL_LOG="$workdir/codex-calls.log" \
    CODEX_SANDBOX=stale-restricted-setting PATH="$workdir/bin:$PATH" \
    bash "$health" --json --require-codex --repo-root "$workdir" \
      --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6c: authenticated sandboxed Codex passes preflight" "$ec" 0
  assert_output_contains "AD6d: reports cast sandbox readiness" "$output" \
    'Codex authentication and sandbox modes required by codex-cast are available'
  assert_file_contains "AD6e: preflight inspects exec capability" \
    "$workdir/codex-calls.log" '^exec --help$'
  assert_file_contains "AD6f: preflight checks Codex authentication" \
    "$workdir/codex-calls.log" '^login status$'

  : > "$workdir/codex-calls.log"
  ec=0; output=$(CODEX_CALL_LOG="$workdir/codex-calls.log" FAKE_CODEX_SANDBOX_HELP=0 \
    PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex \
      --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6g: missing sandbox capability blocks preflight" "$ec" 1
  assert_output_contains "AD6h: missing capability names sandbox modes" "$output" \
    'lacks --sandbox read-only/workspace-write'
  assert_file_not_contains "AD6i: capability failure skips auth" \
    "$workdir/codex-calls.log" 'login status'

  : > "$workdir/codex-calls.log"
  ec=0; output=$(CODEX_CALL_LOG="$workdir/codex-calls.log" FAKE_CODEX_AUTH_OK=0 \
    PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex \
      --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6j: unavailable Codex authentication blocks preflight" "$ec" 1
  assert_output_contains "AD6k: authentication failure is explicit" "$output" \
    'Codex authentication is unavailable: Not logged in'
  rm -rf "$workdir"

  # Short maintain-v3 locks replace single-flight whole-pass leases (#389).
  workdir=$(mktemp -d)
  ec=0; output=$(bash "$v3" lock acquire --kind issue --key issue-42 --state-dir "$workdir" \
    --owner one --ttl-seconds 60 2>&1) || ec=$?
  assert_exit_code "AD7: issue lock acquire exits 0" "$ec" 0
  ec=0; output=$(bash "$v3" lock acquire --kind issue --key issue-42 --state-dir "$workdir" \
    --owner two --ttl-seconds 60 2>&1) || ec=$?
  assert_exit_code "AD8: second active owner refused" "$ec" 3
  bash "$v3" lock release --kind issue --key issue-42 --state-dir "$workdir" --owner one >/dev/null
  ec=0; output=$(bash "$v3" lock acquire --kind scheduler --key sched-1 --state-dir "$workdir" \
    --owner two --ttl-seconds 30 2>&1) || ec=$?
  assert_exit_code "AD9: scheduler lock acquire exits 0" "$ec" 0
  bash "$v3" lock release --kind scheduler --key sched-1 --state-dir "$workdir" --owner two >/dev/null
  ec=0; output=$(bash "$v3" lock acquire --kind release --key rel-1 --state-dir "$workdir" \
    --owner two --ttl-seconds 30 2>&1) || ec=$?
  assert_exit_code "AD10: release lock acquire exits 0" "$ec" 0
  bash "$v3" lock release --kind release --key rel-1 --state-dir "$workdir" --owner two >/dev/null
  ec=0; output=$(bash "$v3" lock status --kind issue --key issue-42 --state-dir "$workdir" \
    --owner two 2>&1) || ec=$?
  assert_exit_code "AD11: lock status exits 0" "$ec" 0
  assert_output_contains "AD11b: released lock not held" "$output" '"held":false'
  rm -rf "$workdir"

  ec=0; output=$(bash "$packs" --select --category report_output_quality --text "customer report has citations and remedies" --json 2>&1) || ec=$?
  assert_exit_code "AD12: pack select exits 0" "$ec" 0
  assert_output_contains "AD12b: selects report pack" "$output" "report_output_product"
  assert_output_not_contains "AD12c: does not match Estonian pack through generic words" "$output" "estonian_saas_context"
  ec=0; output=$(bash "$packs" --select --text "Add a public SEO guide page" --json 2>&1) || ec=$?
  assert_exit_code "AD12d: public-page pack selection exits 0" "$ec" 0
  assert_output_contains "AD12e: public-page text selects discoverability" "$output" \
    "public_route_discoverability"
  output=$(bash "$packs" --render public_route_discoverability)
  assert_output_contains "AD12f: rendered pack rejects direct-only QA" "$output" \
    "direct navigation alone cannot pass"
  ec=0; output=$(bash "$packs" --verify-public-route "$bad_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12g: destination-only QA fixture fails" "$ec" 1
  assert_output_contains "AD12h: destination-only failure names missing click path" "$output" \
    "no clicked customer entry path"
  ec=0; output=$(bash "$packs" --verify-public-route "$good_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12i: clicked entry-path fixture passes" "$ec" 0
  assert_output_contains "AD12j: public-route verifier reports success" "$output" \
    "public-route discoverability gate passed"
  ec=0; output=$(bash "$packs" --verify-public-route "$partial_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12k: missing locale entry path fails" "$ec" 1
  assert_output_contains "AD12l: partial-locale failure is explicit" "$output" \
    "for every locale"
  ec=0; output=$(bash "$packs" --verify-public-route "$empty_locale_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12m: empty locale list fails" "$ec" 1
  assert_output_contains "AD12n: empty-locale failure is explicit" "$output" \
    "for every locale"
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
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #56\nClosure-Audit-Split: #55 backend/app/services/xbrl_generator.py -> #56","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  cat > "$workdir/issue-followup.json" <<'JSON'
{"number":56,"state":"OPEN","title":"Complete deferred document rendering","body":"Track the explicitly split rendering acceptance.","comments":[]}
JSON
  printf 'frontend/step2.tsx\n' > "$workdir/files.txt"
  printf 'frontend/step2.tsx\nbackend/app/services/xbrl_generator.py\nbackend/app/services/pdf_renderer.py\n' > "$workdir/files-all.txt"
  fault_bin="$workdir/fault-bin"; mkdir "$fault_bin"
  real_mktemp=$(command -v mktemp); real_sort=$(command -v sort); real_tr=$(command -v tr)
  cat > "$fault_bin/mktemp" <<'SH'
#!/usr/bin/env bash
[ "${CLOSURE_FAULT:-}" != mktemp ] || exit 73
exec "$REAL_MKTEMP" "$@"
SH
  cat > "$fault_bin/sort" <<'SH'
#!/usr/bin/env bash
if [ "${CLOSURE_FAULT:-}" = audit-sort ] && [ "$*" = -nu ]; then exit 73; fi
exec "$REAL_SORT" "$@"
SH
  cat > "$fault_bin/tr" <<'SH'
#!/usr/bin/env bash
[ "${CLOSURE_FAULT:-}" != path-tr ] || exit 73
exec "$REAL_TR" "$@"
SH
  chmod +x "$fault_bin/mktemp" "$fault_bin/sort" "$fault_bin/tr"
  ec=0; output=$(PATH="$fault_bin:$PATH" CLOSURE_FAULT=mktemp \
    REAL_MKTEMP="$real_mktemp" REAL_SORT="$real_sort" REAL_TR="$real_tr" \
    bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" \
      --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD17d: audit workspace creation failure fails closed" "$ec" 1
  assert_output_contains "AD17e: audit workspace failure is explicit" "$output" \
    "cannot create private audit workspace"
  ec=0; output=$(PATH="$fault_bin:$PATH" CLOSURE_FAULT=audit-sort \
    REAL_MKTEMP="$real_mktemp" REAL_SORT="$real_sort" REAL_TR="$real_tr" \
    bash "$closure" --pr-json "$workdir/pr.json" --audit-issue 55 \
      --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD17f: issue normalization producer failure fails closed" "$ec" 1
  assert_output_contains "AD17g: issue normalization failure is explicit" "$output" \
    "cannot normalize audited issue numbers"
  ec=0; output=$(PATH="$fault_bin:$PATH" CLOSURE_FAULT=path-tr \
    REAL_MKTEMP="$real_mktemp" REAL_SORT="$real_sort" REAL_TR="$real_tr" \
    bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" \
      --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD17h: named-surface producer failure fails closure closed" "$ec" 1
  assert_output_contains "AD17i: named-surface producer failure is explicit" "$output" \
    "cannot extract named issue surfaces"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD18: closure audit fails missing named surfaces" "$ec" 1
  assert_output_contains "AD18b: closure audit names missing backend path" "$output" "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-ok.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #56: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19: closure audit accepts an authorized OPEN follow-up" "$ec" 0
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue.json" \
    --issue-json "$workdir/issue-followup.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19a0: duplicate issue fixtures fail closed" "$ec" 1
  assert_output_contains "AD19a01: duplicate fixture refusal is explicit" "$output" \
    "duplicate issue JSON for #55"
  cat > "$workdir/issue-no-split-auth.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue-no-split-auth.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19a02: PR mapping cannot invent split authorization" "$ec" 1
  assert_output_contains "AD19a03: missing original authorization is explicit" "$output" \
    "original issue #55 needs exactly one split authorization"
  cat > "$workdir/pr-generic-override.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\n#55 remaining scope has follow-up #56.\nRefs #55"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-generic-override.json" --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19aa: a generic closure heading cannot waive named surfaces" "$ec" 1
  assert_output_contains "AD19ab: generic waiver failure names the exact missing path" "$output" \
    "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-partial-override.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-partial-override.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ac: a per-path disposition cannot waive another path" "$ec" 1
  assert_output_contains "AD19ad: partial disposition failure names the unbound path" "$output" \
    "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-same-followup.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #55: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #55: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-same-followup.json" \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ae: original issue cannot be its own follow-up" "$ec" 1
  assert_output_contains "AD19af: same-issue refusal is explicit" "$output" \
    "must differ from original issue #55"
  cat > "$workdir/issue-closed-followup-auth.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #57\nClosure-Audit-Split: #55 backend/app/services/xbrl_generator.py -> #57","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  cat > "$workdir/issue-followup-closed.json" <<'JSON'
{"number":57,"state":"CLOSED","title":"Deferred rendering","body":"No longer open.","comments":[]}
JSON
  cat > "$workdir/pr-closed-followup.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #57: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #57: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-closed-followup.json" \
    --issue-json "$workdir/issue-closed-followup-auth.json" \
    --issue-json "$workdir/issue-followup-closed.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ag: a closed follow-up cannot authorize closure" "$ec" 1
  assert_output_contains "AD19ah: closed follow-up refusal requires OPEN state" "$output" \
    "follow-up issue #57 is CLOSED, not OPEN"
  cat > "$workdir/pr-duplicate-deferral.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #56: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-duplicate-deferral.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ai: duplicate path deferrals fail closed" "$ec" 1
  assert_output_contains "AD19aj: duplicate deferral refusal is explicit" "$output" \
    "must appear exactly once"
  cat > "$workdir/pr-malformed-deferral.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | not applicable: PDF rendering is outside this change\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | covered by: existing date emission code"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-malformed-deferral.json" \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ak: non-follow-up dispositions cannot waive scope" "$ec" 1
  assert_output_contains "AD19al: malformed deferral refusal is explicit" "$output" \
    "must name one follow-up issue"
  cat > "$workdir/issue-duplicate-auth.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #56\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #56\nClosure-Audit-Split: #55 backend/app/services/xbrl_generator.py -> #56","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue-duplicate-auth.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19am: duplicate original split authorization fails closed" "$ec" 1
  assert_output_contains "AD19an: original split authorization must be singular" "$output" \
    "needs exactly one split authorization"
  cat > "$workdir/pr-refs.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\n## Changes\nFrontend default selection only."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-refs.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19a: prospective audit checks a non-closing maintain-loop PR" "$ec" 1
  assert_output_contains "AD19b: prospective audit names missing scope" "$output" \
    "backend/app/services/xbrl_generator.py"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-refs.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19c: prospective audit accepts exact metadata and complete scope" "$ec" 0
  cat > "$workdir/pr-prospective-override.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\n## Closure audit\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | not applicable: the requested backend surface is intentionally excluded"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-prospective-override.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ca: prospective audit cannot defer a named surface" "$ec" 1
  assert_output_contains "AD19cb: prospective deferral refusal is explicit" "$output" \
    "prospective audits cannot defer named surfaces"
  cat > "$workdir/pr-closing.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nCloses #55"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d: prospective audit rejects a body closing reference" "$ec" 1
  assert_output_contains "AD19e: closing-reference refusal is explicit" "$output" \
    "closing issue reference"
  cat > "$workdir/pr-qualified-closing.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nCloses example/example#55"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-qualified-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0a: prospective audit rejects a qualified closing reference" "$ec" 1
  assert_output_contains "AD19d0b: qualified closing-reference refusal is explicit" "$output" \
    "closing issue reference"
  cat > "$workdir/pr-url-closing.json" <<'JSON'
{"title":"Resolves: https://github.com/example/example/issues/55","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-url-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0c: prospective audit rejects a URL closing reference" "$ec" 1
  assert_output_contains "AD19d0d: URL closing-reference refusal is explicit" "$output" \
    "closing issue reference"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-qualified-closing.json" \
    --repo example/example --issue-json "$workdir/issue.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0e: qualified closing references enter the normal closure audit" "$ec" 1
  assert_output_contains "AD19d0f: qualified closure audit names missing scope" "$output" \
    "backend/app/services/xbrl_generator.py"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-qualified-closing.json" \
    --repo current/repository --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0g: live audit rejects a cross-repository closing target" "$ec" 1
  assert_output_contains "AD19d0h: cross-repository refusal is explicit" "$output" \
    "cross-repository closing references are not auditable"
  ec=0; output=$(bash "$closure" \
    --pr https://github.com/example/example/pull/7 --repo different/repository 2>&1) || ec=$?
  assert_exit_code "AD19d0i: pull request URL cannot conflict with --repo" "$ec" 2
  assert_output_contains "AD19d0j: URL/repository mismatch is explicit" "$output" \
    "--repo conflicts with the pull request URL"
  cat > "$workdir/pr-title-closing.json" <<'JSON'
{"title":"Fixes #55","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-title-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d1: prospective audit rejects a title closing reference" "$ec" 1
  cat > "$workdir/pr-prose-fixed.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nThe race is fixed and the scope is complete."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-prose-fixed.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d2: prospective audit permits non-closing fix prose" "$ec" 0
  cat > "$workdir/pr-missing-ref.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Maintain-Loop-Issue: #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-missing-ref.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19f: prospective audit rejects missing exact ref" "$ec" 1
  assert_output_contains "AD19g: missing ref names the exact required line" "$output" "exact line: Refs #55"
  cat > "$workdir/pr-mismatched-ref.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #54\n\nMaintain-Loop-Issue: #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-mismatched-ref.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19h: prospective audit rejects mismatched ref" "$ec" 1
  assert_output_contains "AD19i: mismatched ref cannot satisfy exact audited ref" "$output" "exact line: Refs #55"
  cat > "$workdir/pr-missing-marker.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-missing-marker.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19j: prospective audit rejects missing exact marker" "$ec" 1
  assert_output_contains "AD19k: missing marker names the exact required line" "$output" \
    "exact line: Maintain-Loop-Issue: #55"
  cat > "$workdir/pr-mismatched-marker.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #54\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-mismatched-marker.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19l: prospective audit rejects mismatched marker" "$ec" 1
  assert_output_contains "AD19m: mismatched marker cannot satisfy audited marker" "$output" \
    "exact line: Maintain-Loop-Issue: #55"
  cat > "$workdir/pr-duplicate-bindings.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\nRefs #55\n\nMaintain-Loop-Issue: #55\nMaintain-Loop-Issue: #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-duplicate-bindings.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ma: prospective audit rejects duplicate metadata bindings" "$ec" 1
  assert_output_contains "AD19mb: duplicate refs cannot expand the audit set" "$output" \
    "Refs lines must bind exactly once"
  cat > "$workdir/pr-extra-bindings.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\nRefs #56\n\nMaintain-Loop-Issue: #55\nMaintain-Loop-Issue: #56\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-extra-bindings.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19mc: prospective audit rejects extra issue bindings" "$ec" 1
  assert_output_contains "AD19md: extra markers cannot exceed the audit set" "$output" \
    "Maintain-Loop-Issue lines must bind exactly once"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" --audit-issue nope \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19n: prospective audit rejects invalid issue numbers" "$ec" 2
  printf '{"title":' > "$workdir/pr-malformed.json"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-malformed.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19o: malformed PR JSON fails closed" "$ec" 1
  assert_output_contains "AD19p: malformed PR JSON is explicit" "$output" "malformed PR JSON"
  cat > "$workdir/pr-bad-body.json" <<'JSON'
{"title":"fix: covered-stub selection","body":["Refs #55"]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bad-body.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19q: invalid PR body shape fails closed" "$ec" 1
  assert_output_contains "AD19r: invalid PR body shape is explicit" "$output" "invalid body shape"
  cat > "$workdir/pr-bad-files.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55","files":"frontend/step2.tsx"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bad-files.json" 2>&1) || ec=$?
  assert_exit_code "AD19s: invalid fetched PR files shape fails closed" "$ec" 1
  assert_output_contains "AD19t: invalid PR files shape is explicit" "$output" "invalid files shape"
  mkdir -p "$workdir/bin"
  printf '#!/bin/sh\nexit 1\n' > "$workdir/bin/gh"
  chmod +x "$workdir/bin/gh"
  cat > "$workdir/issue-mismatch.json" <<'JSON'
{"number":54,"state":"OPEN","title":"Different issue","body":"Acceptance requires `frontend/step2.tsx`.","comments":[]}
JSON
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue-mismatch.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD20: closure audit rejects mismatched single fixture" "$ec" 1
  assert_output_contains "AD20b: mismatched issue payload is explicit" "$output" "does not match audited issue #55"
  cat > "$workdir/issue-closed.json" <<'JSON'
{"number":55,"state":"CLOSED","title":"Closed issue","body":"Acceptance requires `frontend/step2.tsx`.","comments":[]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-refs.json" --audit-issue 55 \
    --issue-json "$workdir/issue-closed.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD20c: closure audit rejects a closed audited issue" "$ec" 1
  assert_output_contains "AD20d: closed issue refusal requires OPEN state" "$output" "CLOSED, not OPEN"
  printf '{"number":55,"state":"OPEN"' > "$workdir/issue-malformed.json"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr.json" \
    --issue-json "$workdir/issue-malformed.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD20e: malformed issue JSON fails closed" "$ec" 1
  assert_output_contains "AD20f: malformed issue JSON is explicit" "$output" "malformed issue JSON"
  cat > "$workdir/issue-anon.json" <<'JSON'
{"state":"OPEN","title":"Anonymous fixture","body":"Acceptance requires `frontend/step2.tsx`.","comments":[]}
JSON
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue-anon.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD21: closure audit rejects issue JSON without a number" "$ec" 1
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/pr-bracket.json" <<'JSON'
{"title":"fix: download flow","body":"Closes #200\n\n## Changes\nUpdated dynamic route page and step component."}
JSON
  cat > "$workdir/issue-bracket.json" <<'JSON'
{"number":200,"state":"OPEN","title":"Fix download","body":"Acceptance requires `frontend/src/app/[locale]/download/[token]/page.tsx` and `frontend/src/app/[locale]/report/components/Step6Download.tsx`.","comments":[]}
JSON
  printf 'frontend/src/app/[locale]/download/[token]/page.tsx\nfrontend/src/app/[locale]/report/components/Step6Download.tsx\n' > "$workdir/files-bracket.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bracket.json" --issue-json "$workdir/issue-bracket.json" --changed-files "$workdir/files-bracket.txt" 2>&1) || ec=$?
  assert_exit_code "AD22: bracketed Next.js dynamic-route path does not false-fail" "$ec" 0
  rm -rf "$workdir"

  # #1604 — bare basename dedupe when a full path with the same basename is present
  workdir=$(mktemp -d)
  cat > "$workdir/pr-basename.json" <<'JSON'
{"title":"fix: verifier tweak","body":"Closes #201\n\n## Changes\nTouched the full path only."}
JSON
  cat > "$workdir/issue-basename.json" <<'JSON'
{"number":201,"state":"OPEN","title":"Update verifier","body":"Change `scripts/verify_finding.py` (also referred to as bare `verify_finding.py`).","comments":[]}
JSON
  printf 'scripts/verify_finding.py\n' > "$workdir/files-basename.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-basename.json" --issue-json "$workdir/issue-basename.json" --changed-files "$workdir/files-basename.txt" 2>&1) || ec=$?
  assert_exit_code "AD23: bare basename covered by full path does not false-fail" "$ec" 0
  # Without the full path, the bare basename alone is still a real surface
  cat > "$workdir/issue-bare-only.json" <<'JSON'
{"number":201,"state":"OPEN","title":"Bare only","body":"Must update `verify_finding.py` narrative checks.","comments":[]}
JSON
  printf 'frontend/src/app/report/storage.ts\n' > "$workdir/files-other.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-basename.json" --issue-json "$workdir/issue-bare-only.json" --changed-files "$workdir/files-other.txt" 2>&1) || ec=$?
  assert_exit_code "AD23b: bare basename alone still requires a PR surface" "$ec" 1
  assert_output_contains "AD23c: bare basename is named as missing" "$output" "verify_finding.py"
  # #416 — bare filenames match an exact basename in nested changed paths.
  cat > "$workdir/pr-nested-basename.json" <<'JSON'
{"title":"fix: VAT fixture assertions","body":"Closes #203"}
JSON
  cat > "$workdir/issue-nested-basename.json" <<'JSON'
{"number":203,"state":"OPEN","title":"Update assertions","body":"Update `assertions.json`.","comments":[]}
JSON
  printf '%s\n' 'backend/tests/fixtures/engine_sessions/vat_payable_year_end/expected/assertions.json' > "$workdir/files-nested-basename.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-nested-basename.json" --issue-json "$workdir/issue-nested-basename.json" --changed-files "$workdir/files-nested-basename.txt" 2>&1) || ec=$?
  assert_exit_code "AD23d: bare basename matches nested changed path" "$ec" 0
  rm -rf "$workdir"

  # #1604 — Closure-Audit-Unchanged disposition
  workdir=$(mktemp -d)
  cat > "$workdir/pr-unchanged.json" <<'JSON'
{"title":"fix: storage isolation","body":"Closes #202\n\n## Closure audit\nClosure-Audit-Unchanged: #202 scripts/verify_finding.py | narrative verifier must stay byte-identical; covered by existing regression tests"}
JSON
  cat > "$workdir/issue-unchanged.json" <<'JSON'
{"number":202,"state":"OPEN","title":"Keep verifier","body":"Touch storage and leave `scripts/verify_finding.py` behaviorally unchanged.","comments":[]}
JSON
  printf 'frontend/src/app/report/storage.ts\n' > "$workdir/files-unchanged.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-unchanged.json" --issue-json "$workdir/issue-unchanged.json" --changed-files "$workdir/files-unchanged.txt" 2>&1) || ec=$?
  assert_exit_code "AD24: Closure-Audit-Unchanged accepts negative-requirement surface" "$ec" 0
  cat > "$workdir/pr-unchanged-short.json" <<'JSON'
{"title":"fix: storage isolation","body":"Closes #202\n\nClosure-Audit-Unchanged: #202 scripts/verify_finding.py | too short"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-unchanged-short.json" --issue-json "$workdir/issue-unchanged.json" --changed-files "$workdir/files-unchanged.txt" 2>&1) || ec=$?
  assert_exit_code "AD24b: short unchanged reason fails closed" "$ec" 1
  assert_output_contains "AD24c: short reason refusal is explicit" "$output" "concrete reason"
  # Without disposition, the unchanged surface still fails
  cat > "$workdir/pr-no-disp.json" <<'JSON'
{"title":"fix: storage isolation","body":"Closes #202"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-no-disp.json" --issue-json "$workdir/issue-unchanged.json" --changed-files "$workdir/files-unchanged.txt" 2>&1) || ec=$?
  assert_exit_code "AD24d: missing unchanged disposition still fails" "$ec" 1
  assert_output_contains "AD24e: missing surface named" "$output" "scripts/verify_finding.py"
  rm -rf "$workdir"
}

test_autonomous_workflow_alignment() {
  echo -e "\n${CYAN}Suite AE: autonomous workflow alignment${NC}"
  local repo_root; repo_root="$(cd "$PLUGIN_ROOT/../.." && pwd)"
  assert_file_contains "AE1: lifecycle/playbook health preflight" "$PLUGIN_ROOT/references/delivery-playbook.md" "health-preflight.sh"
  assert_file_contains "AE2: lifecycle uses market scout" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "market-scout.sh"
  assert_file_not_contains "AE3: lifecycle has no single-flight" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "single-flight.sh"
  assert_file_not_contains "AE4: startup no broad stale pkill command" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "pkill -f 'agent-type saas-startup-team'"
  assert_file_not_contains "AE4b: lifecycle no broad pkill" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" \
    "pkill -f 'agent-type saas-startup-team"
  assert_file_contains "AE5: improve calls health preflight" "$PLUGIN_ROOT/references/delivery-playbook.md" "health-preflight.sh"
  assert_file_contains "AE6: goal-deliver calls market scout" "$PLUGIN_ROOT/references/delivery-playbook.md" "market-scout.sh"
  assert_file_contains "AE7: goal-deliver requires acceptance packs" "$PLUGIN_ROOT/references/delivery-playbook.md" "acceptance-packs.sh"
  assert_file_contains "AE8: goal-deliver completion artifact" "$PLUGIN_ROOT/references/delivery-playbook.md" "completion artifact"
  assert_file_not_exists "AE9: lessons-review removed (#390)" "$PLUGIN_ROOT/commands/lessons-review.md"
  assert_file_not_exists "AE10: lessons-deliver removed (#390)" "$PLUGIN_ROOT/commands/lessons-deliver.md"
  assert_file_not_exists "AE11: agent-events removed (#390)" "$PLUGIN_ROOT/scripts/agent-events.sh"
  assert_file_contains "AE12: README documents health preflight" "$PLUGIN_ROOT/README.md" "health-preflight.sh"
  assert_file_contains "AE13: README documents market scout" "$PLUGIN_ROOT/README.md" "market-scout.sh"
  assert_file_contains "AE14: README documents acceptance packs" "$PLUGIN_ROOT/README.md" "acceptance-packs.sh"
  assert_file_contains "AE15: README documents short maintain locks" "$PLUGIN_ROOT/README.md" "Short maintain locks only"
  assert_file_contains "AE16: improve runs closure audit" "$PLUGIN_ROOT/references/delivery-playbook.md" "issue-closure-audit.sh"
  assert_file_contains "AE17: goal-deliver runs closure audit" "$PLUGIN_ROOT/references/delivery-playbook.md" "issue-closure-audit.sh"
  assert_file_contains "AE18: goal-deliver asks material promise question" "$PLUGIN_ROOT/references/delivery-playbook.md" "material promise"
  assert_file_contains "AE19: growth detects lifecycle" "$PLUGIN_ROOT/skills/growth/SKILL.md" "growth_lifecycle"
  assert_file_contains "AE20: growth prelive forbids outreach" "$PLUGIN_ROOT/skills/growth/SKILL.md" "do not contact prospects"
  assert_file_contains "AE21: growth uses autonomous operations gates" "$PLUGIN_ROOT/skills/growth/SKILL.md" "owner authorization gates"
  assert_file_not_contains "AE22: growth no longer creates recurring human tasks" "$PLUGIN_ROOT/skills/growth/SKILL.md" "### 2e: Create human tasks"
  assert_file_contains "AE22a: improve selects the public-route pack" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'public_route_discoverability'
  assert_file_contains "AE22b: improve mechanically rejects destination-only QA" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" '--verify-public-route "$QA_REVIEW"'
  assert_file_contains "AE22c: business brief carries public-route contract" \
    "$PLUGIN_ROOT/templates/handoff-business-to-tech.md" 'Public-route discoverability'
  assert_file_contains "AE22d: tech handoff carries public-route evidence" \
    "$PLUGIN_ROOT/templates/handoff-tech-to-business.md" 'Public-route discoverability'
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

  # Discovered suites: tests/**/*.tests.sh so nested suites (e.g. lifecycle/) load.
  local suite
  while IFS= read -r -d '' suite; do
    echo ""
    echo -e "${CYAN}Discovered suite: ${suite#"$PLUGIN_ROOT/tests/"}${NC}"
    # shellcheck source=/dev/null
    . "$suite"
  done < <(find "$PLUGIN_ROOT/tests" -type f -name '*.tests.sh' -print0 | sort -z)

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
  else
    echo ""
  fi

  if [ "$TOTAL_COUNT" -ne "$((PASS_COUNT + FAIL_COUNT))" ]; then
    echo -e "${RED}COUNTER MISMATCH: Total: $TOTAL_COUNT | Pass: $PASS_COUNT | Fail: $FAIL_COUNT${NC}"
    exit 1
  fi

  if [ "${#FAILURES[@]}" -ne "$FAIL_COUNT" ]; then
    echo -e "${RED}FAILURE MISMATCH: Failures: ${#FAILURES[@]} | Fail: $FAIL_COUNT${NC}"
    exit 1
  fi

  [ "$FAIL_COUNT" -eq 0 ] || exit 1
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
}

# ---------------------------------------------------------------------------
# Suite Q: Handoff Index Hook (index-handoff.sh)
# ---------------------------------------------------------------------------

test_index_handoff_hook() {
  echo -e "\n${CYAN}Suite: index-handoff removed (#391)${NC}"
  assert_file_not_exists "index: script removed" "$PLUGIN_ROOT/scripts/index-handoff.sh"
}


test_goal_deliver() {
  echo -e "\n${CYAN}Suite T: /goal-deliver via deliver skill${NC}"
  local cmd="$PLUGIN_ROOT/commands/goal-deliver.md"
  local skill="$PLUGIN_ROOT/skills/deliver/SKILL.md"
  local graph="$PLUGIN_ROOT/references/delivery-playbook.md"
  local entry="$PLUGIN_ROOT/references/delivery-playbook.md"
  local multi="$PLUGIN_ROOT/references/delivery-playbook.md"

  assert_file_exists "T1: goal-deliver command exists" "$cmd"
  assert_file_contains "T2: command name frontmatter" "$cmd" "^name: goal-deliver"
  assert_file_contains "T3: user_invocable" "$cmd" "user_invocable: true"
  assert_file_contains "T4: command loads deliver skill" "$cmd" "skills/deliver/SKILL.md"
  assert_file_contains "T5: graph references tribunal-loop" "$graph" "tribunal-loop"
  assert_file_contains "T6: graph references closing-tribunal-loop" "$graph" "closing-tribunal-loop"
  assert_file_contains "T7: deliver does not require active_role" "$skill" "require founder personas"
  assert_file_contains "T8: warns against team-lead" "$skill" "team-lead"
  assert_file_contains "T9: documents /goal autonomy pairing" "$entry" "/goal "
  assert_file_contains "T10: monitors GitHub Actions deploy" "$multi" "gh run"
}

# ---------------------------------------------------------------------------
# Suite U: /ads command + growth→ads delegation
# ---------------------------------------------------------------------------

test_ads_delegation() {
  echo -e "\n${CYAN}Suite U: growth→ads capability (no /ads command)${NC}"
  local growth="$PLUGIN_ROOT/skills/growth/SKILL.md"
  local gh="$PLUGIN_ROOT/skills/growth/SKILL.md"
  assert_file_not_exists "U0: /ads command removed" "$PLUGIN_ROOT/commands/ads.md"
  assert_file_not_exists "U1: ads workflow alias removed" "$PLUGIN_ROOT/skills/saas-startup-team-ads-workflow/SKILL.md"
  assert_file_exists "U2: growth command remains" "$growth"
  assert_file_contains "U3: growth command name" "$growth" "^name: growth"
  assert_file_contains "U4: spawns ads-strategist by scoped registered type" "$growth" 'subagent_type: "google-ads-strategist:ads-strategist"'
  assert_file_contains "U5: creates PAUSED / investor enables" "$growth" "PAUSED"
  assert_file_contains "U6: hard-dependency install message" "$growth" "google-ads-strategist"
  assert_file_not_contains "U7: no read-md idiom for the strategist" "$growth" 'agents/ads-strategist.md'
  assert_file_contains "U8: growth.md has Google Ads request branch" "$growth" "Google Ads request"
  assert_file_contains "U9: no /ads command (growth owns ads link)" "$gh" "no /ads command"
  assert_file_contains "U10: Google Ads request flag in growth skill" "$gh" "Google Ads request"
  assert_file_contains "U11: forbids designing Google Ads inline" "$gh" "Designing/creating Google Ads inline"
  assert_file_contains "U12: growth skill is capability not persona" "$gh" "Not a founder persona"
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
#   GH_API_JSON       paginated `gh api` JSON (default `[[]]`)
#   GH_FAIL_ON        if argv contains this substring, exit 1 (simulate gh failure)
make_mock_gh() {
  local bindir="$1/bin"
  local view_store="$1/.gh-view.json"
  mkdir -p "$bindir"
  if [ -n "${GH_VIEW_JSON:-}" ]; then
    printf '%s
' "$GH_VIEW_JSON" > "$view_store"
  else
    rm -f -- "$view_store"
  fi
  # Quoted heredoc keeps the mock body literal; only view_store path is injected.
  cat > "$bindir/gh" <<MOCK
#!/usr/bin/env bash
_args="\$*"; printf '%s
' "\${_args//\$'
'/ }" >> "\${GH_CALLS_LOG:?}"
if [ -n "\${GH_FAIL_ON:-}" ] && [[ "\$*" == *"\$GH_FAIL_ON"* ]]; then
  echo "mock gh: forced failure" >&2; exit 1
fi
_VIEW_STORE="$view_store"
_seed_view() {
  if [ ! -f "\$_VIEW_STORE" ] && [ -n "\${GH_VIEW_JSON:-}" ]; then
    printf '%s
' "\$GH_VIEW_JSON" > "\$_VIEW_STORE"
  fi
}
case "\$1 \$2" in
  "api --paginate") echo "\${GH_API_JSON:-[[]]}" ;;
  "repo view")   echo "\${GH_REPO:-o/r}" ;;
  "issue create") echo "https://github.com/o/r/issues/\${GH_CREATE_NUMBER:?GH_CREATE_NUMBER unset}" ;;
  "issue comment") echo "https://github.com/o/r/issues/commented" ;;
  "issue view")
     # Mutable store / GH_VIEW_JSON for claim re-reads; otherwise keep legacy
     # plain GH_VIEW_STATE / GH_VIEW_BODY responses used by monitor-dedup.
     if [ -f "\$_VIEW_STORE" ] || [ -n "\${GH_VIEW_JSON:-}" ]; then
       if [[ "\$*" == *"--json"* ]]; then
         _seed_view
         if [ -f "\$_VIEW_STORE" ]; then cat "\$_VIEW_STORE"; else echo "\$GH_VIEW_JSON"; fi
       elif [[ "\$*" == *"body"* ]]; then echo "\${GH_VIEW_BODY:-}"
       else echo "\${GH_VIEW_STATE:-OPEN}"; fi
     elif [[ "\$*" == *"body"* ]]; then echo "\${GH_VIEW_BODY:-}"
     else echo "\${GH_VIEW_STATE:-OPEN}"; fi ;;
  "issue list")
     if [[ "\$*" == *"--state all"* ]] && [ -n "\${GH_ALL_ISSUES_JSON:-}" ]; then
       echo "\$GH_ALL_ISSUES_JSON"
     else
       echo "\${GH_LIST_JSON:-\${GH_SEARCH_JSON:-[]}}"
     fi ;;
  "issue edit")
     _seed_view
     if [ -f "\$_VIEW_STORE" ]; then
       _cur="\$(cat "\$_VIEW_STORE")"
       _i=1
       while [ "\$_i" -le "\$#" ]; do
         _a="\${!_i}"
         if [ "\$_a" = "--add-label" ]; then
           _i=\$((_i + 1)); _lab="\${!_i}"
           _cur="\$(printf '%s' "\$_cur" | jq -c --arg l "\$_lab" '.labels = ((.labels // []) + [{name:\$l}] | group_by(.name) | map(.[0]))')"
         elif [ "\$_a" = "--remove-label" ]; then
           _i=\$((_i + 1)); _lab="\${!_i}"
           _cur="\$(printf '%s' "\$_cur" | jq -c --arg l "\$_lab" '.labels = [((.labels // [])[]) | select(.name != \$l)]')"
         fi
         _i=\$((_i + 1))
       done
       printf '%s
' "\$_cur" > "\$_VIEW_STORE"
     fi
     ;;
  "issue close") : ;;
  "label create") : ;;
  "pr create")   echo "https://github.com/o/r/pull/\${GH_PR_NUMBER:-999}" ;;
  "pr merge")    : ;;
  "pr list")     echo "\${GH_PR_LIST_JSON:-[]}" ;;
  "pr view")     echo "\${GH_PR_VIEW_JSON:-{}}" ;;
  *) : ;;
esac
MOCK
  chmod +x "$bindir/gh"
}

test_lessons_deliver() {
  echo -e "\n${CYAN}Suite L: lessons-deliver removed (#390)${NC}"
  assert_file_not_exists "L1: lessons-deliver.sh deleted" "$PLUGIN_ROOT/scripts/lessons-deliver.sh"
  assert_file_not_exists "L2: lessons-deliver command deleted" "$PLUGIN_ROOT/commands/lessons-deliver.md"
}

test_lawyer_lifecycle() {
  echo -e "\n${CYAN}Suite V: /lawyer lifecycle guard (in_force/status)${NC}"
  local skill="$PLUGIN_ROOT/skills/lawyer/SKILL.md"
  local ref="$PLUGIN_ROOT/references/lawyer/law-registry.md"
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

test_gate_cli_391
