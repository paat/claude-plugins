# Workflow-level lifecycle/state safety regressions.
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "workflow-lifecycle.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_lifecycle_safety() {
  echo -e "\n${CYAN}Suite WL: workflow lifecycle safety${NC}"
  local goal maintain maintain_protocol maintain_loop maintain_receipts maintain_proof_contract maintain_loop_entry maintain_delivery maintain_attempt maintain_escalation mutation_ownership design_review startup improve lessons design first second count guardian lease workdir owner owner2 ec before after holder child_ready child_stopped grandchild_file grandchild
  goal="$PLUGIN_ROOT/references/workflows/goal-deliver.md"
  maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  maintain_protocol="$PLUGIN_ROOT/references/workflows/maintain-protocol.md"
  maintain_loop="$PLUGIN_ROOT/commands/maintain-loop.md"
  maintain_receipts="$PLUGIN_ROOT/references/workflows/goal-deliver-maintain-receipts.md"
  maintain_proof_contract="$PLUGIN_ROOT/references/workflows/maintain-proof-contract.md"
  maintain_loop_entry="$PLUGIN_ROOT/commands/maintain-loop.md"
  maintain_delivery="$PLUGIN_ROOT/scripts/maintain-delivery.sh"
  maintain_attempt="$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  maintain_escalation="$PLUGIN_ROOT/scripts/maintain-escalation.sh"
  mutation_ownership="$PLUGIN_ROOT/references/workflows/mutation-ownership.md"
  design_review="$PLUGIN_ROOT/skills/ux-tester/references/design-review-leg.md"
  startup="$PLUGIN_ROOT/commands/startup.md"
  improve="$PLUGIN_ROOT/references/workflows/improve.md"
  lessons="$PLUGIN_ROOT/commands/lessons-deliver.md"
  design="$PLUGIN_ROOT/docs/design/lessons-deliver.md"

  assert_before() {
    local label="$1" file="$2" earlier="$3" later="$4"
    first=$(grep -nF -- "$earlier" "$file" | head -1 | cut -d: -f1 || true)
    second=$(grep -nF -- "$later" "$file" | head -1 | cut -d: -f1 || true)
    if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
      assert_equals "$label" yes yes
    else
      assert_equals "$label" no yes
    fi
  }

  assert_before "WL1: goal lease precedes every route path" "$goal" \
    '## Step 1.25: Claim the Delivery Scope' \
    '## Step 1.5: Autonomous Light Fast Path'
  assert_file_contains "WL2: goal uses durable lease owner" "$goal" 'GOAL_OWNER_FILE='
  assert_file_contains "WL3: goal blocks contaminated deep retry" "$goal" \
    'never launch a deep worker from'
  assert_file_contains "WL4: goal verifies merge state" "$goal" \
    'query that exact PR before doing anything else'
  assert_file_contains "WL5: goal releases terminal lease" "$goal" \
    'releases `$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`'

  assert_file_exists "WL5a: maintain detailed protocol exists" "$maintain_protocol"
  assert_file_exists "WL5b: embedded maintain receipt adapter exists" "$maintain_receipts"
  assert_file_contains "WL5c: maintain router loads details on demand" "$maintain" \
    'Never read that file'
  assert_file_contains "WL5d: only goal loads the embedded receipt adapter" \
    "$goal" 'goal-deliver-maintain-receipts.md'
  assert_before "WL5e: pending receipt recovery precedes ordinary triage" "$maintain" \
    'If the probe found one pending embedded delivery' \
    'Route each triage-cache miss'
  assert_file_contains "WL5f: pending-receipt dry-run advances no delivery state" \
    "$maintain_receipts" 'Do not acquire a lease, enter `/goal-deliver`, advance the receipt'
  assert_before "WL6: maintain protocol orders pass lease before worktree mutation" "$maintain_protocol" \
    '## Whole-Pass Lease' '## Workspace — Dedicated Worktree'
  assert_before "WL6a: maintain router requests pass lease before worktree setup" "$maintain" \
    '1. `Whole-Pass Lease`' '2. `Workspace — Dedicated Worktree`'
  assert_before "WL6b: maintain-loop probes before fresh dispatch" "$maintain_loop" \
    'workflow-probe.sh maintain' \
    'launch exactly one fresh isolated subagent'
  assert_file_contains "WL6b1: fresh loop child carries root ID and command mechanically" \
    "$maintain" '--lease-run-id "$SAAS_INVOCATION_ID" --invocation-command maintain-loop'
  assert_before "WL6b2: internal command conflicts stop before the probe" "$maintain" \
    'context-binding failure before the probe or mutation' \
    'Run `${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain`'
  count=$(wc -l < "$maintain_loop" | tr -d ' ')
  if [ "$count" -le 150 ]; then
    assert_equals "WL6c: maintain-loop coordinator stays within the prompt budget" yes yes
  else
    assert_equals "WL6c: maintain-loop coordinator stays within the prompt budget" no yes
  fi
  assert_file_contains "WL6d: maintain repairs owned test targets before blocking" \
    "$goal" 'using only documented setup/start commands'
  assert_file_contains "WL6e: issue-local blockers keep the queue moving" \
    "$maintain_protocol" 'Continue the remaining eligible'
  assert_file_contains "WL6f: pre-PR issue-local block records cooldown without claim" \
    "$maintain_protocol" 'no claim required'
  assert_file_contains "WL6f1: resumable issue-local block preserves open PR" \
    "$maintain_protocol" 'keep both intact'
  assert_file_contains "WL6g: issue-local block records terminal state" \
    "$maintain_protocol" 'record the terminal triage/digest state'
  assert_file_contains "WL6h: shared dev evidence proves its served commit" \
    "$design_review" 'served commit is'
  assert_file_contains "WL6i: closed browser transport gets one fresh retry before cooldown" \
    "$design_review" 'second failure as issue-local'
  assert_file_contains "WL6j: UX retry waits for the failed session before isolated dispatch" \
    "$design_review" 'failed agent/session is terminal'
  assert_file_contains "WL6j1: UX retry does not combine partial browser evidence" \
    "$design_review" 'combine partial sessions'
  assert_file_contains "WL6j2: isolated worktrees reuse the documented start command" \
    "$design_review" 'project'"'"'s documented local command'
  assert_file_contains "WL6k: UX retry forbids overlapping repository mutation" \
    "$design_review" 'never overlap'
  assert_file_contains "WL6l: UX baseline cannot reset the caller checkout" \
    "$design_review" 'never switch or'
  assert_file_contains "WL7: maintain lease state is common-worktree scoped" "$maintain_protocol" \
    'MAINTAIN_LEASE_STATE="$GIT_COMMON/'
  assert_file_contains "WL7a: maintain acquire uses only the route-selected mode" "$maintain_protocol" \
    '--mode "$MAINTAIN_CONTROLLER_MODE"'
  assert_file_contains "WL7b: canonical route binds the exact maintain worktree" \
    "$maintain_protocol" 'WT="$REPO_ROOT/.worktrees/maintain"'
  assert_file_contains "WL7c: maintain documents the canonical schema-v3 contract" \
    "$maintain_protocol" 'canonical lease state is schema v3'
  assert_file_contains "WL7c1: public router consumes the helper route object" \
    "$maintain" '\.\[0\]\.controller_route\.kind'
  assert_file_contains "WL7c2: public router fingerprints the exact pending receipt before leasing" \
    "$maintain" 'MAINTAIN_PENDING_FINGERPRINT=$(jq -cS'
  assert_file_contains "WL7c3: legacy recovery selects the canonical worktree" \
    "$maintain_protocol" 'WT="$REPO_ROOT/.worktrees/maintain"'
  assert_file_contains "WL7c4: locked inventory must match the pre-lease fingerprint" \
    "$maintain_protocol" '"$MAINTAIN_PENDING_FINGERPRINT"'
  assert_before "WL7c4a: cleanup trap precedes every post-acquire inventory failure" \
    "$maintain_protocol" 'trap release_maintain_pass EXIT' 'LOCKED_PENDING='
  assert_file_contains "WL7c5: legacy controller cannot begin new receipt work" \
    "$maintain_delivery" 'legacy maintain-loop controller is receipt-recovery-only'
  assert_file_contains "WL7c6: public legacy recovery ends after its one receipt" \
    "$maintain" 'this receipt is the entire pass'
  assert_file_contains "WL7ca: attempt helper delegates controller binding to one validator" \
    "$maintain_attempt" '"$LEASES" controller-binding'
  assert_file_contains "WL7d: maintain bounds foreground lease lifetime" "$maintain_protocol" \
    '--max-seconds 14400'
  assert_file_contains "WL7f: maintain long commands use foreground lease-set hold" "$maintain_protocol" \
    'maintain-leases.sh" hold'
  assert_file_contains "WL7f2: embedded delivery uses the inherited lease" "$maintain_receipts" \
    'Never acquire or release a second goal lease'
  assert_file_contains "WL7f3: pre-worktree pending stays read-only on the primary" \
    "$maintain_receipts" 'maintain-delivery.sh` `pending`'
  count=$(grep -cF -- '--repo-root "$WT"' "$maintain_proof_contract" || true)
  assert_equals "WL7f4: delivery proof calls use the leased worktree" "$count" 4
  assert_file_not_contains "WL7f5: delivery proof never targets the primary checkout" \
    "$maintain_proof_contract" '--repo-root "$REPO_ROOT"'
  assert_before "WL7f6: new receipt begins only after the green base gate" "$maintain_receipts" \
    'Only after the base gate is green' \
    'maintain-delivery.sh begin'
  assert_before "WL7f7: new receipt begins before writer work" "$maintain_receipts" \
    'maintain-delivery.sh begin' \
    'maintain-attempt.sh deliver'
  assert_file_contains "WL7f8: pending delivery resumes at its next receipt transition" \
    "$maintain_receipts" 'resume at the next helper-owned transition'
  assert_file_contains "WL7f9: post-merge recovery retains durable release state" \
    "$maintain_receipts" 'crash after claim, PR creation, merge, release, or close'
  assert_file_contains "WL7f10: unbound claimed recovery fails closed" "$maintain_receipts" \
    'pending state without its issue, claim, bound worktree'
  assert_before "WL7f11: normal merge reset precedes live proof" "$maintain_receipts" \
    'Read `MERGE_SHA` only from the updated receipt' \
    'Run the common deploy/live verification'
  assert_file_contains "WL7f12: rollback merge resets before live proof" "$maintain_receipts" \
    'Reset the worktree to the receipt'"'"'s rollback merge SHA before rollback live proof'
  assert_file_contains "WL7f13: begin requires the classified issue scope" "$maintain_delivery" \
    '--delivery-id ID --merge-budget N --scope-json FILE'
  assert_file_contains "WL7f14: workflow passes the retained scope to begin" "$maintain_receipts" \
    'exact `--scope-json`'
  assert_before "WL7f15: issue scope capture precedes begin" "$maintain_receipts" \
    'capture the complete classified issue scope' \
    'maintain-delivery.sh begin'
  assert_file_contains "WL7f16: route-selected whole-pass lease controls receipt resume" "$maintain_receipts" \
    'whole-pass lease selected by that route'
  assert_file_contains "WL7f17: receipt origin remains run-ledger provenance" "$maintain_receipts" \
    '`origin_run_id` remains provenance and the run-ledger identity'
  assert_file_contains "WL7f18: adapter binds lease validation to the current controller" \
    "$maintain_receipts" 'CONTROLLER_RUN_ID="$SAAS_INVOCATION_ID"'
  assert_file_contains "WL7f18a: goal heartbeat binds the inherited lease to its current root" \
    "$goal" '--run-id "$SAAS_INVOCATION_ID"'
  assert_file_contains "WL7f18b: delivery mutations require an explicit controller" \
    "$maintain_delivery" '--lease-state FILE --controller-run-id CONTROLLER'
  assert_file_contains "WL7f18c: adapter reuses one controller argument tuple" \
    "$maintain_receipts" 'DELIVERY_CONTROLLER_ARGS=('
  assert_file_contains "WL7f19: adapter never overwrites a resumed receipt origin" \
    "$maintain_receipts" 'it never rewrites that origin'
  assert_file_contains "WL7f20: reset passes the current controller explicitly" \
    "$maintain_receipts" '--controller-run-id "$CONTROLLER_RUN_ID"'
  assert_file_contains "WL7f21: writer dispatch passes a fresh child explicitly" \
    "$maintain_receipts" '--child-run-id "$CHILD_RUN_ID"'
  assert_file_contains "WL7f22: writer dispatch preserves the finite invocation command" \
    "$maintain_receipts" '--invocation-command "$INVOCATION_COMMAND"'
  assert_file_contains "WL7f23: escalation constructs one origin/controller argument bundle" \
    "$maintain_receipts" 'ESCALATION_ARGS=('
  assert_before "WL7g: canonical base gate precedes writer dispatch" "$maintain_receipts" \
    'maintain-attempt.sh" base-check' \
    'maintain-attempt.sh deliver'
  assert_file_contains "WL7h: maintain keeps auth receipts in one shell" "$maintain_protocol" \
    'one continuous host'
  assert_file_contains "WL7i: embedded adapter keeps auth in one host shell" "$maintain_receipts" \
    'one continuous host shell'
  assert_file_contains "WL7j: embedded adapter rejects cross-shell transient reuse" "$maintain_receipts" \
    'shell loss invalidates transient guard/trust evidence'
  assert_file_exists "WL7j0: model-free escalation authority exists" "$maintain_escalation"
  assert_file_contains "WL7j1: adapter delegates cleanup proof to helper" "$maintain_receipts" \
    'maintain-escalation.sh" cleanup'
  assert_file_contains "WL7j2: adapter requires live restart authorization" "$maintain_receipts" \
    'authorize-restart'
  assert_file_contains "WL7j3: restart authority enforces canonical false polarity" "$maintain_escalation" \
    'open_pr:false,remote_branch:false,head_at_base:true,worktree_clean:true'
  assert_file_contains "WL7j4: mutation ownership matches terminal marker retirement" \
    "$mutation_ownership" 'retires the active marker on every terminal'
  assert_file_not_contains "WL7j5: rejection never preserves a stale active marker" \
    "$mutation_ownership" 'leave the active marker in place'
  assert_file_contains "WL7s: maintain-loop entry forwards read-only dry-run" "$maintain_loop_entry" \
    '--dry-run'
  assert_before "WL7v: maintain resolves queue roots before dry-run branch" "$maintain_protocol" \
    'MAINTAIN_BLOCKED_FILE="$GIT_COMMON/' 'Under `--dry-run`, acquire no lease'
  assert_file_contains "WL7x: tribunal rounds are persisted and bounded" "$goal" \
    'Round 5'
  assert_before "WL7y: forward merge is recorded before deploy" "$maintain_receipts" \
    'Call `record-merge --role normal`' 'Run the common deploy/live verification'
  assert_before "WL7z: issue close intent waits for release proof" "$maintain_receipts" \
    'call `record-release`' 'call `close-intent`'
  assert_file_contains "WL7z0: success evidence requires helper-observed close" "$maintain_receipts" \
    'Success requires the helper-observed close'
  assert_file_contains "WL7za: PR remains non-closing before deploy" "$maintain_receipts" \
    'uses `Refs #N`'
  assert_file_not_contains "WL7zb: PR does not auto-close before deploy" "$maintain_receipts" \
    '`Closes #N`'
  assert_file_contains "WL7zc: non-closing PR still receives closure audit" "$maintain_receipts" \
    'prospective closure audit'
  assert_file_contains "WL7zd: pre-close gate resumes pending close receipts" "$maintain_receipts" \
    'crash between close and verification'
  assert_file_contains "WL7ze: close intent freshly reads the merged PR and issue" \
    "$maintain_receipts" 'freshly re-fetches the exact merged PR and open issue'
  assert_before "WL7zg: verified claim removal precedes close intent" "$maintain_receipts" \
    'Remove `maintain:claimed`' 'call `close-intent`'
  assert_file_contains "WL7zg1: merge helper pins authorized head" "$maintain_receipts" \
    'gh pr merge --match-head-commit <receipt-head>'
  assert_file_contains "WL7zg2: workflow forbids direct PR merge" "$maintain_receipts" \
    'never invokes `gh pr merge` directly'
  assert_file_contains "WL7zg3: close intent binds canonical issue revision" "$maintain_receipts" \
    'complete open revision'
  assert_file_contains "WL7zg4: close helper owns issue close" "$maintain_receipts" \
    'That helper alone fetches and compares the complete open revision'
  assert_file_contains "WL7zg4a: close helper takes no caller snapshot" "$maintain_receipts" \
    'no snapshot argument'
  assert_file_contains "WL7zg4b: close helper owns post-close verification" "$maintain_receipts" \
    'verifies the complete closed revision'
  assert_file_contains "WL7zg5: rollback proves the exact inverse tree" "$maintain_receipts" \
    'exact expected inverse tree of the recorded normal merge'
  assert_file_contains "WL7zg6: premerge evidence has stable identifiers" "$maintain_proof_contract" \
    'retains the proof digest'
  assert_file_contains "WL7zg6a: proof contract rejects a narrow passed assertion" "$maintain_proof_contract" \
    'A bare success exit or'
  assert_file_contains "WL7zg7: merge receipt rejects caller accounting" "$maintain_receipts" \
    'with no caller counter or snapshot'
  assert_file_contains "WL7zg8: release receipt binds target and live assertions" "$maintain_receipts" \
    'stable target-source code'
  assert_file_contains "WL7zg9: result is helper-rendered from receipt" "$maintain_receipts" \
    'Call `maintain-delivery.sh render-result`'
  assert_file_contains "WL7zg10: finalize requires exact canonical bytes" "$maintain_receipts" \
    'pass those exact bytes to `finalize`'
  assert_file_contains "WL7zg11: free-form result edits fail" "$maintain_receipts" \
    'omitted, duplicate, reordered, free-form, or contradictory facts'
  assert_file_contains "WL7zg12: executable rejects contradictory result facts" "$maintain_delivery" \
    'result source omits or contradicts canonical receipt facts'
  assert_file_contains "WL7zh: close intent requires an exact open issue" "$maintain_delivery" \
    'close intent requires a valid open issue'
  assert_before "WL7zi: helper verifies claim removal before durable close intent" "$maintain_delivery" \
    'claim label must be removed before close intent' \
    '.state = "close_intent"'
  assert_before "WL7zj: helper validates exact audit before durable close intent" "$maintain_delivery" \
    'fresh close audit failed' \
    '.state = "close_intent"'
  assert_file_contains "WL7zk: helper persists ready-to-close receipt" "$maintain_delivery" \
    'status:"ready_to_close"'
  assert_file_contains "WL7zl: closed resume requires prior close intent" "$maintain_delivery" \
    'cannot observe issue close from $TOP_STATE'
  assert_file_contains "WL7zm: reconciliation appends issue outcome once" "$maintain_delivery" \
    'agent-events.sh" append --once'
  assert_file_contains "WL8: maintain runner has signal trap cleanup" "$maintain_protocol" \
    '`EXIT INT TERM HUP` trap'
  assert_file_contains "WL9: maintain scheduler uses flock" "$maintain_protocol" \
    'non-blocking `flock`'
  assert_file_contains "WL10: split duplicate pre-check before create" "$maintain_protocol" \
    'find_split_child_by_marker()'
  assert_file_contains "WL10b: post-create uses create number not search" "$maintain_protocol" \
    'Do NOT re-search after create'
  assert_file_contains "WL11: split child id is verified numeric" "$maintain_protocol" \
    'split child id is not numeric'
  assert_file_not_contains "WL12: issue create uses no unsupported JSON flag" "$maintain_protocol" \
    '--json number -q .number'
  assert_file_contains "WL12a: split list failure is captured" "$maintain_protocol" \
    'split_json=$(gh issue list'
  assert_file_contains "WL12b: split view failure is captured" "$maintain_protocol" \
    'child_body=$(gh issue view'

  assert_before "WL13: startup lease precedes idea capture" "$startup" \
    'Before any command that may write project state' '## Step 1: Capture the SaaS Idea'
  count=$(grep -cF -- '--acquire "startup:${PWD}"' "$startup" || true)
  assert_equals "WL14: startup acquires one session identity" "$count" 1
  assert_file_contains "WL15: startup heartbeats stable owner file" "$startup" \
    '--owner-file .startup/leases/.owners/startup.owner'

  assert_before "WL16: improve lease precedes branch mutation" "$improve" \
    '## Claim Work Unit' '## Establish Branch'
  assert_before "WL17: improve lease precedes role mutation" "$improve" \
    '## Claim Work Unit' '## Reset active_role'
  assert_file_contains "WL18: improve snapshots exact state" "$improve" \
    'state.before'
  assert_file_contains "WL19: improve refusal restores original branch" "$improve" \
    'git checkout "$ORIGINAL_BRANCH"'
  assert_file_contains "WL20: improve refusal verifies clean state" "$improve" \
    'test -z "$(git status --porcelain)"'

  assert_file_contains "WL21: lessons records exact attempt base" "$lessons" \
    'ATTEMPT_BASE=$(git rev-parse'
  assert_file_contains "WL22: lessons unstages failed attempt" "$lessons" \
    'git reset --hard "$ATTEMPT_BASE"'
  assert_file_contains "WL23: lessons removes only clean-start untracked files" "$lessons" \
    'git clean -fd'
  assert_file_contains "WL24: lessons reruns tribunal on generated HEAD" "$lessons" \
    '**Final-head tribunal gate.**'
  assert_file_contains "WL25: lessons pins verdict to HEAD" "$lessons" \
    'TRIBUNAL_HEAD=$(git rev-parse HEAD)'
  assert_file_contains "WL26: lessons preserves supervisor commits" "$lessons" \
    'supervisor-commit.sh'
  assert_file_contains "WL27: design documents final-head tribunal" "$design" \
    '**Final-head tribunal gate:**'

  guardian="$PLUGIN_ROOT/scripts/lease-guardian.sh"
  lease="$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_exists "WL28: foreground lease guardian exists" "$guardian"
  workdir=$(mktemp -d)
  owner="$workdir/owners/maintain.owner"
  owner2="$workdir/owners/loop.owner"
  mkdir -p "$workdir/owners"
  bash "$lease" --acquire maintain-delivery:pass --state-dir "$workdir" --owner-file "$owner" \
    --ttl-seconds 14400 >/dev/null
  printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$workdir/maintain-delivery-pass/heartbeat"
  ec=0
  bash "$lease" --acquire maintain-delivery:pass --state-dir "$workdir" \
    --owner-file "$owner2" --ttl-seconds 14400 >/dev/null 2>&1 || ec=$?
  assert_exit_code "WL29: shared TTL prevents cross-workflow lease theft" "$ec" 1
  bash "$lease" --heartbeat maintain-delivery:pass --state-dir "$workdir" \
    --owner-file "$owner" >/dev/null

  bash "$lease" --acquire guardian:worktree --state-dir "$workdir" --owner-file "$owner2" \
    --ttl-seconds 10 >/dev/null
  before=$(stat -c %Y "$workdir/guardian-worktree/heartbeat")
  ec=0
  bash "$guardian" hold --state-dir "$workdir" --interval-seconds 1 --max-seconds 10 \
    --lease maintain-delivery:pass "$owner" --lease guardian:worktree "$owner2" -- \
    bash -c 'sleep 2; exit 17' || ec=$?
  assert_exit_code "WL30: foreground guardian propagates child status" "$ec" 17
  after=$(stat -c %Y "$workdir/guardian-worktree/heartbeat")
  if [ "$after" -gt "$before" ]; then assert_equals "WL31: foreground guardian advances heartbeat" yes yes
  else assert_equals "WL31: foreground guardian advances heartbeat" no yes; fi

  child_ready="$workdir/child-ready"
  child_stopped="$workdir/child-stopped"
  grandchild_file="$workdir/grandchild-pid"
  bash "$guardian" hold --state-dir "$workdir" --interval-seconds 1 --max-seconds 10 \
    --lease maintain-delivery:pass "$owner" --lease guardian:worktree "$owner2" -- \
    bash -c 'trap "printf stopped > \"$1\"; exit 0" TERM; sleep 60 & printf "%s\n" "$!" > "$3"; : > "$2"; wait' \
      _ "$child_stopped" "$child_ready" "$grandchild_file" >"$workdir/hold.log" 2>&1 &
  holder=$!
  for ((count = 0; count < 50; count++)); do
    [ ! -e "$child_ready" ] || break
    sleep 0.1
  done
  bash "$lease" --release maintain-delivery:pass --state-dir "$workdir" --owner-file "$owner" >/dev/null
  ec=0; wait "$holder" || ec=$?
  assert_exit_code "WL32: lease loss fails the foreground wrapper" "$ec" 1
  assert_file_exists "WL33: lease loss terminates the child" "$child_stopped"
  grandchild=$(cat "$grandchild_file")
  if kill -0 "$grandchild" 2>/dev/null; then
    assert_equals "WL33a: lease loss terminates descendants" alive stopped
  else
    assert_equals "WL33a: lease loss terminates descendants" stopped stopped
  fi

  rm -f "$child_ready" "$child_stopped"
  bash "$guardian" hold --state-dir "$workdir" --interval-seconds 1 --max-seconds 10 \
    --lease guardian:worktree "$owner2" -- \
    bash -c 'trap "printf stopped > \"$1\"; exit 0" TERM; : > "$2"; while :; do sleep 1; done' \
      _ "$child_stopped" "$child_ready" >"$workdir/signal.log" 2>&1 &
  holder=$!
  for ((count = 0; count < 50; count++)); do
    [ ! -e "$child_ready" ] || break
    sleep 0.1
  done
  kill -TERM "$holder"
  ec=0; wait "$holder" || ec=$?
  assert_exit_code "WL34: wrapper propagates TERM status" "$ec" 143
  assert_file_exists "WL35: wrapper forwards TERM to child" "$child_stopped"

  bash "$lease" --release guardian:worktree --state-dir "$workdir" --owner-file "$owner2" >/dev/null
  rm -rf "$workdir"
}

test_workflow_lifecycle_safety
