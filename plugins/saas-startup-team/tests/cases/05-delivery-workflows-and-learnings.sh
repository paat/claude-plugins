#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.


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
# Suite Y: Workflow registry and triggered SaaS gates
# ---------------------------------------------------------------------------

test_workflow_registry_and_gates() {
  echo -e "\n${CYAN}Suite Y: Workflow/gate guidance${NC}"

  # Workflow registry.
  assert_file_exists "Y14: workflow registry template exists" "$PLUGIN_ROOT/templates/workflow-registry.md"
  assert_file_exists "Y15: workflow spec template exists" "$PLUGIN_ROOT/templates/workflow-spec.md"
  assert_file_contains "Y16: bootstrap creates workflow registry" "$PLUGIN_ROOT/skills/bootstrap/SKILL.md" ".startup/workflows/registry.md"
  assert_file_contains "Y17: lifecycle uses bootstrap scaffold" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "/bootstrap"
  assert_file_contains "Y18: improve reads workflow registry" "$PLUGIN_ROOT/references/delivery-playbook.md" ".startup/workflows/registry.md"
  assert_file_contains "Y19: lifecycle does not force numbered handoffs" "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "numbered conversational handoffs"

  # Config and README.
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

test_sourced_suite_print_lint() {
  echo -e "\n${CYAN}Suite: sourced suite print lint (#477)${NC}"
  local fixture_dir="$PLUGIN_ROOT/fixtures/sourced-suite-print-lint"
  local output ec=0

  output=$(lint_sourced_suite_prints "$fixture_dir" 2>&1) || ec=$?
  assert_exit_code "L1: lint rejects print-without-TOTAL_COUNT fixture" "$ec" 1
  assert_output_contains "L2: lint reports a named error" "$output" "SOURCED SUITE PRINT LINT"

  ec=0
  lint_sourced_suite_prints "$PLUGIN_ROOT/tests" || ec=$?
  assert_exit_code "L3: all sourced suites pass print counter lint" "$ec" 0
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


test_lessons_deliver() {
  echo -e "\n${CYAN}Suite L: lessons-deliver removed (#390)${NC}"
  assert_file_not_exists "L1: lessons-deliver.sh deleted" "$PLUGIN_ROOT/scripts/lessons-deliver.sh"
  assert_file_not_exists "L2: lessons-deliver command deleted" "$PLUGIN_ROOT/commands/lessons-deliver.md"
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


test_goal_deliver
test_ads_delegation
test_workflow_registry_and_gates
test_session_insights
test_harvest
test_sourced_suite_print_lint
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
