# Executable context-continuity regressions for workflow-probe.sh.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "workflow-context.tests.sh must be sourced by a test harness" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_context_contract() {
  echo -e "\n${CYAN}Suite WC: workflow context continuity${NC}"
  local fixture root mode ec out calls
  fixture=$(mktemp -d); root=$(mktemp -d); calls="$fixture/gh-calls"
  cp "$PLUGIN_ROOT/scripts/workflow-probe.sh" "$fixture/workflow-probe.sh"
  chmod +x "$fixture/workflow-probe.sh"
  cat > "$fixture/maintain-delivery.sh" <<'SH'
#!/usr/bin/env bash
case "${PENDING_FIXTURE:-empty}" in
  empty) printf '[]\n' ;;
  post_merge) printf '[{"issue_number":7,"delivery_id":"old","state":"post_merge","receipt":"x"}]\n' ;;
  close_intent) printf '[{"issue_number":7,"delivery_id":"old","state":"close_intent","receipt":"x"}]\n' ;;
  multiple) printf '[{"state":"post_merge"},{"state":"close_intent"}]\n' ;;
  malformed) printf '{bad\n' ;;
  failure) exit 1 ;;
esac
SH
  cat > "$fixture/gh" <<'SH'
#!/usr/bin/env bash
: > "$GH_CALLS"
printf '[]\n'
SH
  chmod +x "$fixture/maintain-delivery.sh" "$fixture/gh"

  for mode in maintain maintain-loop; do
    rm -f "$calls"; ec=0
    out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$calls" PENDING_FIXTURE=post_merge \
      bash "$fixture/workflow-probe.sh" "$mode" --root "$root" --dry-run 2>&1) || ec=$?
    assert_exit_code "WC1/$mode: post-merge receipt is launchable for recovery" "$ec" 0
    assert_output_contains "WC2/$mode: recovery diagnostic names issue and state" "$out" \
      'pending receipt: issue #7 (post_merge)'
    assert_file_not_exists "WC3/$mode: pending receipt bypasses new issue probing" "$calls"
  done

  ec=0; out=$(cd "$root" && PATH="$fixture:$PATH" PENDING_FIXTURE=close_intent \
    bash "$fixture/workflow-probe.sh" maintain --root "$root" --dry-run 2>&1) || ec=$?
  assert_exit_code "WC4: pending close receipt launches recovery" "$ec" 0
  assert_output_not_contains "WC5: pending close receipt emits no no-op" "$out" 'no work to do'

  ec=0; out=$(cd "$root" && PATH="$fixture:$PATH" PENDING_FIXTURE=multiple \
    bash "$fixture/workflow-probe.sh" maintain-loop --root "$root" --dry-run 2>&1) || ec=$?
  assert_exit_code "WC6: multiple compatibility receipts fail closed" "$ec" 4
  assert_output_contains "WC7: multiple receipt diagnostic is precise" "$out" \
    'multiple nonterminal maintain-delivery receipts require reconciliation'

  ec=0; out=$(cd "$root" && PATH="$fixture:$PATH" PENDING_FIXTURE=malformed \
    bash "$fixture/workflow-probe.sh" maintain --root "$root" --dry-run 2>&1) || ec=$?
  assert_exit_code "WC8: malformed receipt inventory fails closed" "$ec" 4
  assert_output_contains "WC9: malformed receipt diagnostic is precise" "$out" \
    'maintain-delivery receipt inventory is malformed'

  rm -rf "$fixture" "$root"
}

test_workflow_context_contract
