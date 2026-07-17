# Executable context-continuity regressions for workflow-probe.sh.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "workflow-context.tests.sh must be sourced by a test harness" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_context_contract() {
  echo -e "\n${CYAN}Suite WC: workflow context continuity${NC}"
  local fixture root mode ec out calls maintain_ec loop_ec maintain_out loop_out
  local maintain_calls loop_calls auth_calls branch_count identity_section coordinator_section
  fixture=$(mktemp -d); root=$(mktemp -d); calls="$fixture/gh-calls"
  git init -q "$root"
  cp "$PLUGIN_ROOT/scripts/workflow-probe.sh" "$fixture/workflow-probe.sh"
  chmod +x "$fixture/workflow-probe.sh"
  cat > "$fixture/maintain-delivery.sh" <<'SH'
#!/usr/bin/env bash
case "${PENDING_FIXTURE:-empty}" in
  empty) printf '[]\n' ;;
  claimed|post_merge|close_intent)
    jq -cn --arg state "$PENDING_FIXTURE" --arg worktree "${3:-}/.worktrees/maintain" \
      '[{issue_number:7,delivery_id:"old",state:$state,receipt:"x",
         controller_route:{kind:"canonical",mode:"maintain",worktree:$worktree}}]'
    ;;
  multiple) printf '[{"state":"post_merge"},{"state":"close_intent"}]\n' ;;
  malformed) printf '{bad\n' ;;
  failure) exit 1 ;;
esac
SH
  cat > "$fixture/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
printf '%s\n' "${GH_FIXTURE:-[]}"
SH
  cat > "$fixture/delivery-route.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = schema-version ] && printf '%s\n' '{"schema_version":1}'
SH
  cat > "$fixture/maintain-leases.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  primary-root) printf '%s\n' "$3" ;;
  available) exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$fixture/maintain-blocked.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = active ] && printf '[]\n'
SH
  cat > "$fixture/lease-guardian.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fixture/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "login status" ] || exit 64
printf '%s\n' "$*" >> "$CODEX_CALLS"
[ "${FAKE_CODEX_AUTH_OK:-1}" -eq 1 ]
SH
  chmod +x "$fixture/maintain-delivery.sh" "$fixture/gh" \
    "$fixture/delivery-route.sh" "$fixture/maintain-leases.sh" \
    "$fixture/maintain-blocked.sh" "$fixture/lease-guardian.sh" "$fixture/codex"

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

  # maintain-loop is a compatibility spelling only. Both spellings execute the
  # same maintain branch and fail closed before dispatch without authenticated Codex.
  maintain_calls="$fixture/maintain-calls"; loop_calls="$fixture/loop-calls"
  maintain_ec=0
  maintain_out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$maintain_calls" \
    GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    SAAS_PREFLIGHT_MISSING=codex bash "$fixture/workflow-probe.sh" maintain \
      --root "$root" --repo owner/repo --issue 7 --label ready 2>&1) \
    || maintain_ec=$?
  loop_ec=0
  loop_out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$loop_calls" \
    GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    SAAS_PREFLIGHT_MISSING=codex bash "$fixture/workflow-probe.sh" maintain-loop \
      --root "$root" --repo owner/repo --issue 7 --label ready 2>&1) \
    || loop_ec=$?
  assert_equals "WC10: maintain-loop alias returns the canonical probe status" \
    "$loop_ec" "$maintain_ec"
  assert_exit_code "WC10a: missing Codex blocks the canonical queue" "$maintain_ec" 4
  assert_output_contains "WC10b: missing Codex diagnostic is actionable" "$maintain_out" \
    'Codex CLI not found'
  loop_out=${loop_out//maintain-loop/maintain}
  assert_equals "WC11: maintain-loop alias has canonical output apart from its name" \
    "$loop_out" "$maintain_out"
  assert_equals "WC12: maintain-loop alias makes the canonical GitHub query" \
    "$(cat "$loop_calls")" "$(cat "$maintain_calls")"

  for mode in maintain maintain-loop; do
    auth_calls="$fixture/$mode-auth-failed"; rm -f "$auth_calls"; ec=0
    out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$fixture/$mode-gh-auth-failed" \
      CODEX_CALLS="$auth_calls" FAKE_CODEX_AUTH_OK=0 \
      GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
      bash "$fixture/workflow-probe.sh" "$mode" --root "$root" --issue 7 2>&1) || ec=$?
    assert_exit_code "WC13/$mode: unavailable Codex auth blocks execution" "$ec" 4
    assert_output_contains "WC14/$mode: auth failure is actionable" "$out" \
      'Codex authentication is unavailable'
    assert_file_contains "WC15/$mode: probe checks actual Codex auth" "$auth_calls" \
      '^login status$'

    auth_calls="$fixture/$mode-auth-ok"; rm -f "$auth_calls"; ec=0
    out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$fixture/$mode-gh-auth-ok" \
      CODEX_CALLS="$auth_calls" FAKE_CODEX_AUTH_OK=1 \
      GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
      bash "$fixture/workflow-probe.sh" "$mode" --root "$root" --issue 7 2>&1) || ec=$?
    assert_exit_code "WC16/$mode: authenticated Codex makes execution ready" "$ec" 0
    assert_equals "WC17/$mode: auth is checked exactly once" \
      "$(cat "$auth_calls")" 'login status'

    auth_calls="$fixture/$mode-dry-auth"; rm -f "$auth_calls"; ec=0
    out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$fixture/$mode-gh-dry" \
      CODEX_CALLS="$auth_calls" SAAS_PREFLIGHT_MISSING=codex \
      GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
      bash "$fixture/workflow-probe.sh" "$mode" --root "$root" --issue 7 --dry-run 2>&1) \
      || ec=$?
    assert_exit_code "WC18/$mode: dry-run skips execution prerequisites" "$ec" 0
    assert_file_not_exists "WC19/$mode: dry-run never checks Codex auth" "$auth_calls"

    ec=0
    out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$fixture/$mode-gh-claimed" \
      PENDING_FIXTURE=claimed SAAS_PREFLIGHT_MISSING=codex \
      bash "$fixture/workflow-probe.sh" "$mode" --root "$root" 2>&1) || ec=$?
    assert_exit_code "WC20/$mode: claimed recovery requires Codex" "$ec" 4
    assert_output_contains "WC21/$mode: claimed recovery names missing Codex" "$out" \
      'Codex CLI not found'
  done

  branch_count=$(grep -c '^  maintain-loop)' "$fixture/workflow-probe.sh" || true)
  assert_equals "WC22: workflow probe has only the maintain-loop alias label" \
    "$branch_count" "1"
  branch_count=$(grep -cF '  maintain-loop) MODE=maintain ;;' \
    "$fixture/workflow-probe.sh" || true)
  assert_equals "WC23: maintain-loop normalizes directly to maintain" \
    "$branch_count" "1"

  identity_section=$(awk '/^## Invocation identity and probe/{on=1; next} /^## /{if(on) exit} on' \
    "$PLUGIN_ROOT/references/workflows/maintain.md")
  coordinator_section=$(awk '/^## \/maintain-loop coordinator/{on=1; next} /^## /{if(on) exit} on' \
    "$PLUGIN_ROOT/references/workflows/maintain.md")
  assert_output_contains "WC24: fresh direct maintain resolves its own root command" \
    "$identity_section" 'environment-free direct call records `maintain`'
  assert_output_contains "WC25: fresh loop child resolves the outer root command" \
    "$identity_section" 'child records `maintain-loop`'
  assert_output_contains "WC26: fresh loop dispatch carries an explicit command binding" \
    "$coordinator_section" \
    '--lease-run-id "$SAAS_INVOCATION_ID" --invocation-command maintain-loop'
  assert_output_contains "WC27: conflicting environment and child binding fail closed" \
    "$identity_section" 'value must agree exactly'
  assert_output_contains "WC27a: inherited loop context requires the exact internal binding" \
    "$identity_section" '`maintain-loop` value requires both exact internal arguments'
  assert_file_contains "WC28: generated Codex dispatch retains the child binding" \
    "$PLUGIN_ROOT/skills/maintain-loop/SKILL.md" \
    '--lease-run-id "$SAAS_INVOCATION_ID" --invocation-command maintain-loop'

  rm -rf "$fixture" "$root"
}

test_workflow_context_contract
