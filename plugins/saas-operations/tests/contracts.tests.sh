test_operations_contracts() {
  local al
  # E6a-E6b: the optional browser MCP remains configured without alwaysLoad.
  assert_json_valid "E6a: .mcp.json is valid JSON" "$PLUGIN_ROOT/.mcp.json"
  # #391: unconditional alwaysLoad removed
  al=$(jq -r '.mcpServers.playwright.alwaysLoad // "absent"' "$PLUGIN_ROOT/.mcp.json")
  assert_equals "E6b: Playwright not alwaysLoad" "$al" "absent"

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

  assert_file_contains "Y20: example has operate block" "$PLUGIN_ROOT/saas-operations.local.md.example" "operate:"
  assert_file_contains "Y21: README documents operate command" "$PLUGIN_ROOT/README.md" "/saas-operations:operate"
  assert_file_exists "MV3-3: operate skill exists" "$PLUGIN_ROOT/skills/operate/SKILL.md"
  assert_file_contains "MV3-7: operate modes table" "$PLUGIN_ROOT/skills/operate/SKILL.md" 'investigate'
  assert_file_contains "MV3-8: scheduling outside prompts" "$PLUGIN_ROOT/skills/operate/SKILL.md" 'outside'
  assert_file_contains "MV3-56: operate command loads skill" \
    "$PLUGIN_ROOT/commands/operate.md" 'skills/operate'
  assert_file_contains "MV3-57: monitor routes to operate" \
    "$PLUGIN_ROOT/commands/monitor.md" 'skills/operate'
  assert_file_contains "MV3-58: investigate routes to operate" \
    "$PLUGIN_ROOT/commands/investigate.md" 'skills/operate'
  assert_file_contains "MV3-59: replay routes to operate" \
    "$PLUGIN_ROOT/commands/replay-abandoned.md" 'skills/operate'
  assert_file_contains "MV3-62b: monitor-nightly scheduling outside" \
    "$PLUGIN_ROOT/skills/monitor-nightly/SKILL.md" 'Scheduling lives outside'
  # monitor-nightly slimmed
  assert_file_contains "EC30: monitor cron moved" \
    "$PLUGIN_ROOT/skills/monitor-nightly/SKILL.md" 'monitor-nightly-cron.md'
  assert_file_exists "EC31: cron doc" "$PLUGIN_ROOT/docs/legacy/monitor-nightly-cron.md"

  assert_file_contains "J-gh-skill: NEW issues other than plugin-defect pass the filing gate" \
    "$PLUGIN_ROOT/skills/issue-file/SKILL.md" 'Every NEW issue other than a plugin-defect report passes the filing gate'
  assert_file_contains "J-gh-skill: filing-gate fallback covers open issues" \
    "$PLUGIN_ROOT/skills/issue-file/SKILL.md" 'already covers the outcome'
  assert_file_contains "J-gh-skill: gate comment passes pii-gate" \
    "$PLUGIN_ROOT/skills/issue-file/SKILL.md" 'pii-gate'
}

test_operations_contracts
