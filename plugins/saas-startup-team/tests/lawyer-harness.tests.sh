# Sourced by run-tests.sh's discovered-suite loop. The lawyer skill's own
# test-*.sh files live under skills/lawyer/tests/ and are run by their own
# harness.sh — this shim makes that harness's pass/fail visible to the main
# runner, which otherwise has no path to them.
echo -e "${CYAN}Testing: lawyer skill test harness${NC}"
lh_ec=0
bash "$PLUGIN_ROOT/skills/lawyer/tests/harness.sh" >/dev/null 2>&1 || lh_ec=$?
assert_exit_code "LH1: lawyer skill test harness passes" "$lh_ec" 0

lawyer_skill=$(<"$PLUGIN_ROOT/skills/lawyer/SKILL.md")
lawyer_registry=$(<"$PLUGIN_ROOT/skills/lawyer/references/law-registry.md")
assert_file_contains "LH2: autonomous topic has an early disposition" "$PLUGIN_ROOT/commands/lawyer.md" "### Non-interactive / autonomous disposition"
assert_file_contains "LH3: autonomous topic skips backlog expansion" "$PLUGIN_ROOT/commands/lawyer.md" "Skip Marker Scan, Invariant Check"
assert_file_contains "LH4: autonomous topic continues requested analysis" "$PLUGIN_ROOT/commands/lawyer.md" 'Continue directly to'
assert_file_contains "LH5: pending flags remain durable" "$PLUGIN_ROOT/commands/lawyer.md" 'The flags remain durable in `.startup/law-registry.json`'
assert_file_contains "LH6: issue creation remains explicit" "$PLUGIN_ROOT/commands/lawyer.md" "Issue creation still requires an explicit subcommand"
assert_file_contains "LH7: flagged topic dependency requires primary evidence" "$PLUGIN_ROOT/commands/lawyer.md" "re-verify it from Tier A before using it"
assert_output_contains "LH8: domain skill matches autonomous routing" "$lawyer_skill" "Non-interactive topic runs report the"
assert_output_contains "LH9: registry state machine documents non-blocking autonomous topics" "$lawyer_registry" "non-interactive topic warns once and continues"
assert_file_contains "LH10: context gathering is topic-targeted" "$PLUGIN_ROOT/commands/lawyer.md" "Do not inventory or load the newest files across every docs area"
assert_output_contains "LH11: workflow activates extra research conditionally" "$lawyer_skill" "Activate extra research only when the topic needs it"
assert_output_contains "LH12: workflow exits after sufficient evidence" "$lawyer_skill" "Stop when the requested decision has enough evidence."
assert_output_contains "LH13: workflow rejects ellipsized primary quotes" "$lawyer_skill" '`...`, `…`, `[...]`, and `[…]`'
assert_output_contains "LH14: output is bounded to a concise decision brief" "$lawyer_skill" "at or below 150 lines"
assert_output_contains "LH15: blocking human actions must match frontmatter" "$lawyer_skill" 'verbatim in `blocking_human_tasks`'
assert_file_contains "LH16: Claude agent delegates to shared targeted workflow" "$PLUGIN_ROOT/agents/lawyer.md" 'Read `skills/lawyer/SKILL.md`'
assert_file_contains "LH17: command names deterministic structural validation" "$PLUGIN_ROOT/commands/lawyer.md" 'legal-verdict-gate.sh'
assert_file_contains "LH18: command enables validation mode" "$PLUGIN_ROOT/commands/lawyer.md" '--validate'
assert_file_exists "LH19: deterministic lawyer preflight exists" "$PLUGIN_ROOT/scripts/lawyer-preflight.sh"
lh_ec=0; bash -n "$PLUGIN_ROOT/scripts/lawyer-preflight.sh" || lh_ec=$?
assert_exit_code "LH20: lawyer preflight parses" "$lh_ec" 0
assert_output_contains "LH21: read-only probes override document writes" "$lawyer_skill" "decision in chat instead of writing the default document"
assert_output_contains "LH22: read-only project inspection is bounded" "$lawyer_skill" "at most three targeted source ranges"
assert_output_contains "LH23: incomplete probes terminate with a decision" "$lawyer_skill" 'partial `UNCONFIRMED`'
assert_file_contains "LH24: EUR-Lex article endpoint is documented" "$PLUGIN_ROOT/skills/lawyer/references/datalake-api.md" '/eurlex/{celex}/citation?article=N&language=EN'
assert_output_contains "LH25: bounded probes skip API inventory" "$lawyer_skill" "Never inventory"
assert_output_contains "LH26: bounded probes do not resume broad search" "$lawyer_skill" "Never resume repository-wide searches"
assert_file_contains "LH27: EU citation requires lifecycle evidence" "$PLUGIN_ROOT/skills/lawyer/references/datalake-api.md" 'Require `in_force == true`; preserve the'
assert_file_contains "LH28: EU citation preserves primary source" "$PLUGIN_ROOT/skills/lawyer/references/datalake-api.md" 'returned HTTPS `source_url`'
assert_output_contains "LH29: proposal probes skip product inspection" "$lawyer_skill" "Proposal/risk questions do not justify"
assert_output_contains "LH30: bounded probes prohibit delegation" "$lawyer_skill" "never delegate or spawn subagents"
assert_output_contains "LH31: current-code requests retain inspection" "$lawyer_skill" "compliance is explicitly requested or the user names files"
