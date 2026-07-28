# Executable context-continuity regressions for workflow-probe.sh (v3, #389).
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "workflow-context.tests.sh must be sourced by a test harness" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_context_contract() {
  echo -e "\n${CYAN}Suite WC: workflow context continuity${NC}"
  local fixture root ec out maintain_ec loop_ec maintain_calls loop_calls
  fixture=$(mktemp -d); root=$(mktemp -d)
  git init -q "$root"
  git -C "$root" config user.email t@t.t
  git -C "$root" config user.name t
  printf 'base\n' > "$root/app.txt"
  git -C "$root" add app.txt
  git -C "$root" commit -q -m base
  cp "$PLUGIN_ROOT/scripts/workflow-probe.sh" "$fixture/workflow-probe.sh"
  cp "$PLUGIN_ROOT/scripts/maintain-paths.sh" "$fixture/maintain-paths.sh"
  # legacy-drain inventory empty for fixture
  cat > "$fixture/legacy-drain.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":1,"engine":"legacy-drain","summary":{"total":0,"recoverable":0,"unresolved":0,"terminal":0,"drained":0},"items":[]}'
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
  cat > "$fixture/maintain-blocked.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = active ] && printf '[]\n'
SH
  cat > "$fixture/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "login status" ] || exit 64
printf '%s\n' "$*" >> "$CODEX_CALLS"
[ "${FAKE_CODEX_AUTH_OK:-1}" -eq 1 ]
SH
  chmod +x "$fixture/workflow-probe.sh" "$fixture/legacy-drain.sh" "$fixture/gh" \
    "$fixture/delivery-route.sh" "$fixture/maintain-blocked.sh" "$fixture/codex"

  # Empty open issues → no-op (exit 3)
  ec=0
  out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$fixture/c1" GH_FIXTURE='[]' \
    SAAS_PREFLIGHT_MISSING=codex bash "$fixture/workflow-probe.sh" maintain \
    --root "$root" --dry-run 2>&1) || ec=$?
  assert_exit_code "WC1: empty issues is no-op" "$ec" 3
  assert_output_contains "WC2: no-op message" "$out" 'no work to do'

  # Open issue + missing codex → blocked 4
  maintain_calls="$fixture/maintain-calls"
  maintain_ec=0
  out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$maintain_calls" \
    GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    SAAS_PREFLIGHT_MISSING=codex bash "$fixture/workflow-probe.sh" maintain \
      --root "$root" --repo owner/repo --issue 7 2>&1) \
    || maintain_ec=$?
  assert_exit_code "WC3: missing codex blocks launch" "$maintain_ec" 4

  loop_calls="$fixture/loop-calls"
  loop_ec=0
  out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$loop_calls" \
    GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    SAAS_PREFLIGHT_MISSING=codex bash "$fixture/workflow-probe.sh" maintain-loop \
      --root "$root" --repo owner/repo --issue 7 2>&1) \
    || loop_ec=$?
  assert_equals "WC4: maintain-loop alias same status as maintain" "$loop_ec" "$maintain_ec"

  # Open issue + dry-run skips codex gate → ready 0
  ec=0
  out=$(cd "$root" && PATH="$fixture:$PATH" GH_CALLS="$fixture/c2" \
    GH_FIXTURE='[{"number":7,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    bash "$fixture/workflow-probe.sh" maintain --root "$root" --dry-run 2>&1) || ec=$?
  assert_exit_code "WC5: dry-run with open issue is ready" "$ec" 0
  assert_output_contains "WC6: work available" "$out" 'work available'

  # No lease/guardian scripts required
  assert_file_not_exists "WC7: no maintain-leases in fixture path" \
    "$PLUGIN_ROOT/scripts/maintain-leases.sh"
  assert_file_not_contains "WC8: probe has no assert-primary-only" \
    "$PLUGIN_ROOT/scripts/workflow-probe.sh" 'assert-primary-only'
  assert_file_not_contains "WC9: probe has no maintain-delivery" \
    "$PLUGIN_ROOT/scripts/workflow-probe.sh" 'maintain-delivery.sh'

  rm -rf -- "$fixture" "$root"
}

test_workflow_context_contract
