# Workflow-level lifecycle/state safety regressions (post #389).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "workflow-lifecycle.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_lifecycle_safety() {
  echo -e "\n${CYAN}Suite WL: workflow lifecycle safety${NC}"
  local goal_entrypoints goal_light maintain maintain_protocol maintain_receipts
  local maintain_proof_contract maintain_loop_entry mutation_ownership startup v3 drain

  goal_entrypoints="$PLUGIN_ROOT/references/delivery-playbook.md"
  goal_light="$PLUGIN_ROOT/references/delivery-playbook.md"
  maintain="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  maintain_protocol="$PLUGIN_ROOT/docs/legacy/maintain-protocol.md"
  maintain_receipts="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  maintain_proof_contract="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  maintain_loop_entry="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  mutation_ownership="$PLUGIN_ROOT/references/delivery-playbook.md"
  startup="$PLUGIN_ROOT/skills/lifecycle/SKILL.md"
  v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  drain="$PLUGIN_ROOT/scripts/legacy-drain.sh"

  assert_file_exists "WL1: maintain-v3 engine" "$v3"
  assert_file_exists "WL2: legacy-drain" "$drain"
  assert_file_not_exists "WL3: maintain-delivery deleted" \
    "$PLUGIN_ROOT/scripts/maintain-delivery.sh"
  assert_file_not_exists "WL4: maintain-attempt deleted" \
    "$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  assert_file_not_exists "WL5: maintain-escalation deleted" \
    "$PLUGIN_ROOT/scripts/maintain-escalation.sh"
  assert_file_not_exists "WL6: lease-guardian deleted" \
    "$PLUGIN_ROOT/scripts/lease-guardian.sh"
  assert_file_not_exists "WL7: single-flight deleted" \
    "$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_not_exists "WL8: maintain-leases deleted" \
    "$PLUGIN_ROOT/scripts/maintain-leases.sh"

  assert_file_contains "WL9: entrypoints no whole-pass lease" "$goal_entrypoints" \
    'no whole-pass lease'
  assert_file_contains "WL10: light path no primary hard-reset" "$goal_light" \
    'Never hard-reset the primary'
  assert_file_contains "WL11: maintain uses v3" "$maintain" 'maintain-v3.sh'
  assert_file_contains "WL12: maintain drain path" "$maintain" 'legacy-drain.sh'
  assert_file_contains "WL13: protocol archive still linked" "$maintain_protocol" \
    'Whole-Pass Lease'
  assert_file_contains "WL14: receipts retired pointer" "$maintain_receipts" \
    'removed in #389'
  assert_file_contains "WL15: proof via release-facts" "$maintain_proof_contract" \
    'release-facts'
  assert_file_contains "WL16: loop prefers v3" \
    "$PLUGIN_ROOT/skills/maintain-loop/SKILL.md" 'maintain-v3.sh'
  assert_file_contains "WL17: mutation ownership file exists" "$mutation_ownership" \
    'Workers edit product source'
  assert_file_contains "WL18: lifecycle no single-flight" "$startup" 'No whole-pass session lease'
  assert_file_not_contains "WL19: lifecycle has no single-flight.sh" "$startup" 'single-flight.sh'
  assert_file_contains "WL20: cancel no primary reset" "$startup" \
    'without resetting the primary checkout'
}

test_workflow_lifecycle_safety
