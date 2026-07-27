# Parity fixtures for founder → capability skills (#385).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "capability-skills-parity.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_capability_skills_parity() {
  echo -e "\n${CYAN}Suite CS: capability skills parity (#385)${NC}"
  local pd="$PLUGIN_ROOT/skills/product-discovery/SKILL.md"
  local pa="$PLUGIN_ROOT/skills/product-acceptance/SKILL.md"
  local gr="$PLUGIN_ROOT/skills/growth/SKILL.md"
  local ux="$PLUGIN_ROOT/skills/ux-review/SKILL.md"
  local law="$PLUGIN_ROOT/skills/lawyer/SKILL.md"
  local del="$PLUGIN_ROOT/skills/deliver/SKILL.md"

  for f in "$pd" "$pa" "$gr" "$ux" "$law" "$del"; do
    assert_file_exists "CS: $(basename $(dirname $f)) skill exists" "$f"
  done

  for skill in "$pd" "$pa" "$gr" "$ux"; do
    assert_file_contains "CS: $(basename $(dirname $skill)) has Triggers" "$skill" '## Triggers'
    assert_file_contains "CS: $(basename $(dirname $skill)) has Inputs" "$skill" '## Inputs'
    assert_file_contains "CS: $(basename $(dirname $skill)) has Mutation boundary" "$skill" '## Mutation boundary'
    assert_file_contains "CS: $(basename $(dirname $skill)) has Outputs" "$skill" '## Outputs'
    assert_file_not_contains "CS: no color pin in $(basename $(dirname $skill))" "$skill" 'color:'
    assert_file_not_contains "CS: no model pin in $(basename $(dirname $skill))" "$skill" 'model:'
  done

  assert_file_contains "CS: lawyer evidence tiers" "$law" 'Evidence-Tier Policy'
  assert_file_contains "CS: growth spend/ads policy" "$gr" 'envelope'
  assert_file_contains "CS: ux evidence contract" "$ux" 'Browser Evidence Contract'
  assert_file_contains "CS: product-acceptance independent" "$pa" 'Independent of the implementation'
  assert_file_contains "CS: technical delivery is deliver" "$del" 'founder personas'
  assert_file_contains "CS: product-discovery not unconditional research" "$pd" 'unconditional market research'

  for persona in business-founder.md business-founder-maintain.md \
      tech-founder-claude.md tech-founder-claude-maintain.md \
      growth-hacker.md ux-tester.md; do
    assert_file_not_exists "CS: deleted persona $persona" "$PLUGIN_ROOT/agents/$persona"
  done

  assert_file_not_exists "CS: /ads command removed" "$PLUGIN_ROOT/commands/ads.md"
  assert_file_not_exists "CS: ads workflow alias removed" \
    "$PLUGIN_ROOT/skills/saas-startup-team-ads-workflow/SKILL.md"
  assert_file_contains "CS: growth links ads capability" "$gr" 'google-ads-strategist'
  assert_file_not_contains "CS: entrypoints has no ads" \
    "$PLUGIN_ROOT/integrity/entrypoints.json" '"name": "ads"'

  assert_file_contains "CS: startup uses product-discovery" \
    "$PLUGIN_ROOT/commands/startup.md" 'skills/product-discovery'
  assert_file_contains "CS: startup uses product-acceptance" \
    "$PLUGIN_ROOT/commands/startup.md" 'skills/product-acceptance'
  assert_file_not_contains "CS: startup no business-founder agent type" \
    "$PLUGIN_ROOT/commands/startup.md" 'saas-startup-team:business-founder'
  assert_file_not_contains "CS: startup no tech-founder-claude type" \
    "$PLUGIN_ROOT/commands/startup.md" 'tech-founder-claude'
}

test_capability_skills_parity
