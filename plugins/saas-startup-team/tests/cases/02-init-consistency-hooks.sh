#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

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
  assert_file_not_exists "H13: lawyer ships as its own plugin" \
    "$PLUGIN_ROOT/skills/lawyer/SKILL.md"
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
  assert_file_contains "J-gh-ref: plugin-defect reports bypass filing gate" \
    "$PLUGIN_ROOT/templates/plugin-issue-reporting.md" 'bypass the should-this-be-filed gate'

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


test_stop_hook
test_startup_init
test_cross_file_consistency
test_post_tool_use_hook
test_plugin_issues
test_auto_commit_hook
