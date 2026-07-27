# Lifecycle skill + path classifier + legacy importer (#386).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "lifecycle.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_lifecycle() {
  echo -e "\n${CYAN}Suite LC: thin conditional lifecycle (#386)${NC}"
  local skill="$PLUGIN_ROOT/skills/lifecycle/SKILL.md"
  local startup="$PLUGIN_ROOT/commands/startup.md"
  local importer="$PLUGIN_ROOT/scripts/legacy-import.sh"
  local pathc="$PLUGIN_ROOT/scripts/lifecycle-path.sh"
  local workdir ec out state_before

  assert_file_exists "LC1: lifecycle skill exists" "$skill"
  assert_file_exists "LC2: startup command exists" "$startup"
  assert_file_exists "LC3: legacy-import.sh exists" "$importer"
  assert_file_exists "LC3b: lifecycle-path.sh exists" "$pathc"
  assert_file_not_exists "LC4: startup-orchestration removed" \
    "$PLUGIN_ROOT/skills/startup-orchestration/SKILL.md"
  assert_file_not_exists "LC5: check-stop removed" "$PLUGIN_ROOT/scripts/check-stop.sh"
  assert_file_not_exists "LC6: mark-yield removed" "$PLUGIN_ROOT/scripts/mark-yield.sh"
  assert_file_not_exists "LC7: compact-state removed" "$PLUGIN_ROOT/scripts/compact-state.sh"
  assert_file_not_exists "LC8: index-handoff removed" "$PLUGIN_ROOT/scripts/index-handoff.sh"
  assert_file_not_exists "LC9: backfill-handoff-index removed" \
    "$PLUGIN_ROOT/scripts/backfill-handoff-index.sh"
  assert_file_not_exists "LC10: migrate-state removed" "$PLUGIN_ROOT/scripts/migrate-state.sh"

  # --- Executable path classification (fast / discovery / blocked) ---
  out=$(bash "$pathc" --concrete); assert_equals "LC11: concrete → fast" "$out" fast
  out=$(bash "$pathc" --concrete --has-brief); assert_equals "LC12: concrete+brief → fast" "$out" fast
  out=$(bash "$pathc" --evidence-gap); assert_equals "LC13: evidence gap → discovery" "$out" discovery
  out=$(bash "$pathc" --concrete --evidence-gap)
  assert_equals "LC14: evidence gap wins over concrete" "$out" discovery
  out=$(bash "$pathc" --has-goal); assert_equals "LC15: goal alone → fast" "$out" fast
  out=$(bash "$pathc" --has-brief); assert_equals "LC16: brief alone → fast" "$out" fast
  out=$(bash "$pathc" --scout-empty)
  assert_equals "LC17: no demand + scout empty → blocked" "$out" blocked
  out=$(bash "$pathc"); assert_equals "LC18: empty flags → blocked" "$out" blocked
  ec=0; bash "$pathc" --nope >/dev/null 2>&1 || ec=$?
  assert_exit_code "LC19: bad arg exits 2" "$ec" 2

  # Skill wires path helper + specialist triggers + honest outcomes
  assert_file_contains "LC20: skill uses path helper" "$skill" 'lifecycle-path.sh'
  assert_file_contains "LC21: skip broad market research on fast path" "$skill" \
    'Skip broad market research'
  assert_file_contains "LC22: prefers Fast" "$skill" 'prefers Fast'
  assert_file_contains "LC23: lawyer trigger" "$skill" '`lawyer`'
  assert_file_contains "LC24: ux-review trigger" "$skill" '`ux-review`'
  assert_file_contains "LC25: product-acceptance trigger" "$skill" '`product-acceptance`'
  assert_file_contains "LC26: growth trigger" "$skill" '`growth`'
  assert_file_contains "LC27: specialists only when Triggers fire" "$skill" \
    'only when its own Triggers fire'
  assert_file_contains "LC28: deliver is technical path" "$skill" \
    'SAAS_DELIVER_ENTRYPOINT=startup-impl'
  assert_file_contains "LC29: cancelled outcome" "$skill" '`cancelled`'
  assert_file_contains "LC30: budget_exhausted outcome" "$skill" '`budget_exhausted`'
  assert_file_contains "LC31: incomplete outcome" "$skill" '`incomplete`'
  assert_file_contains "LC32: blocked outcome" "$skill" '`blocked`'
  assert_file_contains "LC33: complete outcome" "$skill" '`complete`'
  assert_file_contains "LC34: never claim success without evidence" "$skill" \
    'Never claim success without gate evidence'

  # No state machine for new runs
  assert_file_contains "LC35: skill bans active_role" "$skill" 'No `active_role`'
  assert_file_contains "LC36: skill bans Stop/yield" "$skill" 'No Stop-hook'
  assert_file_contains "LC37: skill bans numbered handoffs" "$skill" \
    'numbered conversational handoffs'
  assert_file_not_contains "LC38: skill does not assign active_role" "$skill" '.active_role ='
  assert_file_not_contains "LC39: startup does not init iteration" "$startup" \
    '"iteration": 0'
  assert_file_not_contains "LC40: startup does not set active_role" "$startup" \
    '"active_role"'
  assert_file_contains "LC41: startup hard ban on state.json loop fields" "$startup" \
    'initialize or update'
  assert_file_contains "LC42: startup loads lifecycle" "$startup" 'lifecycle'
  assert_file_contains "LC43: startup names deliver entrypoint" "$startup" \
    'SAAS_DELIVER_ENTRYPOINT=startup-impl'
  assert_file_contains "LC44: silent observer optional presentation" "$skill" \
    'silent observer'
  assert_file_contains "LC45: not a control plane" "$skill" \
    'never as a control-plane role'

  # Hooks: Stop / compact-state / index-handoff gone
  local hooks_blob
  hooks_blob=$(cat "$PLUGIN_ROOT/hooks/hooks.json")
  assert_output_not_contains "LC46: no Stop hook" "$hooks_blob" '"Stop"'
  assert_output_not_contains "LC47: no check-stop hook" "$hooks_blob" 'check-stop.sh'
  assert_output_not_contains "LC48: no compact-state hook" "$hooks_blob" 'compact-state.sh'
  assert_output_not_contains "LC49: no index-handoff hook" "$hooks_blob" 'index-handoff.sh'

  # Importer: bounded, read-only, canonical signoff precedence
  workdir=$(make_workdir)
  (cd "$workdir" && git init -q)
  mkdir -p "$workdir/docs/business" "$workdir/docs/research" \
    "$workdir/.startup/workflows" "$workdir/.startup/go-live" \
    "$workdir/go-live" "$workdir/.startup/signoffs" "$workdir/.startup/handoffs"
  printf '# Brief\nBuild invoicing for e-residents.\n' > "$workdir/docs/business/brief.md"
  printf '# Research\n' > "$workdir/docs/research/market.md"
  printf '# Registry\n' > "$workdir/.startup/workflows/registry.md"
  printf '# WF\n' > "$workdir/.startup/workflows/WORKFLOW-checkout.md"
  printf '# Canonical signoff\n' > "$workdir/.startup/go-live/solution-signoff.md"
  printf '# Loose stale signoff\n' > "$workdir/go-live/solution-signoff.md"
  printf '# RT\n' > "$workdir/.startup/signoffs/roundtrip-001.md"
  printf '# Handoff\n' > "$workdir/.startup/handoffs/001-business-to-tech.md"
  printf '%s\n' '{"iteration":7,"phase":"review","active_role":"product-discovery","status":"active"}' \
    > "$workdir/.startup/state.json"
  state_before=$(cat "$workdir/.startup/state.json")

  ec=0
  out=$(bash "$importer" --root "$workdir" --json 2>&1) || ec=$?
  assert_exit_code "LC50: importer --json exits 0" "$ec" 0
  assert_output_contains "LC51: importer read_only true" "$out" '"read_only": true'
  assert_output_contains "LC52: importer does not revive SM" "$out" \
    '"revives_state_machine": false'
  assert_output_contains "LC53: importer surfaces brief" "$out" 'docs/business/brief.md'
  assert_output_contains "LC54: importer surfaces workflow" "$out" 'WORKFLOW-checkout.md'
  assert_output_contains "LC55: importer prefers canonical signoff" "$out" \
    '.startup/go-live/solution-signoff.md'
  assert_output_not_contains "LC56: importer ignores loose signoff when canonical exists" \
    "$out" "$workdir/go-live/solution-signoff.md"
  assert_output_not_contains "LC57: importer does not scan research" "$out" 'docs/research'
  assert_output_not_contains "LC58: importer does not list handoffs" "$out" 'handoffs_listed'
  assert_equals "LC59: importer did not mutate state.json" \
    "$(cat "$workdir/.startup/state.json")" "$state_before"
  assert_equals "LC60: importer did not write active_role" \
    "$(jq -r .active_role "$workdir/.startup/state.json")" "product-discovery"

  # Cancellation / budget honesty via lease + skill contract (executable lease release)
  local lease_script="$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_exists "LC61: single-flight present for cancel/release" "$lease_script"
  assert_file_contains "LC62: cancel releases lease" "$skill" '--release'
  assert_file_contains "LC63: budget_exhausted named" "$skill" 'budget_exhausted'
  assert_file_contains "LC64: incomplete named" "$skill" 'incomplete'

  # Simulate cancelled session: acquire then release leaves no live owner
  mkdir -p "$workdir/.startup/leases/.owners"
  ec=0
  (cd "$workdir" && bash "$lease_script" \
    --acquire "startup:${workdir}" --state-dir .startup/leases \
    --owner-file .startup/leases/.owners/startup.owner --ttl-seconds 60) || ec=$?
  assert_exit_code "LC65: cancel setup acquire" "$ec" 0
  ec=0
  (cd "$workdir" && bash "$lease_script" \
    --release "startup:${workdir}" --state-dir .startup/leases \
    --owner-file .startup/leases/.owners/startup.owner) || ec=$?
  assert_exit_code "LC66: cancel path releases lease" "$ec" 0

  # Empty tree is fine
  workdir2=$(make_workdir)
  ec=0
  out=$(bash "$importer" --root "$workdir2" --json 2>&1) || ec=$?
  assert_exit_code "LC67: empty root import exits 0" "$ec" 0
  assert_output_contains "LC68: empty brief null" "$out" '"brief": null'
  rm -rf "$workdir" "$workdir2"

  assert_file_contains "LC69: startup uses health preflight" "$startup" 'health-preflight.sh'
  assert_file_contains "LC70: startup uses legacy-import" "$startup" 'legacy-import.sh'
  assert_file_contains "LC71: lifecycle uses single-flight" "$skill" 'single-flight.sh'
  assert_file_contains "LC72: lifecycle uses market-scout when needed" "$skill" \
    'market-scout.sh'
  assert_file_contains "LC73: Codex startup alias → command" \
    "$PLUGIN_ROOT/skills/saas-startup-team-startup-workflow/SKILL.md" \
    '../../commands/startup.md'
}

test_lifecycle
