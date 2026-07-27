# Lifecycle skill + legacy importer parity (#386).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "lifecycle.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_lifecycle() {
  echo -e "\n${CYAN}Suite LC: thin conditional lifecycle (#386)${NC}"
  local skill="$PLUGIN_ROOT/skills/lifecycle/SKILL.md"
  local startup="$PLUGIN_ROOT/commands/startup.md"
  local importer="$PLUGIN_ROOT/scripts/legacy-import.sh"
  local workdir ec out state_before

  assert_file_exists "LC1: lifecycle skill exists" "$skill"
  assert_file_exists "LC2: startup command exists" "$startup"
  assert_file_exists "LC3: legacy-import.sh exists" "$importer"
  assert_file_not_exists "LC4: startup-orchestration removed" \
    "$PLUGIN_ROOT/skills/startup-orchestration/SKILL.md"
  assert_file_not_exists "LC5: check-stop removed" "$PLUGIN_ROOT/scripts/check-stop.sh"
  assert_file_not_exists "LC6: mark-yield removed" "$PLUGIN_ROOT/scripts/mark-yield.sh"
  assert_file_not_exists "LC7: compact-state removed" "$PLUGIN_ROOT/scripts/compact-state.sh"
  assert_file_not_exists "LC8: index-handoff removed" "$PLUGIN_ROOT/scripts/index-handoff.sh"
  assert_file_not_exists "LC9: backfill-handoff-index removed" \
    "$PLUGIN_ROOT/scripts/backfill-handoff-index.sh"
  assert_file_not_exists "LC10: migrate-state removed" "$PLUGIN_ROOT/scripts/migrate-state.sh"

  # Fast path: small scoped work bypasses broad market research
  assert_file_contains "LC11: fast path table" "$skill" '**Fast**'
  assert_file_contains "LC12: skip broad market research on fast path" "$skill" \
    'Skip broad market research'
  assert_file_contains "LC13: small scoped prefers Fast" "$skill" \
    'prefers Fast'

  # Conditional discovery
  assert_file_contains "LC14: discovery only on evidence gap" "$skill" \
    'Material evidence gap that can change `Done`'
  assert_file_contains "LC15: product-discovery only for gap" "$skill" \
    'product-discovery/SKILL.md` only for that gap'
  assert_file_contains "LC16: no unconditional product-wide audit" "$skill" \
    'No unconditional product-wide market or legal audit'

  # Specialist triggers
  assert_file_contains "LC17: lawyer trigger" "$skill" '`lawyer`'
  assert_file_contains "LC18: ux-review trigger" "$skill" '`ux-review`'
  assert_file_contains "LC19: product-acceptance trigger" "$skill" '`product-acceptance`'
  assert_file_contains "LC20: growth trigger" "$skill" '`growth`'
  assert_file_contains "LC21: specialists only when Triggers fire" "$skill" \
    'only when its own Triggers fire'
  assert_file_contains "LC22: deliver is technical path" "$skill" \
    'SAAS_DELIVER_ENTRYPOINT=startup-impl'

  # Cancellation, budget, incomplete
  assert_file_contains "LC23: cancelled outcome" "$skill" '`cancelled`'
  assert_file_contains "LC24: budget_exhausted outcome" "$skill" '`budget_exhausted`'
  assert_file_contains "LC25: incomplete outcome" "$skill" '`incomplete`'
  assert_file_contains "LC26: blocked outcome" "$skill" '`blocked`'
  assert_file_contains "LC27: complete outcome" "$skill" '`complete`'
  assert_file_contains "LC28: never claim success without evidence" "$skill" \
    'Never claim success without gate evidence'

  # No state machine for new runs
  assert_file_contains "LC29: skill bans active_role" "$skill" 'No `active_role`'
  assert_file_contains "LC30: skill bans Stop/yield" "$skill" 'No Stop-hook'
  assert_file_contains "LC31: skill bans numbered handoffs" "$skill" \
    'numbered conversational handoffs'
  assert_file_not_contains "LC32: skill does not assign active_role" "$skill" '.active_role ='
  assert_file_not_contains "LC33: startup does not init iteration" "$startup" \
    '"iteration": 0'
  assert_file_not_contains "LC34: startup does not set active_role" "$startup" \
    '"active_role"'
  assert_file_contains "LC35: startup hard ban on state.json loop fields" "$startup" \
    'initialize or update'
  assert_file_contains "LC36: startup loads lifecycle" "$startup" 'lifecycle'
  assert_file_contains "LC37: startup names deliver entrypoint" "$startup" \
    'SAAS_DELIVER_ENTRYPOINT=startup-impl'

  # Silent investor optional only
  assert_file_contains "LC38: silent observer optional presentation" "$skill" \
    'silent observer'
  assert_file_contains "LC39: not a control plane" "$skill" \
    'never as a control-plane role'

  # Hooks: Stop / compact-state / index-handoff gone
  local hooks_blob
  hooks_blob=$(cat "$PLUGIN_ROOT/hooks/hooks.json")
  assert_output_not_contains "LC40: no Stop hook" "$hooks_blob" '"Stop"'
  assert_output_not_contains "LC41: no check-stop hook" "$hooks_blob" 'check-stop.sh'
  assert_output_not_contains "LC42: no compact-state hook" "$hooks_blob" 'compact-state.sh'
  assert_output_not_contains "LC43: no index-handoff hook" "$hooks_blob" 'index-handoff.sh'

  # Importer: read-only, surfaces useful artifacts, does not mutate state
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q)
  mkdir -p "$workdir/docs/business" "$workdir/docs/research" \
    "$workdir/.startup/workflows" "$workdir/.startup/go-live" \
    "$workdir/.startup/signoffs" "$workdir/.startup/handoffs"
  printf '# Brief\nBuild invoicing for e-residents.\n' > "$workdir/docs/business/brief.md"
  printf '# Research\n' > "$workdir/docs/research/market.md"
  printf '# Registry\n' > "$workdir/.startup/workflows/registry.md"
  printf '# WF\n' > "$workdir/.startup/workflows/WORKFLOW-checkout.md"
  printf '# Signoff\n' > "$workdir/.startup/go-live/solution-signoff.md"
  printf '# RT\n' > "$workdir/.startup/signoffs/roundtrip-001.md"
  printf '# Handoff\n' > "$workdir/.startup/handoffs/001-business-to-tech.md"
  printf '%s\n' '{"iteration":7,"phase":"review","active_role":"product-discovery","status":"active"}' \
    > "$workdir/.startup/state.json"
  state_before=$(cat "$workdir/.startup/state.json")

  ec=0
  out=$(bash "$importer" --root "$workdir" --json 2>&1) || ec=$?
  assert_exit_code "LC44: importer --json exits 0" "$ec" 0
  assert_output_contains "LC45: importer read_only true" "$out" '"read_only": true'
  assert_output_contains "LC46: importer does not revive SM" "$out" \
    '"revives_state_machine": false'
  assert_output_contains "LC47: importer surfaces brief" "$out" 'docs/business/brief.md'
  assert_output_contains "LC48: importer surfaces workflow" "$out" 'WORKFLOW-checkout.md'
  assert_output_contains "LC49: importer surfaces signoff" "$out" 'solution-signoff.md'
  assert_output_contains "LC50: importer lists handoffs only" "$out" 'handoffs_listed_only'
  assert_equals "LC51: importer did not mutate state.json" \
    "$(cat "$workdir/.startup/state.json")" "$state_before"
  assert_equals "LC52: importer did not write active_role" \
    "$(jq -r .active_role "$workdir/.startup/state.json")" "product-discovery"

  # Text mode also works and remains non-mutating
  ec=0
  out=$(bash "$importer" --root "$workdir" 2>&1) || ec=$?
  assert_exit_code "LC53: importer text mode exits 0" "$ec" 0
  assert_output_contains "LC54: text mode labels read-only" "$out" 'read-only'
  assert_equals "LC55: text mode did not mutate state" \
    "$(cat "$workdir/.startup/state.json")" "$state_before"

  # Empty tree is fine
  workdir2=$(make_workdir)
  ec=0
  out=$(bash "$importer" --root "$workdir2" --json 2>&1) || ec=$?
  assert_exit_code "LC56: empty root import exits 0" "$ec" 0
  assert_output_contains "LC57: empty brief null" "$out" '"brief": null'
  rm -rf "$workdir" "$workdir2"

  # Startup parity with deliver/capability skills
  assert_file_contains "LC58: startup uses health preflight" "$startup" 'health-preflight.sh'
  assert_file_contains "LC59: startup uses legacy-import" "$startup" 'legacy-import.sh'
  assert_file_contains "LC60: lifecycle uses single-flight" "$skill" 'single-flight.sh'
  assert_file_contains "LC61: lifecycle uses market-scout when needed" "$skill" \
    'market-scout.sh'
  assert_file_contains "LC62: ensure engineering principles" "$skill" \
    'ensure-engineering-principles.sh'

  # Codex alias still points at command
  assert_file_contains "LC63: Codex startup alias → command" \
    "$PLUGIN_ROOT/skills/saas-startup-team-startup-workflow/SKILL.md" \
    '../../commands/startup.md'
}

test_lifecycle
