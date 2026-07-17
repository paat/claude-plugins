# Workflow-level lifecycle/state safety regressions.
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "workflow-lifecycle.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_lifecycle_safety() {
  echo -e "\n${CYAN}Suite WL: workflow lifecycle safety${NC}"
  local goal maintain maintain_protocol maintain_loop maintain_loop_protocol maintain_proof_contract maintain_loop_entry maintain_delivery maintain_escalation mutation_ownership design_review startup improve lessons design first second count guardian lease workdir owner owner2 ec before after holder child_ready child_stopped grandchild_file grandchild
  goal="$PLUGIN_ROOT/references/workflows/goal-deliver.md"
  maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  maintain_protocol="$PLUGIN_ROOT/references/workflows/maintain-protocol.md"
  maintain_loop="$PLUGIN_ROOT/commands/maintain-loop.md"
  maintain_loop_protocol="$PLUGIN_ROOT/references/workflows/maintain-loop-protocol.md"
  maintain_proof_contract="$PLUGIN_ROOT/references/workflows/maintain-proof-contract.md"
  maintain_loop_entry="$PLUGIN_ROOT/commands/maintain-loop.md"
  maintain_delivery="$PLUGIN_ROOT/scripts/maintain-delivery.sh"
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
    'release `$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`'

  assert_file_exists "WL5a: maintain detailed protocol exists" "$maintain_protocol"
  assert_file_exists "WL5b: maintain-loop detailed protocol exists" "$maintain_loop_protocol"
  assert_file_contains "WL5c: maintain router loads details on demand" "$maintain" \
    'Never read that file'
  assert_file_not_contains "WL5d: thin coordinator never loads the retired loop protocol" \
    "$maintain_loop" 'maintain-loop-protocol.md'
  assert_before "WL6: maintain protocol orders pass lease before worktree mutation" "$maintain_protocol" \
    '## Whole-Pass Lease' '## Workspace — Dedicated Worktree'
  assert_before "WL6a: maintain router requests pass lease before worktree setup" "$maintain" \
    '1. `Whole-Pass Lease`' '2. `Workspace — Dedicated Worktree`'
  assert_before "WL6b: maintain-loop probes before fresh dispatch" "$maintain_loop" \
    'workflow-probe.sh maintain' \
    'launch exactly one fresh isolated subagent'
  count=$(wc -l < "$maintain_loop" | tr -d ' ')
  if [ "$count" -le 150 ]; then
    assert_equals "WL6c: maintain-loop coordinator stays within the prompt budget" yes yes
  else
    assert_equals "WL6c: maintain-loop coordinator stays within the prompt budget" no yes
  fi
  assert_file_contains "WL6d: maintain repairs owned test targets before blocking" \
    "$maintain_protocol" 'use only the project'"'"'s documented'
  assert_file_contains "WL6e: issue-local blockers keep the queue moving" \
    "$maintain_protocol" 'Continue the remaining eligible'
  assert_file_contains "WL6f: pre-PR issue-local block removes its active claim" \
    "$maintain_protocol" 'If no open linked PR exists, remove `maintain:claimed`'
  assert_file_contains "WL6f1: resumable issue-local block preserves its claim" \
    "$maintain_protocol" 'keep the PR and `maintain:claimed` intact'
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
  assert_file_contains "WL7a: maintain uses compatibility delivery leases" "$maintain_protocol" \
    '--mode maintain'
  assert_file_contains "WL7b: maintain-loop uses compatibility delivery leases" "$maintain_loop_protocol" \
    '--mode maintain-loop'
  assert_file_contains "WL7b1: no worktrees except maintain hard rule" "$maintain_loop_protocol" \
    'No linked worktrees by default'
  assert_file_contains "WL7b2: maintain-loop binds .worktrees/maintain" "$maintain_loop_protocol" \
    'WT="$REPO_ROOT/.worktrees/maintain"'
  assert_file_not_contains "WL7b3: no maintain-loop worktree assignment" "$maintain_loop_protocol" \
    'WT="$REPO_ROOT/.worktrees/maintain-loop"'
  assert_file_contains "WL7b4: improve forbids worktrees" "$improve" \
    'create a git worktree for `/improve`'
  assert_file_contains "WL7c: maintain-loop lease is common-worktree scoped" "$maintain_loop_protocol" \
    'LEASE_STATE="$GIT_COMMON/'
  assert_file_contains "WL7d: maintain bounds foreground lease lifetime" "$maintain_protocol" \
    '--max-seconds 14400'
  assert_file_contains "WL7e: maintain-loop bounds foreground lease lifetime" "$maintain_loop_protocol" \
    '--max-seconds 14400'
  assert_file_contains "WL7f: maintain long commands use foreground lease-set hold" "$maintain_protocol" \
    'maintain-leases.sh" hold'
  assert_file_contains "WL7f1: maintain-loop accepts a global Playwright CLI" "$maintain_loop_protocol" \
    'command -v playwright'
  assert_file_contains "WL7f2: internally leased attempts are not double-wrapped" "$maintain_loop_protocol" \
    'Do not wrap `maintain-attempt.sh reset`, `base-check`, or'
  assert_file_contains "WL7f3: pre-worktree pending stays read-only on the primary" \
    "$maintain_loop_protocol" 'maintain-delivery.sh pending --repo-root "$REPO_ROOT"'
  count=$(grep -cF -- '--repo-root "$WT"' "$maintain_proof_contract" || true)
  assert_equals "WL7f4: delivery proof calls use the leased worktree" "$count" 4
  assert_file_not_contains "WL7f5: delivery proof never targets the primary checkout" \
    "$maintain_proof_contract" '--repo-root "$REPO_ROOT"'
  assert_before "WL7f6: new receipt begins only after the green base gate" "$maintain_loop_protocol" \
    'maintain-attempt.sh" base-check' \
    'maintain-delivery.sh begin --repo-root "$WT"'
  assert_before "WL7f7: new receipt begins before branch and writer work" "$maintain_loop_protocol" \
    'maintain-delivery.sh begin --repo-root "$WT"' \
    'ATTEMPT_ARGS=(deliver'
  assert_file_contains "WL7f8: pending QA resumes at the receipt head" "$maintain_loop_protocol" \
    'normal or rollback QA/tribunal uses that role'
  assert_file_contains "WL7f9: pending live work resumes at the merge head" "$maintain_loop_protocol" \
    'post-merge live/release/close work uses that role'
  assert_file_contains "WL7f10: unbound claimed recovery fails closed" "$maintain_loop_protocol" \
    'A `claimed` receipt or any pending state without its'
  assert_before "WL7f11: normal merge reset precedes live proof" "$maintain_loop_protocol" \
    'Read `MERGE_SHA` only from the updated receipt' \
    'Select a concrete deploy run for `MERGE_SHA`'
  assert_file_contains "WL7f12: rollback merge resets before live proof" "$maintain_loop_protocol" \
    'Read `ROLLBACK_MERGE_SHA` only from'
  assert_file_contains "WL7f13: begin requires the classified issue scope" "$maintain_delivery" \
    '--delivery-id ID --merge-budget N --scope-json FILE'
  assert_file_contains "WL7f14: workflow passes the retained scope to begin" "$maintain_loop_protocol" \
    '--scope-json "$ISSUE_SCOPE_JSON"'
  assert_before "WL7f15: issue scope capture precedes begin" "$maintain_loop_protocol" \
    'gh issue view "$N" --json' \
    'maintain-delivery.sh begin --repo-root "$WT"'
  assert_file_contains "WL7f16: active loop lease controls receipt resume" "$maintain_loop_protocol" \
    'exclusive `maintain-loop` lease bound to `$WT` is controller'
  assert_file_contains "WL7f17: receipt origin remains run-ledger provenance" "$maintain_loop_protocol" \
    'origin ID remains provenance and the run-ledger identity'
  assert_before "WL7g: canonical base gate precedes writer dispatch" "$maintain_loop_protocol" \
    'maintain-attempt.sh" base-check' \
    'ATTEMPT_ARGS=(deliver'
  assert_file_contains "WL7h: maintain keeps auth receipts in one shell" "$maintain_protocol" \
    'one continuous host'
  assert_file_contains "WL7i: maintain-loop keeps auth through full commit gate" "$maintain_loop_protocol" \
    'full commit gate'
  assert_file_contains "WL7j: maintain-loop rejects cross-shell receipt reuse" "$maintain_loop_protocol" \
    'reset and retry from a new'
  assert_file_exists "WL7j0: model-free escalation authority exists" "$maintain_escalation"
  assert_file_contains "WL7j1: protocol delegates cleanup proof to helper" "$maintain_loop_protocol" \
    'maintain-escalation.sh" cleanup'
  assert_file_contains "WL7j2: protocol requires live restart authorization" "$maintain_loop_protocol" \
    'authorize-restart'
  assert_file_contains "WL7j3: restart authority enforces canonical false polarity" "$maintain_escalation" \
    'open_pr:false,remote_branch:false,head_at_base:true,worktree_clean:true'
  assert_file_contains "WL7j4: mutation ownership matches terminal marker retirement" \
    "$mutation_ownership" 'retires the active marker on every terminal'
  assert_file_not_contains "WL7j5: rejection never preserves a stale active marker" \
    "$mutation_ownership" 'leave the active marker in place'
  assert_file_contains "WL7k: maintain-loop mints one run per invocation" "$maintain_loop_protocol" \
    'Mint one `RUN_ID` per command invocation'
  assert_file_contains "WL7l: foreground holder failure terminates the pass" "$maintain_loop_protocol" \
    'A nonzero foreground `hold` result is a terminal pass failure'
  assert_file_contains "WL7m: maintain-loop emits one terminal pass outcome" "$maintain_loop_protocol" \
    'append exactly one supervisor terminal `pass-outcome`'
  assert_file_contains "WL7n: terminal pass cannot restart in the same invocation" "$maintain_loop_protocol" \
    'never continue the queue'
  assert_file_contains "WL7o: worker success is not supervisor delivery success" "$maintain_loop_protocol" \
    'worker success cannot claim delivery success'
  assert_file_contains "WL7p: supervisor and worker event phases stay distinct" "$maintain_loop_protocol" \
    'never writes an `implementation` event'
  assert_file_contains "WL7q: terminal status observes cleanup first" "$maintain_loop_protocol" \
    'run the one cleanup before choosing'
  assert_file_contains "WL7r: event failure cannot bypass cleanup" "$maintain_loop_protocol" \
    'Cleanup is unconditional even when the later event'
  assert_file_contains "WL7s: maintain-loop entry forwards read-only dry-run" "$maintain_loop_entry" \
    '--dry-run'
  assert_before "WL7t: maintain-loop dry-run terminates before worker preflight" "$maintain_loop_protocol" \
    '`--dry-run` takes a terminal read-only branch here' \
    'health-preflight.sh --require-gh --require-codex'
  assert_file_contains "WL7u: maintain-loop dry-run cannot enter later sections" "$maintain_loop_protocol" \
    'execute any later section'
  assert_before "WL7v: maintain resolves queue roots before dry-run branch" "$maintain_protocol" \
    'MAINTAIN_BLOCKED_FILE="$GIT_COMMON/' 'Under `--dry-run`, acquire no lease'
  assert_file_contains "WL7w: pass event uses pass-outcome phase" "$maintain_loop_protocol" \
    '--phase pass-outcome'
  assert_file_contains "WL7x: tribunal rounds are persisted and bounded" "$maintain_loop_protocol" \
    'Never invoke round 6'
  assert_before "WL7y: forward merge budget is consumed before deploy" "$maintain_loop_protocol" \
    'Call `record-merge --role normal`' 'Select a concrete deploy run'
  assert_before "WL7z: issue close intent waits for release proof" "$maintain_loop_protocol" \
    'Then call `record-release` with only' \
    'then call `close-intent` with no snapshots'
  assert_file_contains "WL7z0: success evidence requires closed issue" "$maintain_loop_protocol" \
    '`issue:closed`'
  assert_file_contains "WL7za: PR remains non-closing before deploy" "$maintain_loop_protocol" \
    'normal PR contains `Refs #N`'
  assert_file_not_contains "WL7zb: PR does not auto-close before deploy" "$maintain_loop_protocol" \
    '`Closes #N`'
  assert_file_contains "WL7zc: non-closing PR still receives closure audit" "$maintain_loop_protocol" \
    'issue-closure-audit.sh --audit-issue'
  assert_file_contains "WL7zd: pre-close gate resumes pending close receipts" "$maintain_loop_protocol" \
    'including `close_intent` or `closed_observed`'
  assert_before "WL7ze: exact merged PR is re-read before pre-close audit" "$maintain_loop_protocol" \
    'freshly fetches the exact merged PR' \
    'the prospective audit itself'
  assert_before "WL7zf: prospective audit precedes close intent" "$maintain_loop_protocol" \
    'the prospective audit itself' \
    'binds the unchanged issue revision'
  assert_before "WL7zg: verified claim removal precedes prospective audit" "$maintain_loop_protocol" \
    'absence of `maintain:claimed`' \
    'the prospective audit itself'
  assert_file_contains "WL7zg1: merge helper pins authorized head" "$maintain_loop_protocol" \
    'gh pr merge --match-head-commit <receipt-head>'
  assert_file_contains "WL7zg2: workflow forbids direct PR merge" "$maintain_loop_protocol" \
    'Never invoke `gh pr merge` directly'
  assert_file_contains "WL7zg3: close intent binds canonical issue revision" "$maintain_loop_protocol" \
    'binds the unchanged issue revision and digest'
  assert_file_contains "WL7zg4: close helper owns issue close" "$maintain_loop_protocol" \
    'That helper alone fetches and compares the'
  assert_file_contains "WL7zg4a: close helper takes no caller snapshot" "$maintain_loop_protocol" \
    'with no snapshot argument'
  assert_file_contains "WL7zg4b: close helper owns post-close verification" "$maintain_loop_protocol" \
    'fetches the full CLOSED'
  assert_file_contains "WL7zg5: rollback proves the exact inverse tree" "$maintain_loop_protocol" \
    'exact expected reverse of the recorded normal merge with no'
  assert_file_contains "WL7zg6: premerge evidence has stable identifiers" "$maintain_proof_contract" \
    'retains the proof digest'
  assert_file_contains "WL7zg6a: proof contract rejects a narrow passed assertion" "$maintain_proof_contract" \
    'A bare success exit or'
  assert_file_contains "WL7zg7: merge receipt enforces count and budget" "$maintain_loop_protocol" \
    'atomically advances the run-owned merge ledger'
  assert_file_contains "WL7zg8: release receipt binds target and live assertions" "$maintain_loop_protocol" \
    'stable target-source code'
  assert_file_contains "WL7zg9: result is helper-rendered from receipt" "$maintain_loop_protocol" \
    '`maintain-delivery.sh render-result` derives the result solely'
  assert_file_contains "WL7zg10: finalize requires exact canonical bytes" "$maintain_loop_protocol" \
    'requires an exact byte match'
  assert_file_contains "WL7zg11: free-form result edits fail" "$maintain_loop_protocol" \
    'omitted, duplicate, reordered, or'
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
  assert_file_contains "WL10: split child is resolved by exact marker" "$maintain_protocol" \
    'resolve_split_child()'
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
