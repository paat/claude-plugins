# Parity fixtures for the canonical deliver skill (#384).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "deliver-parity.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_deliver_parity() {
  echo -e "\n${CYAN}Suite DP: canonical deliver skill parity${NC}"
  local skill="$PLUGIN_ROOT/skills/deliver/SKILL.md"
  local graph="$PLUGIN_ROOT/references/delivery-playbook.md"
  local entry="$PLUGIN_ROOT/references/delivery-playbook.md"
  local light="$PLUGIN_ROOT/references/delivery-playbook.md"
  local multi="$PLUGIN_ROOT/references/delivery-playbook.md"
  local improve_cmd="$PLUGIN_ROOT/commands/improve.md"
  local goal_cmd="$PLUGIN_ROOT/commands/goal-deliver.md"
  local tweak_cmd="$PLUGIN_ROOT/commands/tweak.md"
  local startup_cmd="$PLUGIN_ROOT/commands/startup.md"
  local graph_phrase="Preflight → Plan → Isolated Build → Independent Review → Release → Report"

  assert_file_exists "DP1: deliver skill exists" "$skill"
  assert_file_exists "DP2: deliver graph exists" "$graph"
  assert_file_exists "DP3: entrypoints config exists" "$entry"
  assert_file_exists "DP4: light-path config exists" "$light"
  assert_file_exists "DP5: multi-unit config exists" "$multi"

  assert_file_contains "DP6: skill loads graph" "$skill" '../../references/delivery-playbook.md'
  assert_file_contains "DP7: graph names the delivery graph" "$graph" "$graph_phrase"
  assert_file_contains "DP8: Done/Preserve/Out of Scope" "$graph" 'Out of Scope'
  assert_file_contains "DP9: triggered SaaS gates" "$graph" 'triggered-saas-gates.md'
  assert_file_contains "DP10: check.sh test evidence" "$graph" './check.sh'
  assert_file_contains "DP11: honest incomplete/blocked outcomes" "$graph" '| `blocked` |'
  assert_file_contains "DP12: exact PR/head binding" "$graph" 'Exact PR/head binding'
  assert_file_contains "DP13: fresh check revalidation" "$graph" 'Fresh check revalidation'
  assert_file_contains "DP14: SHA-pinned merge" "$graph" '--match-head-commit'
  assert_file_contains "DP15: deployment/live proof" "$graph" 'Deployment/live proof'
  assert_file_contains "DP16: close observation" "$graph" 'Close observation'
  assert_file_contains "DP17: idempotent post-merge recovery" "$graph" 'Idempotent post-merge recovery'

  assert_file_contains "DP18: no persona requirement" "$skill" 'require founder personas'
  assert_file_contains "DP19: no state.json requirement" "$skill" '.startup/state.json'
  assert_file_not_contains "DP20: skill does not mandate active_role mutation"     "$skill" '.active_role ='
  assert_file_not_contains "DP21: graph does not mandate active_role mutation"     "$graph" '.active_role ='

  for cmd in "$improve_cmd" "$goal_cmd" "$tweak_cmd"; do
    assert_file_contains "DP22: $(basename "$cmd") is generated alias" "$cmd" 'GENERATED-ALIAS'
    assert_file_contains "DP23: $(basename "$cmd") loads deliver skill" "$cmd" 'skills/deliver/SKILL.md'
  done
  assert_file_contains "DP25: startup is generated alias" "$startup_cmd" 'GENERATED-ALIAS'
  assert_file_contains "DP26: startup loads lifecycle skill" "$startup_cmd" 'skills/lifecycle/SKILL.md'

  assert_file_contains "DP27: entrypoints share SKILL graph" "$entry"     'All share `skills/deliver/SKILL.md` graph phases'
  assert_file_contains "DP28: tweak is bounded fast-path only" "$entry"     'bounded light fast-path only'
  assert_file_contains "DP29: improve is single unit" "$entry" 'single improvement cycle'
  assert_file_contains "DP30: goal-deliver is multi-unit" "$entry" 'multi-unit delivery'
  assert_file_contains "DP31: startup-impl skips solution-signoff" "$entry" 'solution-signoff and PR/merge'

  assert_file_not_exists "DP32: old improve playbook removed"     "$PLUGIN_ROOT/references/workflows/improve.md"
  assert_file_not_exists "DP33: old goal-deliver playbook removed"     "$PLUGIN_ROOT/references/workflows/goal-deliver.md"
  assert_file_not_exists "DP34: old tweak playbook removed"     "$PLUGIN_ROOT/references/workflows/tweak.md"

  for cmd in "$improve_cmd" "$goal_cmd" "$tweak_cmd"; do
    assert_file_contains "DP35: $(basename "$cmd") transitional" "$cmd" 'transitional: true'
    assert_file_not_contains "DP36: $(basename "$cmd") has no SHA-pinned merge policy"       "$cmd" '--match-head-commit'
  done

  assert_file_contains "DP37: improve Codex alias → command"     "$PLUGIN_ROOT/skills/saas-startup-team-improve-workflow/SKILL.md"     '../../skills/deliver/SKILL.md'
  assert_file_contains "DP38: goal-deliver Codex alias → command"     "$PLUGIN_ROOT/skills/saas-startup-team-goal-deliver-workflow/SKILL.md"     '../../skills/deliver/SKILL.md'
  assert_file_contains "DP39: tweak Codex alias → command"     "$PLUGIN_ROOT/skills/saas-startup-team-tweak-workflow/SKILL.md"     '../../skills/deliver/SKILL.md'

  # Same delivery graph phase order for all entrypoints (bounded skips only).
  assert_file_contains "DP40: graph states shared phase order" "$graph" \
    'Every entrypoint uses this same phase order'
  for ep in improve goal-deliver tweak startup-impl; do
    assert_file_contains "DP41: entrypoints.md defines $ep" "$entry" "\`$ep\`"
  done
  assert_file_contains "DP42: improve does not merge" "$entry" 'Never merge'
  assert_file_contains "DP43: tweak never merges" "$entry" 'never merge'
  assert_file_contains "DP44: goal-deliver merges after tribunal" "$entry" 'SHA-pinned merge'
  assert_file_contains "DP45: startup-impl skips merge" "$entry" 'solution-signoff and PR/merge'
  # Authority independent of personas/state: no active_role assignment in graph/skill
  assert_file_not_contains "DP46: graph has no active_role assignment" "$graph" '.active_role ='
  assert_file_not_contains "DP47: entrypoints has no mandatory active_role write" \
    "$entry" '.active_role ='
}

test_deliver_parity
