# Maintenance runtime bridge and transaction regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-runtime.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_runtime() {
  echo -e "\n${CYAN}Suite MR: maintenance runtime${NC}"
  local leases="$PLUGIN_ROOT/scripts/maintain-leases.sh"
  local blocked="$PLUGIN_ROOT/scripts/maintain-blocked.sh"
  local attempt_helper="$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  local guardian="$PLUGIN_ROOT/scripts/lease-guardian.sh"
  local single="$PLUGIN_ROOT/scripts/single-flight.sh"
  local repo common state owner ec out run_state linked base second wt lease_dir legacy_dir forged_state
  local canonical_wt canonical_state canonical_gate canonical_summary legacy_attempt_state
  local origin_run controller_run_id child_run_id child_run_id_2 child_run_id_3 child_run_id_4
  local victim ledger prompt_dir prompt fake_gate check_oid summary marker ready release locker holder signal_marker descendant external_state agent_events
  local lock_victim fake_bin old_heartbeat old_audit old_owner old_lease_owner
  local elapsed escaped_pid real_mv real_jq worktree_key lease_jq_bin
  local escape_ready escape_sentinel escape_helper detach_helper
  local kill_ready kill_sentinel outer_pid outer_start
  local root_pid root_start member_start foreground_pid foreground_start
  local outer_state root_state member_state foreground_state
  local race_bin race_count race_entered race_release race_ready race_sentinel
  local race_child race_start real_setpriv
  local legacy_lock_bin real_flock legacy_ready legacy_release legacy_takeover_ready
  local legacy_takeover_status legacy_heartbeat_pid legacy_takeover_pid
  local hold_key hold_dir hold_owner
  local reset_bin real_git reset_ready reset_status reset_pid reset_heartbeat
  local reset_heartbeat_before reset_heartbeat_after
  local lease_before lease_after runtime_before runtime_after
  local role_guard telemetry_id routing_schema guard_dir active_guard verified_guard
  local unrelated guard_victim worker_bin worker_called shared_owner inactive_guard
  local metadata_peer peer_git_dir peer_backpointer peer_head
  local long_reason malformed_file valid_file overlong_file diag_file normalized

  repo=$(mktemp -d)
  origin_run=attempt-run
  controller_run_id=run-11111111111111111111111111111111
  child_run_id=run-22222222222222222222222222222222
  child_run_id_2=run-33333333333333333333333333333333
  child_run_id_3=run-44444444444444444444444444444444
  child_run_id_4=run-55555555555555555555555555555555
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/check.sh"
  printf 'base\n' > "$repo/app.txt"
  chmod +x "$repo/check.sh"
  git -C "$repo" add check.sh app.txt
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'second\n' > "$repo/app.txt"
  git -C "$repo" commit -qam second
  second=$(git -C "$repo" rev-parse HEAD)
  common=$(git -C "$repo" rev-parse --absolute-git-dir)
  lease_dir="$common/saas-startup-team/leases"
  legacy_dir="$repo/.startup/leases"
  mkdir -p "$lease_dir/.owners"

  owner="$lease_dir/.owners/old-maintain.owner"
  bash "$single" --acquire maintain-pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
  state="$common/saas-startup-team/maintain-runtime/blocked-old-maintain.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop --run-id blocked-old-maintain \
    --state-file "$state" --worktree "$repo/.worktrees/maintain-loop" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR1: legacy maintain pass blocks the bridge" "$ec" 1
  assert_file_not_exists "MR2: failed bridge leaves no new shared lease" "$lease_dir/maintain-delivery-pass"
  bash "$single" --release maintain-pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null

  owner="$lease_dir/.owners/old-loop.owner"
  bash "$single" --acquire maintain-loop:pass --state-dir "$legacy_dir" --owner-file "$owner" >/dev/null
  state="$common/saas-startup-team/maintain-runtime/blocked-old-loop.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop --run-id blocked-old-loop \
    --state-file "$state" --worktree "$repo/.worktrees/maintain-loop" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR3: legacy maintain-loop pass blocks the bridge" "$ec" 1
  assert_file_not_exists "MR4: partial bridge acquisition is rolled back" "$lease_dir/maintain-pass"
  bash "$single" --release maintain-loop:pass --state-dir "$legacy_dir" --owner-file "$owner" >/dev/null

  owner="$lease_dir/.owners/old-contract-maintain.owner"
  bash "$single" --acquire maintain-pass --state-dir "$lease_dir" --owner-file "$owner" \
    --ttl-seconds 1800 >/dev/null
  printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$lease_dir/maintain-pass/heartbeat"
  old_heartbeat=$(cat "$lease_dir/maintain-pass/heartbeat")
  old_owner=$(cat "$owner")
  old_lease_owner=$(cat "$lease_dir/maintain-pass/owner")
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4aa: available honors the old maintain-pass TTL" "$ec" 1
  state="$common/saas-startup-team/maintain-runtime/old-contract-active.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id old-contract-active \
    --state-file "$state" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4ab: acquire refuses a 1000-second-old maintain-pass" "$ec" 1
  assert_equals "MR4ac: refused acquire preserves the lease owner" \
    "$(cat "$lease_dir/maintain-pass/owner")" "$old_lease_owner"
  assert_equals "MR4ad: refused acquire preserves the legacy owner identity" \
    "$(cat "$owner")" "$old_owner"
  assert_equals "MR4ae: refused acquire preserves the old heartbeat" \
    "$(cat "$lease_dir/maintain-pass/heartbeat")" "$old_heartbeat"
  assert_file_not_exists "MR4af: refused acquire publishes no lease-set state" "$state"
  bash "$single" --release maintain-pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null

  owner="$lease_dir/.owners/crashed.owner"
  bash "$single" --acquire maintain-pass --state-dir "$lease_dir" --owner-file "$owner" \
    --ttl-seconds 14400 >/dev/null
  printf '%s\n' "$(( $(date +%s) - 15000 ))" > "$lease_dir/maintain-pass/heartbeat"
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4a: well-formed expired crash lease is probe-reclaimable" "$ec" 0
  state="$common/saas-startup-team/maintain-runtime/recovered.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id recovered \
    --state-file "$state" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4b: acquisition reclaims a proven expired crash lease" "$ec" 0
  bash "$leases" cleanup --state-file "$state" --run-id recovered >/dev/null

  state="$common/saas-startup-team/maintain-runtime/terminal-reap-leases.json"
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id terminal-reap \
    --state-file "$state" --worktree "$repo/.worktrees/maintain" >/dev/null
  ec=0
  out=$(bash "$leases" reap-terminal --repo-root "$repo" --run-id absent-terminal 2>&1) || ec=$?
  assert_exit_code "MR4bg: absent exact terminal state is an idempotent no-op" "$ec" 0
  assert_file_exists "MR4bh: wrong terminal ID preserves another run's state" "$state"
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4bi: availability still catches an unreaped active run" "$ec" 1
  bash "$leases" reap-terminal --repo-root "$repo" --run-id terminal-reap >/dev/null
  assert_file_not_exists "MR4bj: exact terminal reap removes its lease state" "$state"
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4bk: exact terminal reap restores delivery availability" "$ec" 0
  ec=0
  out=$(bash "$leases" reap-terminal --repo-root "$repo" --run-id terminal-reap 2>&1) || ec=$?
  assert_exit_code "MR4bl: repeated terminal reap stays idempotent" "$ec" 0
  assert_output_contains "MR4bm: repeated reap reports absent state" "$out" \
    'terminal run has no lease state'

  wt="$repo/.worktrees/maintain-loop"
  state="$common/saas-startup-team/maintain-runtime/loop-terminal-leases.json"
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop --run-id loop-terminal \
    --state-file "$state" --worktree "$wt" >/dev/null
  ec=0
  out=$(bash "$leases" reap-terminal --repo-root "$repo" --run-id loop-terminal 2>&1) || ec=$?
  assert_exit_code "MR4bn: thin coordinator reaps an exact legacy recovery state" "$ec" 0
  assert_output_contains "MR4bo: legacy terminal reap reports completion" "$out" \
    'terminal run reaped'
  assert_file_not_exists "MR4bp: legacy terminal reap removes its lease state" "$state"
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4bq: legacy terminal reap restores shared availability" "$ec" 0

  for heartbeat_case in future malformed; do
    owner="$lease_dir/.owners/$heartbeat_case.owner"
    bash "$single" --acquire maintain-pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
    if [ "$heartbeat_case" = future ]; then
      printf '%s\n' "$(( $(date +%s) + 600 ))" > "$lease_dir/maintain-pass/heartbeat"
    else
      printf 'not-a-time\n' > "$lease_dir/maintain-pass/heartbeat"
    fi
    ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
    assert_exit_code "MR4c: $heartbeat_case crash lease fails probe closed" "$ec" 1
    state="$common/saas-startup-team/maintain-runtime/$heartbeat_case.json"
    ec=0
    bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id "$heartbeat_case" \
      --state-file "$state" >/dev/null 2>&1 || ec=$?
    assert_exit_code "MR4d: $heartbeat_case crash lease cannot be replaced" "$ec" 2
    bash "$single" --release maintain-pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
  done

  wt="$repo/.worktrees/maintain-loop"
  owner="$lease_dir/.owners/orphan-worktree.owner"
  worktree_key="maintain-loop:worktree:$(printf '%s' "$wt" | cksum | awk '{print $1}')"
  bash "$single" --acquire "$worktree_key" --state-dir "$lease_dir" \
    --owner-file "$owner" >/dev/null
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4e: an orphaned worktree lease blocks the model-free probe" "$ec" 1
  state="$common/saas-startup-team/maintain-runtime/orphan-legacy-blocks-canonical.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id blocked-by-legacy \
    --state-file "$state" --worktree "$repo/.worktrees/maintain" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4ea: canonical acquire cannot bypass an active orphan legacy worktree lease" "$ec" 1
  assert_file_not_exists "MR4eb: rejected canonical acquire publishes no lease state" "$state"
  assert_file_not_exists "MR4ec: rejected canonical acquire rolls back shared exclusion" \
    "$lease_dir/maintain-delivery-pass"
  state="$common/saas-startup-team/maintain-runtime/orphan-legacy-blocks-archive.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id archive-blocked-by-legacy \
    --state-file "$state" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4ed: archive acquire cannot bypass an active orphan legacy worktree lease" "$ec" 1
  assert_file_not_exists "MR4ee: rejected archive acquire publishes no lease state" "$state"
  bash "$single" --release "$worktree_key" --state-dir "$lease_dir" \
    --owner-file "$owner" >/dev/null

  canonical_wt="$repo/.worktrees/maintain"
  owner="$lease_dir/.owners/orphan-canonical-worktree.owner"
  worktree_key="maintain:worktree:$(printf '%s' "$canonical_wt" | cksum | awk '{print $1}')"
  bash "$single" --acquire "$worktree_key" --state-dir "$lease_dir" \
    --owner-file "$owner" >/dev/null
  ec=0; bash "$leases" available --repo-root "$repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4f: an orphaned canonical worktree lease blocks the model-free probe" "$ec" 1
  state="$common/saas-startup-team/maintain-runtime/orphan-canonical-blocks-legacy.json"
  ec=0
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop --run-id blocked-by-canonical \
    --state-file "$state" --worktree "$repo/.worktrees/maintain-loop" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR4fa: legacy acquire cannot bypass an active orphan canonical worktree lease" "$ec" 1
  assert_file_not_exists "MR4fb: rejected legacy acquire publishes no lease state" "$state"
  assert_file_not_exists "MR4fc: rejected legacy acquire rolls back shared exclusion" \
    "$lease_dir/maintain-delivery-pass"
  bash "$single" --release "$worktree_key" --state-dir "$lease_dir" \
    --owner-file "$owner" >/dev/null

  state="$common/saas-startup-team/maintain-runtime/run-bridge.json"
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop --run-id run-bridge \
    --state-file "$state" --worktree "$wt" >/dev/null
  assert_equals "MR5: bridge persists all four lease identities" "$(jq '.leases|length' "$state")" 4
  assert_equals "MR6: worktree lease keeps legacy key spelling" \
    "$(jq -r '.leases[]|select(.kind=="worktree")|.key|startswith("maintain-loop:worktree:")' "$state")" true
  ec=0
  bash "$single" --acquire maintain-pass --state-dir "$lease_dir" --owner another >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR7: a bridged run blocks an old maintain client" "$ec" 1
  ec=0
  bash "$single" --acquire maintain-loop:pass --state-dir "$legacy_dir" --owner another >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR8: a bridged run blocks an old loop client" "$ec" 1

  runtime_before=$(/usr/bin/sha256sum -- "$state" | /usr/bin/awk '{print $1}')
  lease_before=$(lease_state_fingerprint "$state")
  marker="$repo/unbound-mutation-launched"
  ec=0; out=$(bash "$leases" heartbeat --state-file "$state" 2>&1) || ec=$?
  assert_exit_code "MR8a: bound heartbeat requires the exact controller tuple" "$ec" 1
  assert_output_contains "MR8aa: missing bound tuple has an explicit diagnostic" "$out" \
    'lease mutation requires --repo-root, --worktree, and --run-id'
  ec=0
  bash "$leases" hold --state-file "$state" --interval-seconds 1 --max-seconds 10 \
    -- bash -c ': > "$1"' _ "$marker" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR8b: bound hold requires the exact controller tuple" "$ec" 1
  assert_file_not_exists "MR8ba: rejected unbound hold never launches its child" "$marker"
  ec=0
  bash "$leases" cleanup --state-file "$state" --run-id run-bridge >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR8bb: bound cleanup requires the exact controller tuple" "$ec" 1
  assert_equals "MR8bc: rejected bound mutations leave lease state byte-identical" \
    "$(/usr/bin/sha256sum -- "$state" | /usr/bin/awk '{print $1}')" "$runtime_before"
  lease_after=$(lease_state_fingerprint "$state")
  assert_equals "MR8bd: rejected bound mutations leave owner and heartbeat state unchanged" \
    "$lease_after" "$lease_before"
  run_state="$repo/.startup/maintain-loop/current-run.json"
  mkdir -p "$(dirname "$run_state")"
  printf '%s\n' '{"run_id":"run-bridge"}' > "$run_state"
  real_jq=$(command -v jq)
  lease_jq_bin="$repo/lease-jq-bin"; mkdir "$lease_jq_bin"
  cat > "$lease_jq_bin/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *'.leases[] | [.kind,.key,.state_dir,.owner_file] | @tsv'*) exit 91 ;;
  esac
done
exec "$REAL_JQ" "$@"
SH
  chmod +x "$lease_jq_bin/jq"
  marker="$repo/failed-jq-launched"
  ec=0
  out=$(PATH="$lease_jq_bin:$PATH" REAL_JQ="$real_jq" \
    bash "$leases" hold --state-file "$state" --repo-root "$repo" --worktree "$wt" \
      --run-id run-bridge --interval-seconds 1 --max-seconds 10 \
      -- bash -c ': > "$1"' _ "$marker" 2>&1) || ec=$?
  assert_exit_code "MR8c: failed lease-row materialization fails hold closed" "$ec" 1
  assert_file_not_exists "MR8d: failed lease-row materialization never launches its child" "$marker"
  marker="$repo/unsafe-interval-launched"
  ec=0
  out=$(bash "$leases" hold --state-file "$state" --repo-root "$repo" --worktree "$wt" \
    --run-id run-bridge --interval-seconds 900 --max-seconds 10 \
    -- bash -c ': > "$1"' _ "$marker" 2>&1) || ec=$?
  assert_exit_code "MR8e: lease-set hold rejects an interval at the minimum TTL" "$ec" 2
  assert_output_contains "MR8f: interval rejection names the safe maximum" "$out" "at most 60 seconds"
  assert_file_not_exists "MR8g: unsafe lease-set interval never launches its child" "$marker"
  hold_key=$(jq -r '.leases[0].key' "$state")
  hold_dir=$(jq -r '.leases[0].state_dir' "$state")
  hold_owner=$(jq -r '.leases[0].owner_file' "$state")
  ec=0
  out=$(bash "$guardian" hold --lease-at "$hold_dir" "$hold_key" "$hold_owner" \
    --interval-seconds 61 --max-seconds 10 -- bash -c ': > "$1"' _ "$marker" 2>&1) || ec=$?
  assert_exit_code "MR8h: direct guardian rejects an unsafe heartbeat interval" "$ec" 2
  assert_file_not_exists "MR8i: unsafe guardian interval never launches its child" "$marker"
  marker="$repo/overlong-hold-launched"
  ec=0
  out=$(bash "$leases" hold --state-file "$state" --repo-root "$repo" --worktree "$wt" \
    --run-id run-bridge --interval-seconds 1 --max-seconds 14401 \
    -- bash -c ': > "$1"' _ "$marker" 2>&1) || ec=$?
  assert_exit_code "MR8j: lease-set hold caps the protocol lifetime" "$ec" 2
  assert_output_contains "MR8k: overlong hold names the protocol maximum" "$out" \
    "maximum hold lifetime is 14400 seconds"
  assert_file_not_exists "MR8l: overlong hold never launches its child" "$marker"
  forged_state="$common/saas-startup-team/maintain-runtime/borrowed-run.json"
  jq '.run_id="borrowed-run"' "$state" > "$forged_state"; chmod 600 "$forged_state"
  ec=0
  out=$(bash "$leases" heartbeat --state-file "$forged_state" --repo-root "$repo" \
    --worktree "$wt" --run-id borrowed-run 2>&1) || ec=$?
  assert_exit_code "MR8m: forged run identity cannot borrow another run's owner tokens" "$ec" 1
  assert_output_contains "MR8n: borrowed owner-token refusal is explicit" "$out" \
    "owner binding does not match this run"
  rm -f -- "$forged_state"
  printf 'forged-owner\n' > "$lease_dir/maintain-pass/owner"
  ec=0
  bash "$leases" cleanup --state-file "$state" --run-state "$run_state" \
    --repo-root "$repo" --worktree "$wt" --run-id run-bridge >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR9: one failed release makes cleanup fail" "$ec" 1
  assert_file_not_exists "MR10: cleanup still releases the shared lease" "$lease_dir/maintain-delivery-pass"
  assert_file_not_exists "MR11: cleanup still releases the legacy loop lease" "$legacy_dir/maintain-loop-pass"
  assert_file_not_exists "MR12: cleanup still releases the worktree lease" \
    "$lease_dir/maintain-loop-worktree-$(printf '%s' "$wt" | cksum | awk '{print $1}')"
  assert_file_not_exists "MR13: matching run state is removed despite release failure" "$run_state"
  assert_file_exists "MR14: failed cleanup retains lease state for recovery" "$state"
  external_state=$(mktemp -d)
  rmdir "$repo/.startup/maintain-loop"
  ln -s "$external_state" "$repo/.startup/maintain-loop"
  printf '%s\n' '{"run_id":"run-bridge"}' > "$external_state/current-run.json"
  ec=0
  bash "$leases" cleanup --state-file "$state" --run-state "$run_state" \
    --repo-root "$repo" --worktree "$wt" --run-id run-bridge >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR14a: cleanup rejects a symlinked run-state parent" "$ec" 1
  assert_file_exists "MR14b: rejected cleanup preserves external run state" \
    "$external_state/current-run.json"
  rm "$repo/.startup/maintain-loop"; mkdir "$repo/.startup/maintain-loop"
  rm -rf "$external_state"
  rm -rf "$lease_dir/maintain-pass" "$lease_dir/.owners" "$state"

  linked=$(mktemp -d); rmdir "$linked"
  git -C "$repo" worktree add -q -b linked-test "$linked" "$second"
  assert_equals "MR15: linked invocation resolves the primary worktree" \
    "$(bash "$leases" primary-root --repo-root "$linked")" "$repo"
  state="$common/saas-startup-team/maintain-runtime/linked-bound-controller.json"
  ec=0
  bash "$leases" acquire --repo-root "$linked" --mode maintain --run-id linked-bound \
    --state-file "$state" --worktree "$repo/.worktrees/maintain" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR15aa: bound canonical controller rejects a linked acquisition root" "$ec" 2
  assert_file_not_exists "MR15ab: rejected linked controller publishes no lease state" "$state"
  mkdir -p "$repo/probe-bin" "$common/saas-startup-team/maintain"
  cat > "$repo/probe-bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s\n' "$GH_ISSUES_JSON" ;;
  "issue view") printf '%s\n' "$GH_ISSUE_VIEW_JSON" ;;
  "pr list") printf '[]\n' ;;
  "repo view") printf 'main\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$repo/probe-bin/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "login status" ]
SH
  chmod +x "$repo/probe-bin/gh" "$repo/probe-bin/codex"
  long_reason=$(printf 'r%.0s' {1..502})
  jq -cn --arg reason "$long_reason" \
    '{number:42,reason:$reason,cooldown_until:"2099-01-01T00:00:00Z"}' \
    > "$common/saas-startup-team/maintain/blocked.jsonl"
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" \
    GH_ISSUES_JSON='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain 2>&1) || ec=$?
  assert_exit_code "MR15a: overlong legacy reason cannot wedge the probe" "$ec" 3
  rm -f "$common/saas-startup-team/maintain/blocked.jsonl"
  mkdir -p "$repo/.startup/maintain"
  printf '%s\n' '{"number":43,"reason":"primary legacy","cooldown_until":"2099-01-01T00:00:00Z"}' \
    > "$repo/.startup/maintain/blocked.jsonl"
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" \
    GH_ISSUES_JSON='[{"number":43,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain 2>&1) || ec=$?
  assert_exit_code "MR15b: linked probe reads primary legacy ledger" "$ec" 3
  rm -f "$repo/.startup/maintain/blocked.jsonl"
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[{"name":"maintain:blocked"}]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain 2>&1) || ec=$?
  assert_exit_code "MR15c: stale blocked label remains launchable" "$ec" 0
  assert_output_contains "MR15d: probe exposes stale-label cleanup" "$out" \
    'stale maintain:blocked cleanup: 44'
  routing_schema=$(bash "$PLUGIN_ROOT/scripts/delivery-route.sh" schema-version | jq -r .schema_version)
  mkdir -p "$linked/.startup/maintain"
  printf '{"schema_version":1,"routing_schema_version":%s,"number":44,"updatedAt":"2026-01-01T00:00:00Z","verdict":"agent-fixable","final_state":"escalated:no-progress"}\n' \
    "$routing_schema" > "$linked/.startup/maintain/triage-cache.jsonl"
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[{"name":"maintain:claimed"}]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain --issue 44 2>&1) || ec=$?
  assert_exit_code "MR15dac0: claimed work outranks a terminal cache entry" "$ec" 0
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[{"name":"maintain:blocked"}]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain 2>&1) || ec=$?
  assert_exit_code "MR15daa: stale-label cleanup outranks a terminal cache entry" "$ec" 0
  assert_output_contains "MR15dab: terminal cache still exposes stale-label cleanup" "$out" \
    'stale maintain:blocked cleanup: 44'
  rm -rf "$linked/.startup"
  mkdir -p "$linked/.startup/maintain"
  printf '{"schema_version":1,"routing_schema_version":%s,"number":44,"updatedAt":"2026-01-01T00:00:00Z","verdict":"agent-fixable","final_state":"escalated:no-progress"}\n' \
    "$routing_schema" > "$linked/.startup/maintain/triage-cache.jsonl"
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" SAAS_PREFLIGHT_MISSING=codex \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[]},{"number":99,"updatedAt":"2026-01-01T00:00:00Z","labels":[{"name":"maintain:blocked"}]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain --issue 44 2>&1) || ec=$?
  assert_exit_code "MR15dac: explicit issue ignores unrelated stale-label cleanup" "$ec" 3
  assert_output_not_contains "MR15dad: filtered probe never reports another issue" "$out" '99'
  rm -rf "$linked/.startup"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ptrace denied" >&2' 'exit 1' \
    > "$repo/probe-bin/python3"
  chmod +x "$repo/probe-bin/python3"
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" SAAS_PREFLIGHT_MISSING=codex \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain 2>&1) || ec=$?
  assert_exit_code "MR15da: model-free probe blocks denied worker containment" "$ec" 4
  assert_output_contains "MR15db: containment block is actionable" "$out" \
    'Linux ptrace support is required'
  rm -f "$repo/probe-bin/python3"
  owner="$lease_dir/.owners/probe-active.owner"
  bash "$single" --acquire maintain-delivery:pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" SAAS_PREFLIGHT_MISSING=codex \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain --dry-run 2>&1) || ec=$?
  assert_exit_code "MR15ea: read-only maintain dry-run ignores an active delivery lease" "$ec" 0
  ec=0
  out=$(cd "$linked" && PATH="$repo/probe-bin:$PATH" SAAS_PREFLIGHT_MISSING=codex \
    GH_ISSUES_JSON='[{"number":44,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' \
    bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain 2>&1) || ec=$?
  assert_exit_code "MR15e: model-free probe blocks an overlapping delivery pass" "$ec" 4
  bash "$single" --release maintain-delivery:pass --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
  git -C "$repo" worktree remove --force "$linked" >/dev/null

  victim="$repo/victim"; ledger="$repo/ledger.jsonl"
  printf 'unchanged\n' > "$victim"; ln -s "$victim" "$ledger"
  ec=0
  bash "$blocked" upsert --file "$ledger" --number 7 --reason retry \
    --cooldown-until 2099-01-01T00:00:00Z >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR16: cooldown upsert rejects a planted ledger symlink" "$ec" 1
  assert_equals "MR17: rejected ledger symlink cannot overwrite its target" "$(cat "$victim")" unchanged
  rm "$ledger"; ln -s "$victim" "$ledger.lock"
  bash "$blocked" upsert --file "$ledger" --number 7 --reason retry \
    --cooldown-until 2099-01-01T00:00:00Z >/dev/null
  assert_equals "MR18: obsolete lock-file symlink is never opened" "$(cat "$victim")" unchanged
  assert_equals "MR19: normalized upsert writes one canonical row" \
    "$(bash "$blocked" normalize --file "$ledger" | jq length)" 1
  bash "$blocked" upsert --file "$ledger" --number 8 --reason "$long_reason" \
    --cooldown-until 2099-01-01T00:00:00Z >/dev/null
  assert_equals "MR19a: cooldown upsert truncates an overlong reason" \
    "$(bash "$blocked" normalize --file "$ledger" | jq -r '.[] | select(.number == 8) | .reason | length')" 500
  malformed_file="$repo/malformed-first.jsonl"
  valid_file="$repo/valid-last.jsonl"
  printf '%s\n' '{"number":905,"reason":"broken","cooldown_until":"not-a-time"}' > "$malformed_file"
  printf '%s\n' '{"number":906,"reason":"valid","cooldown_until":"2099-01-01T00:00:00Z"}' > "$valid_file"
  ec=0
  out=$(bash "$blocked" normalize --file "$malformed_file" --file "$valid_file" 2>&1) || ec=$?
  assert_exit_code "MR19b: malformed multi-file input fails closed" "$ec" 1
  assert_output_contains "MR19c: diagnostic names the offending file" "$out" "$malformed_file"
  assert_output_contains "MR19d: diagnostic names the offending issue" "$out" 'issue #905'
  overlong_file="$repo/overlong.jsonl"
  jq -cn --arg reason "$long_reason" \
    '{number:42,reason:$reason,cooldown_until:"2099-01-01T00:00:00Z",ignored:"drop"}' \
    > "$overlong_file"
  diag_file="$repo/overlong.err"
  normalized=$(bash "$blocked" normalize --file "$overlong_file" 2>"$diag_file")
  assert_equals "MR19e: direct legacy write is canonicalized on read" \
    "$(jq -r '.[0].reason | length' <<<"$normalized")" 500
  assert_file_contains "MR19f: overlong-row diagnostic names its source file" "$diag_file" \
    "$overlong_file"
  assert_file_contains "MR19g: overlong-row diagnostic names its issue" "$diag_file" '#42'
  assert_equals "MR19h: normalization retains the canonical ledger projection" \
    "$(jq -r '.[0] | has("ignored")' <<<"$normalized")" false
  printf '%s\n' '{"number":7,"cooldown_until":"2099-01-01T00:00:00Z"}' > "$repo/malformed.jsonl"
  ec=0; bash "$blocked" normalize --file "$repo/malformed.jsonl" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR20: malformed cooldown row fails before cleanup routing" "$ec" 1
  printf '%s\n' '[{"number":7,"reason":"legacy","cooldown_until":"2099-01-01T00:00:00Z"}]' > "$repo/array.jsonl"
  ec=0; bash "$blocked" normalize --file "$repo/array.jsonl" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21: legacy ledger remains JSONL objects, not guessed arrays" "$ec" 1
  printf '%s\n' '{"number":8,"reason":"legacy date","cooldown_until":"2099-01-01"}' > "$repo/legacy-date.jsonl"
  assert_equals "MR21x: legacy date-only cooldown is canonicalized" \
    "$(bash "$blocked" normalize --file "$repo/legacy-date.jsonl" | jq -r '.[0].cooldown_until')" \
    "2099-01-01T00:00:00Z"
  assert_equals "MR21y: active accepts a legacy date-only cooldown" \
    "$(bash "$blocked" active --file "$repo/legacy-date.jsonl" --now 2026-01-01T00:00:00Z | jq -r '.[0]')" 8
  printf '%s\n' '{"number":8,"reason":"invalid legacy date","cooldown_until":"2026-02-31"}' > "$repo/legacy-date.jsonl"
  ec=0; bash "$blocked" normalize --file "$repo/legacy-date.jsonl" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21z: legacy date-only cooldown rejects an invalid calendar date" "$ec" 1
  ec=0
  bash "$blocked" upsert --file "$ledger" --number 8 --reason retry \
    --cooldown-until 2026-02-31T00:00:00Z >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21aa: cooldown rejects a normalized invalid calendar date" "$ec" 2
  ec=0
  bash "$blocked" active --file "$ledger" --now 2025-02-29T00:00:00Z \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21ab: active query rejects a non-leap February date" "$ec" 2

  state="$common/saas-startup-team/maintain-runtime/unbound-v2-attempt-leases.json"
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id unbound-v2-attempt \
    --state-file "$state" >/dev/null
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$canonical_wt" \
    --base-sha "$base" --lease-state "$state" --run-id unbound-v2-attempt \
    --controller-run-id unbound-v2-attempt \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21bind-a: unbound schema-v2 maintain state cannot authorize a worktree reset" "$ec" 1
  assert_file_not_exists "MR21bind-b: rejected unbound state creates no canonical worktree" "$canonical_wt"
  bash "$leases" cleanup --state-file "$state" --run-id unbound-v2-attempt >/dev/null

  legacy_attempt_state="$common/saas-startup-team/maintain-runtime/legacy-attempt-leases.json"
  wt="$repo/.worktrees/maintain-loop"
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop --run-id legacy-attempt \
    --state-file "$legacy_attempt_state" --worktree "$wt" >/dev/null
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$legacy_attempt_state" --run-id legacy-attempt \
    --controller-run-id legacy-attempt >/dev/null
  assert_equals "MR21bind-c: bounded schema-v2 adapter still resets the legacy worktree" \
    "$(git -C "$wt" rev-parse HEAD):$(jq -r '.schema_version|tostring + ":"' "$legacy_attempt_state")$(jq -r .mode "$legacy_attempt_state")" \
    "$base:2:maintain-loop"
  bash "$leases" cleanup --state-file "$legacy_attempt_state" --repo-root "$repo" \
    --worktree "$wt" --run-id legacy-attempt >/dev/null
  git -C "$repo" worktree remove --force "$wt" >/dev/null

  canonical_wt="$repo/.worktrees/maintain"
  canonical_state="$common/saas-startup-team/maintain-runtime/attempt-leases.json"
  state=$canonical_state; wt=$canonical_wt
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id "$controller_run_id" \
    --state-file "$state" --worktree "$wt" >/dev/null
  assert_equals "MR21bind-d: canonical lease state binds the exact maintain worktree" \
    "$(jq -r .worktree "$state")" "$wt"
  assert_equals "MR21bind-e: canonical worktree binding uses the explicit v3 contract" \
    "$(jq -r '(.schema_version|tostring) + ":" + .mode + ":" + ((.leases|length)|tostring)' "$state")" \
    "3:maintain:4"
  assert_equals "MR21bind-f: canonical worktree lease uses its own key namespace" \
    "$(jq -r '.leases[]|select(.kind=="worktree")|.key|startswith("maintain:worktree:")' "$state")" true
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21bind-g: reset requires an explicit current controller identity" "$ec" 2
  assert_file_not_exists "MR21bind-h: missing controller cannot create the worktree" "$wt"
  lease_before=$(lease_state_fingerprint "$state")
  runtime_before=$(tar -C "$common/saas-startup-team/maintain-runtime" --sort=name -cf - . \
    | sha256sum | awk '{print $1}')
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" --controller-run-id wrong-controller \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21bind-i: reset rejects a controller that does not own the lease" "$ec" 1
  assert_file_not_exists "MR21bind-j: mismatched controller cannot create the worktree" "$wt"
  lease_after=$(lease_state_fingerprint "$state")
  runtime_after=$(tar -C "$common/saas-startup-team/maintain-runtime" --sort=name -cf - . \
    | sha256sum | awk '{print $1}')
  assert_equals "MR21bind-ja: rejected reset cannot heartbeat another controller's lease" \
    "$lease_after" "$lease_before"
  assert_equals "MR21bind-jb: rejected reset leaves maintenance runtime byte-identical" \
    "$runtime_after" "$runtime_before"
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$repo" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" --controller-run-id "$controller_run_id" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21b: reset rejects the primary worktree" "$ec" 1
  assert_equals "MR21c: rejected primary reset leaves HEAD intact" \
    "$(git -C "$repo" rev-parse HEAD)" "$second"
  forged_state="$common/saas-startup-team/maintain-runtime/forged-worktree.json"
  jq --arg worktree "$repo" '.worktree=$worktree' "$state" > "$forged_state"
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$repo" --base-sha "$base" \
    --lease-state "$forged_state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR21d: forged lease state cannot authorize a primary reset" "$ec" 1
  rm -f "$forged_state"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "MR22: reset pins the dedicated worktree to exact BASE_SHA" \
    "$(git -C "$wt" rev-parse HEAD)" "$base"
  canonical_gate="$common/saas-startup-team/maintain-runtime/base-checks/attempt-run/$base.json"
  canonical_summary="$repo/.startup/maintain-loop/base-checks/attempt-run/$base.summary"
  mkdir -p "$(dirname -- "$canonical_gate")"
  check_oid=$(git -C "$wt" rev-parse "$base:check.sh")
  jq -n --arg run_id attempt-run --arg base_sha "$base" --arg check_oid "$check_oid" \
    '{schema_version:1,run_id:$run_id,base_sha:$base_sha,check_rel:"check.sh",
      check_oid:$check_oid,status:"passed"}' > "$canonical_gate"
  bash "$attempt_helper" base-check --repo-root "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" --controller-run-id "$controller_run_id" \
    --cache-dir "$common/saas-startup-team/maintain-runtime/base-checks/attempt-run" \
    --check ./check.sh >/dev/null
  assert_equals "MR22aa: canonical binding reaches and passes the protected base check" \
    "$(jq -r '.status + ":" + .run_id' "$canonical_gate")" "passed:attempt-run"
  rm -f -- "$canonical_gate" "$canonical_summary"

  guard_dir="$(git -C "$wt" rev-parse --absolute-git-dir)/saas-startup-team"
  active_guard="$guard_dir/role-old-active-1.json"
  verified_guard="$guard_dir/role-old-verified-2.json"
  unrelated="$guard_dir/unrelated.keep"
  telemetry_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  mkdir -p "$active_guard.logs-$telemetry_id" "$verified_guard.logs-$telemetry_id"
  printf '{}\n' > "$active_guard"; printf 'active\n' > "$active_guard.active"
  printf 'events\n' > "$active_guard.events-$telemetry_id.jsonl"
  printf 'key\n' > "$active_guard.events-$telemetry_id.jsonl.identity-key"
  printf 'lock\n' > "$active_guard.events-$telemetry_id.jsonl.lock"
  printf '{}\n' > "$active_guard.telemetry-$telemetry_id.json"
  printf 'identity\n' > "$active_guard.telemetry-identity-key"
  printf 'log\n' > "$active_guard.logs-$telemetry_id/full.jsonl"
  printf '{}\n' > "$verified_guard"; printf 'verified\n' > "$verified_guard.verified"
  printf 'events\n' > "$verified_guard.events-$telemetry_id.jsonl"
  printf 'key\n' > "$verified_guard.events-$telemetry_id.jsonl.identity-key"
  printf 'lock\n' > "$verified_guard.events-$telemetry_id.jsonl.lock"
  printf '{}\n' > "$verified_guard.telemetry-$telemetry_id.json"
  printf 'identity\n' > "$verified_guard.telemetry-identity-key"
  printf 'log\n' > "$verified_guard.logs-$telemetry_id/full.jsonl"
  printf 'preserve\n' > "$unrelated"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_file_not_exists "MR22a: reset removes an abandoned active marker" \
    "$active_guard.active"
  assert_file_not_exists "MR22b: reset removes the active guard snapshot" "$active_guard"
  assert_file_not_exists "MR22c: reset removes the active guard event family" \
    "$active_guard.events-$telemetry_id.jsonl"
  assert_file_not_exists "MR22d: reset removes the active guard log family" \
    "$active_guard.logs-$telemetry_id"
  assert_file_not_exists "MR22e: reset removes an abandoned verified marker" \
    "$verified_guard.verified"
  assert_file_not_exists "MR22f: reset removes the verified guard snapshot" "$verified_guard"
  assert_file_not_exists "MR22g: reset removes the verified telemetry family" \
    "$verified_guard.telemetry-$telemetry_id.json"
  assert_file_not_exists "MR22h: reset removes the verified guard log family" \
    "$verified_guard.logs-$telemetry_id"
  assert_file_contains "MR22i: reset preserves unrelated worktree Git metadata" \
    "$unrelated" preserve

  worker_bin="$repo/reset-worker-bin"; worker_called="$repo/reset-worker-called"
  mkdir -p "$worker_bin"
  cat > "$worker_bin/codex" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_CALLED:-}" ] || : > "$FAKE_CALLED"
while [ "$#" -gt 0 ]; do shift; done
cat >/dev/null
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"recovered worker"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1,"cached_input_tokens":0}}'
SH
  chmod +x "$worker_bin/codex"
  ec=0
  out=$(cd "$wt" && PATH="$worker_bin:$PATH" FAKE_CALLED="$worker_called" \
    SAAS_AGENT_EVENTS_FILE="$repo/reset-worker-events.jsonl" \
    SAAS_CODEX_LOG_DIR="$repo/reset-worker-logs" SAAS_RUN_ID=reset-recovery-worker \
    bash "$PLUGIN_ROOT/scripts/codex-run-role.sh" \
      --role qa --profile light --task-file check.sh 2>&1) || ec=$?
  assert_exit_code "MR22j: recovered guard discovery permits a later worker" "$ec" 0
  assert_file_exists "MR22k: recovered guard discovery launches Codex" "$worker_called"

  guard_victim="$repo/guard-cleanup-victim"
  printf 'unchanged\n' > "$guard_victim"
  ln -s "$guard_victim" "$guard_dir/role-unsafe.json.active"
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR22l: reset fails closed on an unsafe guard marker" "$ec" 1
  assert_equals "MR22m: unsafe marker cleanup never touches its symlink target" \
    "$(cat "$guard_victim")" unchanged
  assert_equals "MR22n: failed guard cleanup leaves the unsafe marker for inspection" \
    "$([ -L "$guard_dir/role-unsafe.json.active" ] && printf present || printf missing)" present
  assert_file_contains "MR22o: unsafe marker failure preserves unrelated metadata" \
    "$unrelated" preserve
  rm -f "$guard_dir/role-unsafe.json.active"

  inactive_guard="$guard_dir/role-no-lease.json"
  printf '{}\n' > "$inactive_guard"; printf 'active\n' > "$inactive_guard.active"
  shared_owner=$(jq -r '.leases[] | select(.kind == "shared") | .owner_file' "$state")
  bash "$single" --release maintain-delivery:pass --state-dir "$lease_dir" \
    --owner-file "$shared_owner" >/dev/null
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR22p: abandoned guard cleanup requires the active lease set" "$ec" 1
  assert_file_exists "MR22q: missing lease leaves abandoned guard metadata untouched" \
    "$inactive_guard.active"
  bash "$leases" cleanup --state-file "$state" --repo-root "$repo" --worktree "$wt" \
    --run-id "$controller_run_id" >/dev/null
  bash "$leases" acquire --repo-root "$repo" --mode maintain --run-id "$controller_run_id" \
    --state-file "$state" --worktree "$wt" >/dev/null
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_file_not_exists "MR22r: reacquired exclusive lease permits abandoned guard cleanup" \
    "$inactive_guard.active"
  assert_file_contains "MR22s: bounded recovery still preserves unrelated metadata" \
    "$unrelated" preserve

  rm -rf "$wt"
  assert_file_not_exists "MR22t: registered worktree target is absent for recreation" "$wt"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "MR22u: reset recreates an absent registered worktree at BASE_SHA" \
    "$(git -C "$wt" rev-parse HEAD)" "$base"
  assert_equals "MR22v: recreated registered worktree is clean" \
    "$(git -C "$wt" status --porcelain=v1 --untracked-files=all)" ""

  metadata_git_dir=$(git -C "$wt" rev-parse --absolute-git-dir)
  recovery_guard="$metadata_git_dir/saas-startup-team/role-corrupt-metadata.json"
  mkdir -p "$(dirname -- "$recovery_guard")"
  printf '{}\n' > "$recovery_guard"; printf 'active\n' > "$recovery_guard.active"
  printf 'broken gitfile\n' > "$wt/.git"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "MR22va: reset repairs a corrupt registered worktree gitfile" \
    "$(git -C "$wt" rev-parse --absolute-git-dir)" "$metadata_git_dir"
  assert_file_not_exists "MR22vb: repaired metadata still cleans safe abandoned guards" \
    "$recovery_guard.active"

  printf '/missing/corrupt-worktree/.git\n' > "$metadata_git_dir/gitdir"
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR22vc: reset rejects metadata with no binding backpointer" "$ec" 1
  assert_equals "MR22vd: rejected backpointer repair preserves the metadata entry" \
    "$(cat "$metadata_git_dir/gitdir")" /missing/corrupt-worktree/.git
  printf '%s\n' "$wt/.git" > "$metadata_git_dir/gitdir"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "MR22vda: restored binding preserves exact clean BASE_SHA" \
    "$(git -C "$wt" rev-parse HEAD):$(git -C "$wt" status --porcelain=v1 --untracked-files=all)" \
    "$base:"

  metadata_peer="$repo/.worktrees/metadata-peer"
  git -C "$repo" worktree add -q --detach "$metadata_peer" "$second"
  peer_git_dir=$(git -C "$metadata_peer" rev-parse --absolute-git-dir)
  peer_backpointer=$(cat "$peer_git_dir/gitdir")
  peer_head=$(git -C "$metadata_peer" rev-parse HEAD)
  printf 'gitdir: %s\n' "$peer_git_dir" > "$wt/.git"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "MR22vdb: repair follows the target backpointer, not a forged gitfile" \
    "$(git -C "$wt" rev-parse --absolute-git-dir)" "$metadata_git_dir"
  assert_equals "MR22vdc: forged gitfile repair preserves the peer backpointer" \
    "$(cat "$peer_git_dir/gitdir")" "$peer_backpointer"
  assert_equals "MR22vdd: forged gitfile repair preserves the peer HEAD" \
    "$(git -C "$metadata_peer" rev-parse HEAD)" "$peer_head"

  printf '/missing/unbound-worktree/.git\n' > "$metadata_git_dir/gitdir"
  printf 'gitdir: %s\n' "$peer_git_dir" > "$wt/.git"
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR22vde: forged gitfile cannot replace a missing target binding" "$ec" 1
  assert_equals "MR22vdf: rejected forged gitfile preserves the peer backpointer" \
    "$(cat "$peer_git_dir/gitdir")" "$peer_backpointer"
  assert_equals "MR22vdg: rejected forged gitfile preserves the peer HEAD" \
    "$(git -C "$metadata_peer" rev-parse HEAD)" "$peer_head"
  printf '%s\n' "$wt/.git" > "$metadata_git_dir/gitdir"
  printf 'gitdir: %s\n' "$metadata_git_dir" > "$wt/.git"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  git -C "$repo" worktree remove --force "$metadata_peer" >/dev/null

  corrupt_guard_victim="$repo/corrupt-guard-victim"
  printf 'unchanged\n' > "$corrupt_guard_victim"
  ln -s "$corrupt_guard_victim" "$metadata_git_dir/saas-startup-team/role-corrupt-unsafe.json.active"
  printf 'broken again\n' > "$wt/.git"
  ec=0
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR22ve: corrupt metadata cannot bypass unsafe guard rejection" "$ec" 1
  assert_equals "MR22vf: corrupt-metadata recovery never follows an unsafe guard" \
    "$(cat "$corrupt_guard_victim")" unchanged
  assert_equals "MR22vg: rejected corrupt-metadata guard remains inspectable" \
    "$([ -L "$metadata_git_dir/saas-startup-team/role-corrupt-unsafe.json.active" ] \
      && printf present || printf missing)" present
  rm -f "$metadata_git_dir/saas-startup-team/role-corrupt-unsafe.json.active"

  assert_file_contains "MR22w: reset has a bounded internal lease holder" \
    "$attempt_helper" '--max-seconds 300'
  assert_file_not_contains "MR22wa: reset observes worktree inventory producer failures" \
    "$attempt_helper" '< <(git -C "$ROOT" worktree list'
  reset_bin="$repo/reset-slow-bin"; mkdir -p "$reset_bin"
  reset_ready="$repo/reset-slow-ready"; reset_status="$repo/reset-slow-status"
  real_git=$(command -v git)
  cat > "$reset_bin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != clean ] || { : > "$RESET_SLOW_READY"; sleep 2; break; }
done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$reset_bin/git"
  reset_heartbeat=$(jq -r '.leases[] | select(.kind == "shared") | .state_dir' "$state")/maintain-delivery-pass/heartbeat
  (
    reset_ec=0
    PATH="$reset_bin:$PATH" REAL_GIT="$real_git" RESET_SLOW_READY="$reset_ready" \
      bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
        --lease-state "$state" --run-id "$origin_run" \
        --controller-run-id "$controller_run_id" >/dev/null 2>&1 || reset_ec=$?
    printf '%s\n' "$reset_ec" > "$reset_status"
  ) &
  reset_pid=$!
  while [ ! -e "$reset_ready" ]; do kill -0 "$reset_pid" 2>/dev/null || break; sleep 0.01; done
  assert_file_exists "MR22x: slow reset reaches the held mutation phase" "$reset_ready"
  reset_heartbeat_before=$(cat "$reset_heartbeat")
  reset_heartbeat_after=$reset_heartbeat_before
  for ((i=0; i<400; i++)); do
    reset_heartbeat_after=$(cat "$reset_heartbeat")
    [ "$reset_heartbeat_after" = "$reset_heartbeat_before" ] || break
    kill -0 "$reset_pid" 2>/dev/null || break
    sleep 0.01
  done
  assert_equals "MR22y: slow reset advances its lease heartbeat continuously" \
    "$([[ "$reset_heartbeat_after" -gt "$reset_heartbeat_before" ]] && printf yes || printf no)" yes
  wait "$reset_pid"
  assert_equals "MR22z: held slow reset completes successfully" "$(cat "$reset_status")" 0

  printf 'dirty\n' > "$wt/app.txt"; printf 'new\n' > "$wt/untracked"
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "MR23: reset removes tracked and untracked attempt state" \
    "$(git -C "$wt" status --porcelain=v1 --untracked-files=all)" ""
  assert_file_contains "MR23a: attempt results include issue and attempt identity" \
    "$attempt_helper" 'issue-$ISSUE_NUMBER-attempt-$attempt.json'

  git -C "$wt" switch -q -c issue/7-test
  check_oid=$(git -C "$wt" rev-parse "$base:check.sh")
  prompt_dir="$repo/.startup/maintain-loop/prompts/attempt-run"; mkdir -p "$prompt_dir"
  prompt="$prompt_dir/issue-7-attempt-1.md"; printf 'task\n' > "$prompt"
  ec=0
  SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --child-run-id "$child_run_id" --attempt 1 --profile standard --task-file "$prompt" \
    --message test --check ./check.sh --allow app.txt >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR23b: delivery requires an explicit current controller identity" "$ec" 2
  ec=0
  SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" --attempt 1 --profile standard \
    --task-file "$prompt" --message test --check ./check.sh --allow app.txt \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR23c: delivery requires a fresh canonical child identity" "$ec" 2
  ec=0
  SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" --child-run-id "$controller_run_id" \
    --attempt 1 --profile standard --task-file "$prompt" --message test \
    --check ./check.sh --allow app.txt >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR23d: delivery child must differ from the current controller" "$ec" 2
  ec=0
  SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" --run-id "$child_run_id" \
    --controller-run-id "$controller_run_id" --child-run-id "$child_run_id" \
    --attempt 1 --profile standard --task-file "$prompt" --message test \
    --check ./check.sh --allow app.txt >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR23e: delivery child must differ from the receipt origin" "$ec" 2
  ec=0
  SAAS_INVOCATION_COMMAND= bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" --child-run-id "$child_run_id" \
    --attempt 1 --profile standard --task-file "$prompt" --message test \
    --check ./check.sh --allow app.txt >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR23f: delivery requires a finite invocation command" "$ec" 2
  fake_gate="$repo/.startup/maintain-loop/base-checks/attempt-run/$base.json"
  mkdir -p "$(dirname "$fake_gate")"
  jq -n --arg base_sha "$base" --arg check_oid "$check_oid" \
    '{schema_version:1,run_id:"attempt-run",base_sha:$base_sha,check_rel:"check.sh",
      check_oid:$check_oid,status:"passed"}' > "$fake_gate"
  ec=0
  SAAS_INVOCATION_COMMAND= bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" \
    --run-id "$origin_run" --controller-run-id "$controller_run_id" \
    --child-run-id "$child_run_id" --invocation-command maintain \
    --attempt 1 --profile standard --task-file "$prompt" \
    --message test --check ./check.sh --allow app.txt >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR24: worker-forged primary base gate is ignored" "$ec" 1

  mkdir -p "$common/saas-startup-team/maintain-runtime/base-checks/attempt-run"
  cp "$fake_gate" "$common/saas-startup-team/maintain-runtime/base-checks/attempt-run/$base.json"
  cwd_worker_bin="$repo/cwd-worker-bin"; cwd_worker_seen="$repo/cwd-worker-seen"
  mkdir -p "$cwd_worker_bin"
  cat > "$cwd_worker_bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" > "$WORKER_CWD_SEEN"
while [ "$#" -gt 0 ]; do shift; done
cat >/dev/null
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"worker complete"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1,"cached_input_tokens":0}}'
SH
  chmod +x "$cwd_worker_bin/codex"
  ec=0
  (cd "$repo" && PATH="$cwd_worker_bin:$PATH" WORKER_CWD_SEEN="$cwd_worker_seen" \
    SAAS_INVOCATION_COMMAND= bash "$attempt_helper" deliver \
      --repo-root "$wt" --base-sha "$base" --lease-state "$state" \
      --run-id "$origin_run" --controller-run-id "$controller_run_id" \
      --child-run-id "$child_run_id_2" --invocation-command maintain \
      --attempt 1 --profile standard --task-file "$prompt" \
      --message test --check ./check.sh --allow app.txt >/dev/null 2>&1) || ec=$?
  assert_file_exists "MR24a: contained delivery worker launches from a primary caller" "$cwd_worker_seen"
  assert_equals "MR24b: delivery worker cwd is the leased dedicated worktree" \
    "$(cat "$cwd_worker_seen")" "$wt"
  assert_equals "MR24c: source-free cwd regression fixture still fails delivery" \
    "$([ "$ec" -ne 0 ] && printf true || printf false)" true
  agent_events="$repo/.startup/runs/agent-events.jsonl"
  assert_equals "MR24d: worker telemetry binds the child to the current controller" \
    "$(jq -s --arg child "$child_run_id_2" --arg parent "$controller_run_id" \
      '[.[] | select(.run_id == $child)]
       | length == 2 and all(.[]; .parent_run_id == $parent)' "$agent_events")" true
  assert_equals "MR24e: direct maintain delivery preserves its invocation command" \
    "$(jq -s --arg child "$child_run_id_2" \
      '[.[] | select(.run_id == $child)]
       | length == 2 and all(.[]; .command == "maintain")' "$agent_events")" true

  rm "$prompt"; ln -s "$repo/check.sh" "$prompt"
  ec=0
  SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" \
    --run-id "$origin_run" --controller-run-id "$controller_run_id" \
    --child-run-id "$child_run_id_3" --attempt 1 --profile standard --task-file "$prompt" \
    --message test --check ./check.sh --allow app.txt >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR25: source transaction rejects supplied prompt symlink" "$ec" 1

  rm -f "$prompt"; printf 'task\n' > "$prompt"
  role_guard=$(git -C "$wt" rev-parse --git-path 'saas-startup-team/role-attempt-run-1.json')
  telemetry_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$(dirname -- "$role_guard")" "$role_guard.logs-$telemetry_id"
  printf 'active\n' > "$role_guard.active"
  printf 'buffer\n' > "$role_guard.events-$telemetry_id.jsonl"
  printf 'key\n' > "$role_guard.events-$telemetry_id.jsonl.identity-key"
  printf 'lock\n' > "$role_guard.events-$telemetry_id.jsonl.lock"
  printf 'shared\n' > "$role_guard.telemetry-identity-key"
  printf '{}\n' > "$role_guard.telemetry-$telemetry_id.json"
  printf 'full log\n' > "$role_guard.logs-$telemetry_id/full.jsonl"
  ec=0
  out=$(cd "$wt" && SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" \
    --run-id "$origin_run" --controller-run-id "$controller_run_id" \
    --child-run-id "$child_run_id_4" --attempt 1 --profile standard --task-file "$prompt" \
    --message test --check ./check.sh --allow app.txt 2>&1) || ec=$?
  assert_equals "MR25a: guard setup failure propagates from an attempt" \
    "$([ "$ec" -ne 0 ] && printf true || printf false)" true
  assert_file_not_exists "MR25aa: failed attempt removes its active marker" "$role_guard.active"
  assert_file_not_exists "MR25b: failed attempt removes its guarded event buffer" \
    "$role_guard.events-$telemetry_id.jsonl"
  assert_file_not_exists "MR25c: failed attempt removes its guarded event identity" \
    "$role_guard.events-$telemetry_id.jsonl.identity-key"
  assert_file_not_exists "MR25d: failed attempt removes its guarded event lock" \
    "$role_guard.events-$telemetry_id.jsonl.lock"
  assert_file_not_exists "MR25e: failed attempt removes its shared telemetry identity" \
    "$role_guard.telemetry-identity-key"
  assert_file_not_exists "MR25f: failed attempt removes its telemetry receipt" \
    "$role_guard.telemetry-$telemetry_id.json"
  assert_file_not_exists "MR25g: failed attempt removes its full-log buffer" \
    "$role_guard.logs-$telemetry_id"

  rm -f "$common/saas-startup-team/maintain-runtime/base-checks/attempt-run/$base.json"
  rm -f "$prompt"; printf 'task\n' > "$prompt"
  summary="$repo/.startup/maintain-loop/base-checks/attempt-run/$base.summary"
  mkdir -p "$(dirname "$summary")"; rm -f "$summary"; ln -s "$victim" "$summary"
  ec=0
  bash "$attempt_helper" base-check --repo-root "$wt" --base-sha "$base" \
    --lease-state "$state" --run-id "$origin_run" --controller-run-id "$controller_run_id" \
    --cache-dir "$common/saas-startup-team/maintain-runtime/base-checks/attempt-run" \
    --check ./check.sh >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR26: base-check rejects a planted summary symlink" "$ec" 1
  assert_equals "MR27: summary symlink target remains unchanged" "$(cat "$victim")" unchanged
  bash "$leases" cleanup --state-file "$state" --repo-root "$repo" --worktree "$wt" \
    --run-id "$controller_run_id" >/dev/null
  git -C "$repo" worktree remove --force "$wt" >/dev/null

  lease_dir="$repo/guardian-leases"; owner="$repo/guardian.owner"
  mkdir -p "$lease_dir"
  lock_victim="$repo/lock-victim"; printf 'unchanged\n' > "$lock_victim"
  ln -s "$lock_victim" "$lease_dir/.single-flight-cancel-test.lock"
  bash "$single" --acquire cancel:test --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
  assert_equals "MR27a: legacy predictable lock symlink is never opened" \
    "$(cat "$lock_victim")" unchanged

  bash "$single" --acquire legacy:race --state-dir "$lease_dir" --owner legacy-owner >/dev/null
  printf '1\n' > "$lease_dir/legacy-race/heartbeat"
  legacy_ready="$repo/legacy-heartbeat-ready"
  legacy_release="$repo/legacy-heartbeat-release"
  legacy_takeover_ready="$repo/legacy-takeover-ready"
  legacy_takeover_status="$repo/legacy-takeover-status"
  real_flock=$(command -v flock)
  (
    exec 6>"$lease_dir/.single-flight-legacy-race.lock"
    "$real_flock" -x 6
    : > "$legacy_ready"
    while [ ! -e "$legacy_release" ]; do sleep 0.01; done
    date +%s > "$lease_dir/legacy-race/heartbeat"
  ) &
  legacy_heartbeat_pid=$!
  while [ ! -e "$legacy_ready" ]; do kill -0 "$legacy_heartbeat_pid" 2>/dev/null || break; sleep 0.01; done
  assert_file_exists "MR27aa: legacy heartbeat holds the old per-key lock" "$legacy_ready"
  legacy_lock_bin="$repo/legacy-lock-bin"; mkdir -p "$legacy_lock_bin"
  cat > "$legacy_lock_bin/flock" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "${WAIT_FD:-7}" ]; then : > "$TAKEOVER_READY"; fi
exec "$REAL_FLOCK" "$@"
SH
  chmod +x "$legacy_lock_bin/flock"
  (
    takeover_ec=0
    PATH="$legacy_lock_bin:$PATH" REAL_FLOCK="$real_flock" TAKEOVER_READY="$legacy_takeover_ready" \
      bash "$single" --acquire legacy:race --state-dir "$lease_dir" --owner new-owner \
        --ttl-seconds 1 --lock-timeout-seconds 5 --replace-stale --reason expired \
        >/dev/null 2>&1 || takeover_ec=$?
    printf '%s\n' "$takeover_ec" > "$legacy_takeover_status"
  ) &
  legacy_takeover_pid=$!
  while [ ! -e "$legacy_takeover_ready" ]; do kill -0 "$legacy_takeover_pid" 2>/dev/null || break; sleep 0.01; done
  assert_file_exists "MR27ab: stale takeover reaches the legacy lock" "$legacy_takeover_ready"
  assert_file_not_exists "MR27ac: takeover waits for the in-flight legacy heartbeat" \
    "$legacy_takeover_status"
  : > "$legacy_release"
  wait "$legacy_heartbeat_pid"; wait "$legacy_takeover_pid"
  assert_equals "MR27ad: fresh legacy heartbeat prevents stale takeover" \
    "$(cat "$legacy_takeover_status")" 1
  assert_equals "MR27ae: refused takeover preserves the legacy owner" \
    "$(cat "$lease_dir/legacy-race/owner")" legacy-owner
  bash "$single" --release legacy:race --state-dir "$lease_dir" --owner legacy-owner >/dev/null

  owner="$repo/legacy-shared.owner"
  owner_lock_id=$(printf '%s' "$(realpath -m -- "$owner")" | cksum | awk '{print $1}')
  legacy_ready="$repo/legacy-owner-ready"
  legacy_release="$repo/legacy-owner-release"
  legacy_takeover_ready="$repo/legacy-owner-contender-ready"
  legacy_takeover_status="$repo/legacy-owner-contender-status"
  (
    exec 6>"$lease_dir/.single-flight-owner-$owner_lock_id.lock"
    "$real_flock" -x 6
    : > "$legacy_ready"
    while [ ! -e "$legacy_release" ]; do sleep 0.01; done
    printf 'legacy-shared-owner\n' > "$owner"
    printf 'owner:old\n' > "$owner.key"
  ) &
  legacy_heartbeat_pid=$!
  while [ ! -e "$legacy_ready" ]; do kill -0 "$legacy_heartbeat_pid" 2>/dev/null || break; sleep 0.01; done
  assert_file_exists "MR27af: legacy client holds the old owner-file lock" "$legacy_ready"
  (
    contender_ec=0
    PATH="$legacy_lock_bin:$PATH" REAL_FLOCK="$real_flock" TAKEOVER_READY="$legacy_takeover_ready" WAIT_FD=6 \
      bash "$single" --acquire owner:new --state-dir "$lease_dir" --owner-file "$owner" \
        --lock-timeout-seconds 5 >/dev/null 2>&1 || contender_ec=$?
    printf '%s\n' "$contender_ec" > "$legacy_takeover_status"
  ) &
  legacy_takeover_pid=$!
  while [ ! -e "$legacy_takeover_ready" ]; do kill -0 "$legacy_takeover_pid" 2>/dev/null || break; sleep 0.01; done
  assert_file_exists "MR27ag: new client reaches the legacy owner-file lock" \
    "$legacy_takeover_ready"
  assert_file_not_exists "MR27ah: different-key contender waits for legacy owner publication" \
    "$legacy_takeover_status"
  : > "$legacy_release"
  wait "$legacy_heartbeat_pid"; wait "$legacy_takeover_pid"
  assert_equals "MR27ai: published legacy owner binding rejects the different key" \
    "$(cat "$legacy_takeover_status")" 2
  assert_equals "MR27aj: rejected contender preserves the legacy owner token" \
    "$(cat "$owner")" legacy-shared-owner
  assert_equals "MR27ak: rejected contender preserves the legacy key binding" \
    "$(cat "$owner.key")" owner:old
  rm -f "$owner" "$owner.key"
  owner="$repo/guardian.owner"

  old_heartbeat=$(cat "$lease_dir/cancel-test/heartbeat")
  old_audit=$(cat "$lease_dir/cancel-test/audit.log")
  fake_bin="$repo/fake-mv"; mkdir -p "$fake_bin"; real_mv=$(command -v mv)
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
count=0; [ ! -f "$MV_COUNT" ] || count=$(cat "$MV_COUNT")
count=$((count + 1)); printf '%s\n' "$count" > "$MV_COUNT"
[ "$count" -ne 1 ] || exit 1
exec "$REAL_MV" "$@"
SH
  chmod +x "$fake_bin/mv"
  ec=0
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" MV_COUNT="$repo/mv-count" \
    bash "$single" --heartbeat cancel:test --state-dir "$lease_dir" \
      --owner-file "$owner" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR27b: interrupted atomic heartbeat publication fails" "$ec" 1
  assert_equals "MR27c: failed heartbeat publication preserves prior value" \
    "$(cat "$lease_dir/cancel-test/heartbeat")" "$old_heartbeat"
  assert_equals "MR27ca: failed heartbeat publication records no false audit" \
    "$(cat "$lease_dir/cancel-test/audit.log")" "$old_audit"
  assert_equals "MR27d: failed heartbeat publication removes its temporary file" \
    "$(find "$lease_dir/cancel-test" -maxdepth 1 -name '.*.tmp.*' -print -quit)" ""
  ec=0
  bash "$guardian" probe >/dev/null 2>&1 || ec=$?
  assert_exit_code "MR27e: containment capability probe succeeds" "$ec" 0
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fake_bin/python3"
  chmod +x "$fake_bin/python3"
  ec=0; out=""
  out=$(PATH="$fake_bin:$PATH" bash "$guardian" probe 2>&1) || ec=$?
  assert_exit_code "MR27f: containment probe fails closed when ptrace is denied" "$ec" 1
  assert_output_contains "MR27g: failed probe explains the required capability" "$out" \
    "Linux ptrace support is required"
  rm -f "$fake_bin/python3"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fake_bin/setpriv"
  chmod +x "$fake_bin/setpriv"
  ec=0; out=""
  out=$(PATH="$fake_bin:$PATH" bash "$guardian" probe 2>&1) || ec=$?
  assert_exit_code "MR27h: containment probe fails closed when setpriv is denied" "$ec" 1
  assert_output_contains "MR27i: failed setpriv probe explains parent-death requirement" \
    "$out" "parent-death signaling"
  rm -f "$fake_bin/setpriv"
  ec=0; out=""
  out=$(bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -lc 'ps aux >/dev/null; printf procps-ok' 2>&1) || ec=$?
  assert_exit_code "MR27j: procps runs inside the lease holder" "$ec" 0
  assert_output_contains "MR27k: procps holder reaches the command" "$out" "procps-ok"
  ready="$repo/lock-ready"; release="$repo/lock-release"; marker="$repo/child-launched"
  mkfifo "$release"
  bash -c 'exec 9<"$1"; flock -x 9; : > "$2"; read -r _ < "$3"' _ \
    "$lease_dir" "$ready" "$release" &
  locker=$!
  for _ in {1..50}; do [ ! -e "$ready" ] || break; sleep 0.02; done
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- bash -c ': > "$1"' _ "$marker" &
  holder=$!; sleep 0.1; kill -TERM "$holder"; printf 'release\n' > "$release"; wait "$locker"
  ec=0; wait "$holder" || ec=$?
  assert_exit_code "MR28: signal during initial heartbeat returns TERM status" "$ec" 143
  assert_file_not_exists "MR29: pending TERM prevents child launch" "$marker"

  for signal in INT HUP; do
    signal_marker="$repo/child-$signal"
    ec=0
    timeout --preserve-status --signal="$signal" --kill-after=5s 1s \
      bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
      --interval-seconds 1 --max-seconds 10 -- \
      bash -c 'trap ": > \"$1\"; exit 0" "$2"; while :; do sleep 1; done' \
        _ "$signal_marker" "$signal" >/dev/null 2>&1 || ec=$?
    if [ "$signal" = INT ]; then expected=130; else expected=129; fi
    assert_exit_code "MR30: guardian propagates $signal status" "$ec" "$expected"
    assert_file_exists "MR31: guardian forwards $signal to child" "$signal_marker"
  done
  signal_marker="$repo/child-timeout"; ready="$repo/ready-timeout"
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 1 -- \
    bash -c 'trap ": > \"$1\"; exit 0" TERM; : > "$2"; while :; do sleep 1; done' \
      _ "$signal_marker" "$ready" &
  holder=$!; ec=0; wait "$holder" || ec=$?
  assert_exit_code "MR32: guardian enforces maximum child lifetime" "$ec" 1
  assert_file_exists "MR33: lifetime expiry terminates the child" "$signal_marker"
  signal_marker="$repo/fire-and-forget-stopped"; ready="$repo/fire-and-forget-ready"
  descendant="$repo/descendant-pid"
  ec=0
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -c 'bash -c '\''trap ": > \"$1\"; exit 0" TERM; : > "$2"; \
      while :; do sleep 1; done'\'' _ "$1" "$2" & printf "%s\n" "$!" > "$3"; \
      while [ ! -e "$2" ]; do sleep 0.01; done' \
      _ "$signal_marker" "$ready" "$descendant" || ec=$?
  assert_exit_code "MR34: foreground child status survives descendant cleanup" "$ec" 0
  assert_file_exists "MR35: fire-and-forget descendant is terminated" "$signal_marker"

  ready="$repo/fork-active-ready"; escape_sentinel="$repo/fork-active-survived"
  ec=0
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -c 'bash -c '\''trap "" TERM; : > "$1"; deadline=$((SECONDS + 3)); \
      while [ "$SECONDS" -lt "$deadline" ]; do (:); done; : > "$2"'\'' \
      _ "$1" "$2" & while [ ! -e "$1" ]; do sleep 0.01; done' \
      _ "$ready" "$escape_sentinel" || ec=$?
  assert_exit_code "MR35a: fork-active descendant cleanup preserves foreground status" "$ec" 0
  assert_file_not_exists "MR35b: cleanup deadline escalates during continuous fork events" \
    "$escape_sentinel"

  signal_marker="$repo/new-session-stopped"; descendant="$repo/new-session-pid"
  ec=0
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -c 'setsid bash -c '\''trap ": > \"$1\"; exit 0" TERM; \
      while read -r key host_pid rest; do \
        [ "$key" != NSpid: ] || { printf "%s\n" "$host_pid" > "$2"; break; }; \
      done < /proc/thread-self/status; while :; do sleep 1; done'\'' \
      _ "$1" "$2" >/dev/null 2>&1 & while [ ! -e "$2" ]; do sleep 0.01; done' \
      _ "$signal_marker" "$descendant" || ec=$?
  escaped_pid=$(cat "$descendant")
  assert_exit_code "MR36: foreground status survives new-session cleanup" "$ec" 0
  assert_file_exists "MR37: detached new-session descendant is terminated" "$signal_marker"
  if [ -r "/proc/$escaped_pid/stat" ] && [ "$(awk '{print $3}' "/proc/$escaped_pid/stat")" != Z ]; then
    assert_equals "MR38: detached descendant no longer runs" alive stopped
  else
    assert_equals "MR38: detached descendant no longer runs" stopped stopped
  fi

  descendant="$repo/fast-escape-pid"
  escape_ready="$repo/fast-escape-ready"
  escape_sentinel="$repo/fast-escape-survived"
  ec=0
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -c 'sleep 0.2; setsid bash -c '\''
      unset SAAS_LEASE_GUARDIAN_TOKEN
      while read -r key host_pid rest; do
        [ "$key" != NSpid: ] || { printf "%s\n" "$host_pid" > "$1"; break; }
      done < /proc/thread-self/status
      : > "$2"; sleep 2; : > "$3"
    '\'' _ "$1" "$2" "$3" >/dev/null 2>&1 &
    while [ ! -e "$2" ]; do sleep 0.01; done' \
      _ "$descendant" "$escape_ready" "$escape_sentinel" || ec=$?
  escaped_pid=$(cat "$descendant")
  assert_exit_code "MR38a: fast detached child preserves foreground status" "$ec" 0
  if [ -r "/proc/$escaped_pid/stat" ] && [ "$(awk '{print $3}' "/proc/$escaped_pid/stat")" != Z ]; then
    assert_equals "MR38b: tokenless reparented session cannot outlive hold" alive stopped
  else
    assert_equals "MR38b: tokenless reparented session cannot outlive hold" stopped stopped
  fi
  sleep 2
  assert_file_not_exists "MR38c: contained escape cannot write its delayed sentinel" \
    "$escape_sentinel"

  descendant="$repo/guardian-kill-member-pid"
  marker="$repo/guardian-kill-foreground-pid"
  kill_ready="$repo/guardian-kill-ready"
  kill_sentinel="$repo/guardian-kill-survived"
  escape_helper="$repo/guardian-kill-escaped.sh"
  detach_helper="$repo/guardian-kill-detach.sh"
  cat > "$escape_helper" <<'SH'
#!/usr/bin/env bash
unset SAAS_LEASE_GUARDIAN_TOKEN
while read -r key host_pid rest; do
  [ "$key" != NSpid: ] || { printf '%s\n' "$host_pid" > "$1"; break; }
done < /proc/thread-self/status
: > "$2"
deadline=$((SECONDS + 2)); while [ "$SECONDS" -lt "$deadline" ]; do :; done
: > "$3"; while :; do :; done
SH
  cat > "$detach_helper" <<'SH'
#!/usr/bin/env bash
setsid bash "$1" "$2" "$3" "$4" >/dev/null 2>&1 &
SH
  chmod +x "$escape_helper" "$detach_helper"
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -c '
      while read -r key host_pid rest; do
        [ "$key" != NSpid: ] || { printf "%s\n" "$host_pid" > "$6"; break; }
      done < /proc/thread-self/status
      bash "$1" "$2" "$3" "$4" "$5"
      while [ ! -e "$4" ]; do :; done
      while :; do :; done
    ' _ "$detach_helper" "$escape_helper" "$descendant" "$kill_ready" \
      "$kill_sentinel" "$marker" >/dev/null 2>&1 &
  holder=$!
  for _ in {1..200}; do [ ! -e "$kill_ready" ] || break; sleep 0.01; done
  assert_file_exists "MR38d: SIGKILL fixture enters the traced process tree" "$kill_ready"
  outer_pid=""; read -r outer_pid _ < "/proc/$holder/task/$holder/children" \
    || [ -n "$outer_pid" ]
  root_pid=""; read -r root_pid _ < "/proc/$outer_pid/task/$outer_pid/children" \
    || [ -n "$root_pid" ]
  escaped_pid=$(cat "$descendant")
  foreground_pid=$(cat "$marker")
  outer_start=$(awk '{print $22}' "/proc/$outer_pid/stat")
  root_start=$(awk '{print $22}' "/proc/$root_pid/stat")
  member_start=$(awk '{print $22}' "/proc/$escaped_pid/stat")
  foreground_start=$(awk '{print $22}' "/proc/$foreground_pid/stat")
  out=$(tr '\0' ' ' < "/proc/$outer_pid/cmdline")
  assert_output_contains "MR38e: guardian child is the ptrace boundary" "$out" \
    "trace-containment.py"
  kill -KILL "$holder"
  ec=0; wait "$holder" 2>/dev/null || ec=$?
  assert_exit_code "MR38f: SIGKILL terminates the guardian" "$ec" 137
  for _ in {1..200}; do
    outer_state=$(awk '{print $3 ":" $22}' "/proc/$outer_pid/stat" 2>/dev/null || true)
    root_state=$(awk '{print $3 ":" $22}' "/proc/$root_pid/stat" 2>/dev/null || true)
    member_state=$(awk '{print $3 ":" $22}' "/proc/$escaped_pid/stat" 2>/dev/null || true)
    foreground_state=$(awk '{print $3 ":" $22}' "/proc/$foreground_pid/stat" 2>/dev/null || true)
    { [ -z "$outer_state" ] || [ "$outer_state" = "Z:$outer_start" ] \
      || [ "${outer_state#*:}" != "$outer_start" ]; } \
      && { [ -z "$root_state" ] || [ "$root_state" = "Z:$root_start" ] \
      || [ "${root_state#*:}" != "$root_start" ]; } \
      && { [ -z "$member_state" ] || [ "$member_state" = "Z:$member_start" ] \
      || [ "${member_state#*:}" != "$member_start" ]; } \
      && { [ -z "$foreground_state" ] || [ "$foreground_state" = "Z:$foreground_start" ] \
      || [ "${foreground_state#*:}" != "$foreground_start" ]; } && break
    sleep 0.01
  done
  if [ -n "$outer_state" ] && [ "$outer_state" != "Z:$outer_start" ] \
    && [ "${outer_state#*:}" = "$outer_start" ]; then
    assert_equals "MR38g: guardian SIGKILL tears down the ptrace supervisor" alive stopped
  else
    assert_equals "MR38g: guardian SIGKILL tears down the ptrace supervisor" stopped stopped
  fi
  if { [ -n "$root_state" ] && [ "$root_state" != "Z:$root_start" ] \
      && [ "${root_state#*:}" = "$root_start" ]; } \
    || { [ -n "$member_state" ] && [ "$member_state" != "Z:$member_start" ] \
      && [ "${member_state#*:}" = "$member_start" ]; } \
    || { [ -n "$foreground_state" ] && [ "$foreground_state" != "Z:$foreground_start" ] \
      && [ "${foreground_state#*:}" = "$foreground_start" ]; }; then
    assert_equals "MR38h: guardian SIGKILL tears down every traced member" alive stopped
  else
    assert_equals "MR38h: guardian SIGKILL tears down every traced member" stopped stopped
  fi
  sleep 2
  assert_file_not_exists "MR38i: guardian SIGKILL cannot leave a delayed sentinel" \
    "$kill_sentinel"

  race_bin="$repo/pdeath-race-bin"; mkdir -p "$race_bin"
  race_count="$repo/pdeath-race-count"
  race_entered="$repo/pdeath-race-entered"
  race_release="$repo/pdeath-race-release"
  race_ready="$repo/pdeath-race-command-ready"
  race_sentinel="$repo/pdeath-race-survived"
  real_setpriv=$(command -v setpriv)
  cat > "$race_bin/setpriv" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$SETPRIV_COUNT" ] || read -r count < "$SETPRIV_COUNT"
count=$((count + 1)); printf '%s\n' "$count" > "$SETPRIV_COUNT"
if [ "$count" -eq 1 ]; then exec "$REAL_SETPRIV" "$@"; fi
: > "$SETPRIV_ENTERED"
while [ ! -e "$SETPRIV_RELEASE" ]; do sleep 0.01; done
exec "$REAL_SETPRIV" "$@"
SH
  chmod +x "$race_bin/setpriv"
  PATH="$race_bin:$PATH" REAL_SETPRIV="$real_setpriv" SETPRIV_COUNT="$race_count" \
    SETPRIV_ENTERED="$race_entered" SETPRIV_RELEASE="$race_release" \
    bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
      --interval-seconds 1 --max-seconds 10 -- \
      bash -c ': > "$1"; sleep 1; : > "$2"; while :; do :; done' \
        _ "$race_ready" "$race_sentinel" >/dev/null 2>&1 &
  holder=$!
  for _ in {1..200}; do [ ! -e "$race_entered" ] || break; sleep 0.01; done
  assert_file_exists "MR38j: parent-death setup race reaches the pre-prctl window" \
    "$race_entered"
  race_child=""; read -r race_child _ < "/proc/$holder/task/$holder/children" \
    || [ -n "$race_child" ]
  race_start=$(awk '{print $22}' "/proc/$race_child/stat")
  kill -KILL "$holder"
  ec=0; wait "$holder" 2>/dev/null || ec=$?
  assert_exit_code "MR38k: race fixture SIGKILL terminates the guardian" "$ec" 137
  member_state=$(awk '{print $3 ":" $22}' "/proc/$race_child/stat" 2>/dev/null || true)
  if [ -n "$member_state" ] && [ "$member_state" != "Z:$race_start" ] \
    && [ "${member_state#*:}" = "$race_start" ]; then
    assert_equals "MR38l: fixture holds the orphan before pdeath setup" alive alive
  else
    assert_equals "MR38l: fixture holds the orphan before pdeath setup" stopped alive
  fi
  : > "$race_release"
  for _ in {1..200}; do
    member_state=$(awk '{print $3 ":" $22}' "/proc/$race_child/stat" 2>/dev/null || true)
    [ -z "$member_state" ] || [ "$member_state" = "Z:$race_start" ] \
      || [ "${member_state#*:}" != "$race_start" ] && break
    sleep 0.01
  done
  if [ -n "$member_state" ] && [ "$member_state" != "Z:$race_start" ] \
    && [ "${member_state#*:}" = "$race_start" ]; then
    assert_equals "MR38m: post-prctl PPID check rejects the orphan" alive stopped
  else
    assert_equals "MR38m: post-prctl PPID check rejects the orphan" stopped stopped
  fi
  assert_file_not_exists "MR38n: pre-prctl orphan cannot launch the held command" "$race_ready"
  sleep 1
  assert_file_not_exists "MR38o: pre-prctl orphan cannot write a delayed sentinel" \
    "$race_sentinel"

  signal_marker="$repo/lock-holder-stopped"; ready="$repo/lock-holder-ready"
  elapsed=$SECONDS; ec=0
  bash "$guardian" hold --lease-at "$lease_dir" cancel:test "$owner" \
    --interval-seconds 1 --max-seconds 10 -- \
    bash -c 'exec 8<"$1"; flock -x 8; trap '\''printf stopped > "$2"; exit 0'\'' TERM; \
      : > "$3"; while :; do sleep 1; done' _ "$lease_dir" "$signal_marker" "$ready" \
      >/dev/null 2>&1 || ec=$?
  elapsed=$((SECONDS - elapsed))
  assert_exit_code "MR39: bounded heartbeat lock wait fails the holder" "$ec" 1
  assert_file_exists "MR40: heartbeat lock timeout terminates the child" "$signal_marker"
  if [ "$elapsed" -lt 10 ]; then
    assert_equals "MR41: lock timeout cannot bypass maximum lifetime" bounded bounded
  else
    assert_equals "MR41: lock timeout cannot bypass maximum lifetime" "$elapsed" bounded
  fi
  bash "$single" --release cancel:test --state-dir "$lease_dir" --owner-file "$owner" >/dev/null
  rm -rf "$repo"
}

test_maintain_runtime
