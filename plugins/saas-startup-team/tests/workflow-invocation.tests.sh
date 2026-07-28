# Static regressions for workflow invocation identity (post #389).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "workflow-invocation.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_invocation_contract() {
  echo -e "\n${CYAN}Suite WI: workflow invocation identity${NC}"
  local loop_entry maintain_entry goal_entry maintain goal deliver receipts v3 drain

  loop_entry="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  maintain_entry="$PLUGIN_ROOT/commands/maintain.md"
  goal_entry="$PLUGIN_ROOT/skills/deliver/SKILL.md"
  maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  goal="$PLUGIN_ROOT/references/delivery-playbook.md"
  deliver="$PLUGIN_ROOT/skills/deliver/SKILL.md"
  receipts="$PLUGIN_ROOT/references/workflows/goal-deliver-maintain-receipts.md"
  v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  drain="$PLUGIN_ROOT/scripts/legacy-drain.sh"

  assert_file_exists "WI1: maintain-v3" "$v3"
  assert_file_exists "WI2: legacy-drain" "$drain"
  assert_file_contains "WI3: maintain contract uses v3 tick" "$maintain" 'maintain-v3.sh'
  assert_file_contains "WI4: maintain command loads skill" "$maintain_entry" 'skills/maintain'
  assert_file_contains "WI5: loop probes maintain" "$loop_entry" 'workflow-probe.sh maintain'
  assert_file_contains "WI6: loop prefers v3" "$loop_entry" 'maintain-v3.sh'
  assert_file_contains "WI7: exit 3 is no-op" "$maintain" 'exit 3 is `no-op`'
  assert_file_contains "WI8: once bounds child" "$maintain" '`--once` launches at most one child'
  assert_file_contains "WI9: short locks only" "$maintain" 'Short locks only'
  assert_file_contains "WI10: no claims" "$maintain" 'No claims'
  assert_file_not_contains "WI11: no maintain-leases" "$maintain" 'maintain-leases.sh'
  assert_file_not_contains "WI12: no single-flight" "$maintain" 'single-flight.sh'
  assert_file_contains "WI13: drain inventory" "$maintain" 'legacy-drain.sh'
  assert_file_contains "WI14: source intact until verify" "$maintain" 'stay intact until verify'

  assert_file_contains "WI15: goal-deliver embedded isolation" "$goal" 'SAAS_EMBEDDED_WORKTREE'
  assert_file_contains "WI16: embedded from maintain-v3" "$goal" 'maintain-v3.sh isolate'
  assert_file_not_contains "WI17: no claim marker binding" "$goal" 'maintain:claim:'
  assert_file_not_contains "WI18: no lease state binding" "$goal" 'SAAS_EMBEDDED_LEASE_STATE'
  assert_file_contains "WI19: release-facts not receipts" "$goal" 'release-facts'
  assert_file_contains "WI20: no hard-reset primary" "$goal" 'hard-reset'
  assert_file_contains "WI21: deliver skill exists" "$deliver" 'Plan'
  assert_file_contains "WI22: receipts retired" "$receipts" 'removed in #389'
  assert_file_contains "WI23: never open replacement PR" "$receipts" 'Never open a replacement PR'
  assert_file_contains "WI24: re-prove head" "$receipts" 'Do not trust an earlier green check'

  assert_file_contains "WI32: loop entrypoint loads canonical reference" "$loop_entry" \
    'references/workflows/maintain.md'
  # maintain command is skill-thin; skill points at maintain-v3 contract
  assert_file_contains "WI33: maintain skill contract" \
    "$PLUGIN_ROOT/skills/maintain/SKILL.md" 'maintain-policy.md'
  assert_file_contains "WI34: goal entrypoint keeps sole delivery reference" "$goal_entry" \
    'sole delivery contract'
  assert_file_contains "WI34a: loop prefers maintain-v3" \
    "$loop_entry" 'maintain-v3.sh'
  for section in 'tribunal-review' 'gh pr merge' 'poll-gate.sh' 'single-flight.sh' \
    'maintain-leases.sh' 'invalid_workflow_state' 'root-terminal ownership'; do
    assert_file_not_contains "WI35: loop entrypoint does not duplicate $section" \
      "$loop_entry" "$section"
  done
}

test_workflow_invocation_contract
