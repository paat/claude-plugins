# Static regressions for workflow invocation identity and terminal ownership.
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "workflow-invocation.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_invocation_contract() {
  echo -e "\n${CYAN}Suite WI: workflow invocation identity${NC}"
  local loop_entry maintain_entry loop_skill goal_entry maintain maintain_protocol goal receipts section count
  loop_entry="$PLUGIN_ROOT/commands/maintain-loop.md"
  maintain_entry="$PLUGIN_ROOT/commands/maintain.md"
  loop_skill="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  goal_entry="$PLUGIN_ROOT/commands/goal-deliver.md"
  maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  maintain_protocol="$PLUGIN_ROOT/references/workflows/maintain-protocol.md"
  goal="$PLUGIN_ROOT/references/workflows/goal-deliver.md"
  receipts="$PLUGIN_ROOT/references/workflows/goal-deliver-maintain-receipts.md"

  assert_file_contains "WI1: maintain defines the canonical root identity" "$maintain" \
    '\^run-\[0-9a-f\]{32}\$'
  assert_file_contains "WI2: maintain reuses inherited canonical identity" "$maintain" \
    'Reuse a canonical inherited `SAAS_INVOCATION_ID`'
  section=$(awk '/^## Invocation identity and probe/{on=1; next} /^## /{if(on) exit} on' "$maintain")
  count=$(grep -cF 'agent-events.sh new-run-id' <<< "$section" || true)
  assert_equals "WI3: direct maintain has one root mint point" "$count" "1"
  assert_output_contains "WI4: exact root becomes lease identity" "$section" \
    'MAINTAIN_LEASE_RUN_ID="$SAAS_INVOCATION_ID"'
  assert_output_contains "WI4a: canonical maintain parses the internal command binding" \
    "$section" '--invocation-command maintain-loop'
  assert_output_contains "WI4b: command binding requires the internal lease identity" \
    "$section" 'only with'
  assert_output_contains "WI4c: conflicting command context fails before work" \
    "$section" 'context-binding failure before the probe or mutation'
  assert_output_contains "WI4d: environment-free direct maintain retains its public command" \
    "$section" 'environment-free direct call records `maintain`'
  assert_output_contains "WI4e: environment-free loop child retains its public command" \
    "$section" 'child records `maintain-loop`'
  assert_output_contains "WI4f: internal bindings never contaminate the public probe" \
    "$section" 'never forward either internal argument to the probe'

  section=$(awk '/^## \/maintain-loop coordinator/{on=1; next} /^## /{if(on) exit} on' "$maintain")
  assert_output_contains "WI5: loop preserves a scheduler root unchanged" "$section" \
    'scheduler-provided value unchanged'
  assert_output_contains "WI6: loop passes exact root through lease argument" "$section" \
    '--lease-run-id "$SAAS_INVOCATION_ID"'
  assert_output_contains "WI6a: loop binds its command across the fresh-child boundary" \
    "$section" '--lease-run-id "$SAAS_INVOCATION_ID" --invocation-command maintain-loop'
  assert_output_contains "WI6b: loop does not rely on fresh-child environment inheritance" \
    "$section" 'coordinator environment inheritance across the fresh-child boundary'
  assert_output_contains "WI7: maintain child is sole dispatched root writer" "$section" \
    'child `/maintain` is the sole root'
  assert_output_contains "WI8: coordinator verifies terminal after child exit" "$section" \
    'agent-events.sh terminal --run-id "$SAAS_INVOCATION_ID"'
  assert_output_contains "WI9: post-dispatch missing terminal fails closed" "$section" \
    'every nonzero lookup'
  assert_output_contains "WI10: coordinator never repairs child terminal state" "$section" \
    'never repairs child'
  assert_output_not_contains "WI10a: coordinator has no delivery repair append" "$section" \
    'delivery_failed'
  assert_output_contains "WI10b: failed pre-identity spawn gets a blocked root terminal" \
    "$section" '`blocked/invalid_workflow_state`'
  assert_output_contains "WI10c: returned child identity is the ownership boundary" \
    "$section" 'irrevocable ownership boundary'
  assert_output_contains "WI10d: missing identified child never gets a coordinator terminal" \
    "$section" 'fails closed without appending an event'
  count=$(grep -cF 'agent-events.sh append' <<< "$section" || true)
  assert_equals "WI10e: coordinator defines one shared root append shape" "$count" "1"
  assert_output_contains "WI11: later loop passes get fresh roots" "$section" \
    'never reuse a completed pass root'

  assert_output_contains "WI12a: maintain probe maps exit 3" "$section" 'exit 3 is `no-op`'
  assert_file_contains "WI12b: direct maintain probe records no-op" "$maintain" \
    '`--outcome no-op`'
  assert_file_contains "WI13: maintain probe blocked uses registered reason" "$maintain" \
    'terminal-reason probe_failed'
  assert_output_contains "WI13a: direct maintain always exports lease root" \
    "$(awk '/^## Invocation identity and probe/{on=1; next} /^## /{if(on) exit} on' "$maintain")" \
    'unconditionally after resolution'
  assert_file_contains "WI13b: invocation command has a finite registry" "$maintain" \
    'only `maintain-loop`, `maintain`, and `goal-deliver`'
  assert_output_contains "WI13c: loop binds its outer command in child arguments" "$section" \
    '--invocation-command maintain-loop'
  assert_file_contains "WI14: detailed supervisor owns every handled terminal" \
    "$maintain_protocol" 'path—success, blocked, failure, cancelled, or escalated'
  assert_file_contains "WI15: supervisor appends root only once" "$maintain_protocol" \
    '\-\-phase pass-outcome.*'
  assert_file_contains "WI16: dry-run emits no events" "$maintain_protocol" \
    'Under `--dry-run`, do not append a root or child event'

  section=$(awk '/\*\*Persist an atomic audit\/context-continuity marker/{on=1} /^## Triage/{if(on) exit} on' "$maintain_protocol")
  assert_output_contains "WI17: current-run writes exact invocation identity" "$section" \
    '"$SAAS_INVOCATION_ID"'
  assert_output_contains "WI18: same-ID current-run is reused" "$section" \
    'Same-ID in-process/context recovery'
  assert_output_contains "WI19: different old current-run is archived" "$section" \
    'archived-$(date -u'
  assert_output_not_contains "WI20: current-run does not mint a second ID" "$section" \
    'new-run-id'
  assert_output_not_contains "WI21: current-run has no six-hour age remint" "$section" \
    '21600'
  assert_output_contains "WI21a: current-run writes atomically" "$section" \
    'mktemp .startup/maintain/.current-run.XXXXXX'
  assert_output_contains "WI21b: current-run is not restart authority" "$section" \
    'not a restart mechanism'

  assert_file_contains "WI22: goal defines maintain embedded caller" "$goal" \
    'SAAS_EMBEDDED_CALLER=maintain'
  assert_file_contains "WI23: embedded caller requires inherited root" "$goal" \
    'must inherit an already'
  for section in SAAS_EMBEDDED_WORKTREE SAAS_EMBEDDED_CLAIM \
    SAAS_EMBEDDED_LEASE_STATE SAAS_EMBEDDED_REMAINING_SECONDS; do
    assert_file_contains "WI24: embedded caller requires $section" "$goal" "$section"
  done
  assert_file_contains "WI25: embedded skips primary checkout gate" "$goal" \
    'skip this standalone primary-checkout gate'
  assert_file_contains "WI26: embedded skips second delivery lease" "$goal" \
    'skips this second delivery-scope lease acquisition'
  assert_file_contains "WI27: standalone goal owns one root terminal" "$goal" \
    'standalone `/goal-deliver` is the sole writer for its root'
  assert_file_contains "WI28: embedded goal never writes root terminal" "$goal" \
    '`/goal-deliver` never writes a root pass outcome'
  assert_file_contains "WI29: child events bind to the root" "$goal" \
    '\-\-parent-run-id "$SAAS_INVOCATION_ID"'
  assert_file_contains "WI30: delivery attempts mint fresh child IDs" "$goal" \
    'For each delivery attempt, including a retry, mint a fresh child ID'
  assert_file_contains "WI31: root totals do not aggregate children" "$goal" \
    'never computed from child events'
  assert_file_contains "WI31a: standalone goal defaults its invocation command" "$goal" \
    'defaults an absent value to `goal-deliver`'
  assert_file_contains "WI31b: resumed claim need not equal current root" "$goal" \
    'marker ID to equal'
  assert_file_contains "WI31c: embedded PR references do not auto-close" "$goal" \
    'non-closing issue reference such as `Refs #N`'
  assert_file_contains "WI31d: embedded close waits for release proof" "$receipts" \
    'Release proof must exist before issue close intent'
  assert_file_contains "WI31e: embedded resume never opens replacement PR" "$goal" \
    'replacement PR'
  assert_file_contains "WI31f: maintain references canonical embedded invariants" "$maintain" \
    'goal-deliver.md` §Delivery safety invariants'
  assert_file_contains "WI31g: receipt origin may differ from the active controller" "$receipts" \
    'may differ from `CONTROLLER_RUN_ID`'
  assert_file_contains "WI31h: child identity differs from origin and controller" "$receipts" \
    'origin and controller'
  assert_file_contains "WI31i: embedded worker parents telemetry to the current controller" \
    "$receipts" '`CONTROLLER_RUN_ID` in `SAAS_PARENT_RUN_ID`'
  assert_file_contains "WI31j: embedded worker preserves the inherited command" "$receipts" \
    '`INVOCATION_COMMAND` in `SAAS_INVOCATION_COMMAND`'

  assert_file_contains "WI32: loop entrypoint loads canonical reference" "$loop_entry" \
    'references/workflows/maintain.md'
  assert_file_contains "WI33: maintain entrypoint loads canonical reference" "$maintain_entry" \
    'references/workflows/maintain.md'
  assert_file_contains "WI34: goal entrypoint keeps sole delivery reference" "$goal_entry" \
    'sole delivery contract'
  assert_file_contains "WI34a: generated Codex loop retains the mechanical child binding" \
    "$loop_skill" '--lease-run-id "$SAAS_INVOCATION_ID" --invocation-command maintain-loop'
  for section in 'tribunal-review' 'gh pr merge' 'poll-gate.sh' 'single-flight.sh' \
    'invalid_workflow_state' 'root-terminal ownership'; do
    assert_file_not_contains "WI35: loop entrypoint does not duplicate $section" \
      "$loop_entry" "$section"
  done
}

test_workflow_invocation_contract
