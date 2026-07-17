# /maintain-loop - On-demand delivery protocol

This is the detailed protocol behind `maintain-loop.md`. Read only the named section
the router requests, stopping at the next heading of the same or higher level. Never
load this file wholesale or re-read a section already in context.

## Hard rule — no worktrees except maintain

- **No linked worktrees by default.** The **only** exception is
  `.worktrees/maintain` (shared with `/maintain`).
- **NEVER** create, lease, or deliver from `.worktrees/maintain-loop`,
  `.worktrees/improve-*`, per-issue worktrees, `maintain-preserved-*`, or any other
  path under `.worktrees/`.
- **NEVER** set `core.worktree` on the primary checkout.
- Delivery is **sequential**: one nonterminal receipt, one leased worktree, one
  issue at a time. Reset/recreate `.worktrees/maintain` between attempts; do not
  preserve parallel trees.
- `/improve`, `/tweak`, and other human-invoked one-shots run on the **primary
  checkout** (main repo dir), not in a worktree.

## Ownership invariant

The calling session is the supervisor and the only delivery-state mutation owner.
It owns queue and issue reads, leases, worktrees, branches, `.startup/` state,
deterministic checks, staged-size validation, commits, browser QA, tribunal,
pull requests, merges, deploys, live verification, rollback, result artifacts,
counters, and authoritative events.

Each implementation attempt is a fresh
`scripts/codex-run-role.sh --role tech-founder --profile "$PROFILE"` process. It
may edit only task-required product source and tests in the assigned worktree. It
must not stage or commit, change refs or state, use GitHub, run browser QA, invoke
tribunal, write a result artifact, push, open or edit a PR, merge, deploy, or
roll back. Focused checks are feedback only; the supervisor reruns every
authoritative check. Never launch a `maintain-loop-supervisor` worker. On Codex,
browser work stays flattened in the calling supervisor rather than becoming a
nested browser worker.

Only one source writer may run at a time. Tribunal and browser QA are read-only.
If either finds a source defect, the supervisor launches another fresh
tech-founder attempt, then repeats containment, checks, commit, QA, and tribunal.
The supervisor never patches product source itself.

Use documented helper interfaces. Do not read helper implementations unless a
failed invocation needs a targeted diagnostic range of at most 20 lines.

## Flags and preflight

- `--dry-run`: list the eligible queue and profiles without acquiring leases,
  creating a worktree, or launching a worker.
- `--once`: set `MAX_ISSUES=1`.
- `--issue N`, `--label LABEL`: restrict queue selection.
- `--max-issues N`: delivery cap; unset means no issue-count cap.
- `--max-merges N`: forward-merge cap, default `5`. A single emergency rollback
  may exceed it only to restore production, then the pass stops.
- `--max-run-minutes N`: pass wall-clock cap, default `120`; `0` is unlimited.

`--dry-run` takes a terminal read-only branch here. Resolve the repository and
default branch, require only `gh` and `jq`, build the queue with the issue/label
filters and every shared/legacy blocked ledger described below, and classify each
queued issue with temporary files outside the repository. Read and report any
pending delivery receipt with `maintain-delivery.sh pending`, but do not advance
it. Print issue number, profile, routing reasons, and planned stale-label removal,
delete temporary files, then return. Do not run the Codex smoke, mint IDs, acquire
or replace a lease, create state or prompts, touch a worktree/ref/label, emit an
event, or execute any later section.

Only a normal delivery continues below.

Run `scripts/health-preflight.sh --require-gh --require-codex --check-sync` and
require its `codex:worker-shell` smoke check. Require `jq`, `flock`, both
tribunal-review skills, and either `command -v playwright` or the project's
existing Playwright runner. Do not install dependencies during a pass. Resolve the default branch with the shared
repository mechanism — `default=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/default-branch.sh")` —
and stop if it cannot resolve; do not assume a conventional branch name.

Mint one `RUN_ID` per command invocation. Acquire the shared, legacy, and dedicated
worktree leases as one persisted set before touching `.worktrees/maintain`;
never reconstruct owner identities. An active, malformed, or future-dated lease stops
the pass; only a well-formed expired heartbeat is reclaimable. Never restart setup or
mint another run after a terminal outcome in the same invocation.

```bash
REPO_ROOT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" primary-root \
  --repo-root "$(git rev-parse --show-toplevel)")
GIT_COMMON_RAW=$(git -C "$REPO_ROOT" rev-parse --git-common-dir)
case "$GIT_COMMON_RAW" in /*) GIT_COMMON=$GIT_COMMON_RAW ;; *) GIT_COMMON="$REPO_ROOT/$GIT_COMMON_RAW" ;; esac
GIT_COMMON=$(cd "$GIT_COMMON" && pwd -P)
RUN_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)
BLOCKED_FILE="$GIT_COMMON/saas-startup-team/maintain/blocked.jsonl"
WT="$REPO_ROOT/.worktrees/maintain"
LEASE_STATE="$GIT_COMMON/saas-startup-team/maintain-runtime/$RUN_ID-leases.json"
RUN_STATE="$REPO_ROOT/.startup/maintain-loop/current-run.json"
SETUP_COMPLETE=0
RUN_STATE_ACTIVE=0
cleanup_failed_setup() {
  local args=(cleanup --state-file "$LEASE_STATE" --run-id "$RUN_ID")
  [ "$SETUP_COMPLETE" -eq 0 ] || return 0
  [ "$RUN_STATE_ACTIVE" -eq 0 ] || args+=(--run-state "$RUN_STATE")
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" "${args[@]}" >/dev/null 2>&1 || true
}
trap cleanup_failed_setup EXIT
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" acquire \
  --repo-root "$REPO_ROOT" --mode maintain-loop --run-id "$RUN_ID" \
  --state-file "$LEASE_STATE" --worktree "$WT"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" activate \
  --state-file "$LEASE_STATE" --run-state "$RUN_STATE" --blocked-file "$BLOCKED_FILE"
RUN_STATE_ACTIVE=1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" heartbeat --state-file "$LEASE_STATE" >/dev/null
SETUP_COMPLETE=1
trap - EXIT
```

Heartbeat the persisted lease around every phase. Wrap long operations with `hold`;
it terminates the child tree on lease loss or lifetime expiry and propagates status.
Never background it. Do not wrap `maintain-attempt.sh reset`, `base-check`, or
`deliver` in another `hold`; all three hold the lease internally.

```bash
LEASE_STATE=$(jq -r .lease_state "$RUN_STATE")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" heartbeat --state-file "$LEASE_STATE"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" hold \
  --state-file "$LEASE_STATE" --interval-seconds 60 --max-seconds 14400 -- COMMAND...
```

Every handled terminal path calls one cleanup, which attempts every release and
removes only a matching `current-run.json`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-leases.sh" cleanup \
  --state-file "$LEASE_STATE" --run-state "$RUN_STATE" --run-id "$RUN_ID"
```

## Delivery receipt

`maintain-delivery.sh` is the only delivery lifecycle writer. Its validated,
atomic receipts live under the common Git directory, so every local worktree sees
the same state. It permits one nonterminal issue at a time. Separate clones do not
share receipts: a public PR marker without the matching local receipt is untrusted
and blocks adoption rather than becoming authority.

Before the GitHub queue, call `maintain-delivery.sh pending --repo-root "$REPO_ROOT"`
and require zero or one result. Resume one pending receipt before
new work, including `close_intent` or `closed_observed` for an issue absent from
the open queue. This is the only normal-pass delivery call permitted before `$WT`
exists. Every mutating or proof action uses `--repo-root "$WT"`; the primary
checkout does not satisfy the lease's dedicated worktree binding.

A heartbeat-valid exclusive `maintain-loop` lease bound to `$WT` is controller
authority for a nonterminal receipt even when its run ID differs from immutable
`.origin_run_id`. The origin ID remains provenance and the run-ledger identity;
never rewrite or transfer it. A different-run legacy `maintain` primary lease
cannot resume that receipt.

For a pending receipt, reset the leased worktree to the exact receipt-bound SHA
before continuing: normal or rollback QA/tribunal uses that role's `head_sha`,
while post-merge live/release/close work uses that role's recorded merge `sha`.
Use `maintain-attempt.sh reset` with the current lease and run identity; it
recreates a missing registered worktree and leaves the exact clean HEAD. A `claimed` receipt or any pending state without its
required bound SHA stops fail-closed; do not infer a base, preserve a dirty tree,
or invent recovery state.

For a new issue mint a separate `DELIVERY_ID` with `agent-events.sh new-run-id`,
but defer `maintain-delivery.sh begin` until the source section has created and
validated `$WT` and the base gate is green. The helper compares its own fresh
issue fetch with the retained classified scope before sealing title/body. Every
later mutating delivery action also passes `--lease-state "$LEASE_STATE"`, and
the helper heartbeats it before state or remote mutation. A prior
`finalized_success` may start another generation
only with the ID and timestamp of a paginated GitHub `reopened` event later than
the recorded close. Historical PRs stay history. Never infer or recreate a
receipt from GitHub state.

## Queue and routing

Build the queue only with `scripts/maintain-queue.sh`, passing filters plus the shared
and any legacy blocked ledgers; repeated `--blocked-file` arguments preserve active
cooldowns, while new rows go only to the shared ledger. Exclude `needs-human`, `epic`,
active cooldowns, open-PR claims, and unresolved dependencies. Order by dependency,
severity, then age. A zero queue must account for every candidate, otherwise fail.
Before delivery, remove `maintain:blocked` from every issue number reported under
`.cleanup.stale_maintain_blocked`; these labels have no active durable cooldown.
Under `--dry-run`, report the planned removals without mutating GitHub. A failed
label removal stops the pass.

For each issue, retain the exact regular output of `gh issue view "$N" --json
number,state,title,body,updatedAt` as `ISSUE_SCOPE_JSON`; require those exact
fields, the selected number, and `state == "OPEN"`. Use its title/body for task
classification and the attempt prompt. Read labels, comments, linked PRs, and
the delivery receipt separately. List PRs in every state without truncation. Markers only find
candidates; accept one only through `maintain-delivery.sh match-pr`. Each delivery
generation owns exactly one normal PR. An open authorized candidate resumes its
recorded gate. A merged candidate resumes only when the receipt already contains
the exact supervisor premerge authorization; otherwise stop. An abandoned branch
without a planned receipt-owned PR is verified, deleted with recorded cleanup,
and restarted from a clean base. Put task text and labels in temporary files, classify with
`delivery-route.sh classify --mode autonomous`, then delete those temporary files
but retain `ISSUE_SCOPE_JSON` through the base gate and `begin`.
Exit 2 stops the pass; exit 20 selects `deep`. Autonomous `light` additionally
requires `ui_touch=false`. Mechanical work runs only an exact existing script
with objective output; uncertainty becomes `standard`.

Write the attempt prompt under the ignored primary path
`.startup/maintain-loop/prompts/<RUN_ID>/issue-<N>-attempt-<A>.md`. Include the
issue acceptance criteria, profile, base SHA, assigned worktree, and a narrow
source/test mutation contract. Do not put issue text or the prompt in events.

## Source attempt and containment

While leased, exclude `.worktrees/` through `.git/info/exclude`. For each attempt,
fetch default, record a new exact `BASE_SHA`, reset the dedicated worktree, and initialize
`CHECK_SCRIPT`. Then run the canonical base gate before
creating a branch or writer. It reasserts `HEAD == BASE_SHA`, runs the trusted check,
and caches only a validated pass in the protected common-Git runtime with a bounded summary.
A red base stops before dispatch and is not attributed to the issue.

`maintain-attempt.sh deliver` is the source transaction interface. Its one host
process mints the token, checks all leases before the guard snapshot, runs the
writer, verifies containment even after worker failure, and routes the diff. Only
then does it recheck leases, snapshot strict commit trust from the accepted ref
state, and pass the same in-memory token and receipt to the full commit gate.
It rejects source-free success and invalid lower-profile routing. On every exit or
signal it invalidates guard/trust artifacts. Never split this into tool calls or
reuse a candidate from an interrupted transaction; reset and retry from a new
token.

```bash
git -C "$REPO_ROOT" fetch origin "$default"
BASE_SHA=$(git -C "$REPO_ROOT" rev-parse "origin/$default^{commit}")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-attempt.sh" reset \
  --repo-root "$REPO_ROOT" --worktree "$WT" --base-sha "$BASE_SHA" \
  --lease-state "$LEASE_STATE" --run-id "$RUN_ID"
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE_SHA" ]
CHECK_SCRIPT=./check.sh
BASE_GATE_DIR="$GIT_COMMON/saas-startup-team/maintain-runtime/base-checks/$RUN_ID"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-attempt.sh" base-check \
  --repo-root "$WT" --base-sha "$BASE_SHA" --lease-state "$LEASE_STATE" \
  --run-id "$RUN_ID" --cache-dir "$BASE_GATE_DIR" --check "$CHECK_SCRIPT"
```

Only for new work, now call `maintain-delivery.sh begin --repo-root "$WT"` with
the new issue and delivery IDs, the run's validated `--merge-budget`,
`--scope-json "$ISSUE_SCOPE_JSON"`, and `--lease-state "$LEASE_STATE"`. The helper
independently fetches the same five fields and creates no receipt or run ledger
unless the canonical JSON matches exactly. Delete the snapshot immediately after
a successful `begin`; terminal cleanup deletes it on failure. A resume never
calls `begin` again. Do not create the issue branch or launch a writer unless
this transition succeeds.

After a green base gate, create the local issue branch at `BASE_SHA` and confirm
no open PR or remote branch claims it. The prompt must be a regular file named
`issue-<N>-attempt-<A>.md` in this run's primary prompt directory. Then invoke the
single transaction and handle exit 20 only through the persistent escalation path:

```bash
ATTEMPT_ARGS=(deliver --repo-root "$WT" --base-sha "$BASE_SHA"
  --lease-state "$LEASE_STATE" --run-id "$RUN_ID" --attempt "$ATTEMPT"
  --profile "$PROFILE" --task-file "$PROMPT" --message "$COMMIT_MESSAGE"
  --check "$CHECK_SCRIPT" --routing-reasons "$ROUTING_REASONS")
for path in "${ROLE_ALLOWED_PATHS[@]}"; do ATTEMPT_ARGS+=(--allow "$path"); done
ATTEMPT_RC=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-attempt.sh" "${ATTEMPT_ARGS[@]}" || ATTEMPT_RC=$?
case "$ATTEMPT_RC" in 0) : ;; 20) ;; *) exit "$ATTEMPT_RC" ;; esac
```

The transaction records `attempt-results/<RUN_ID>/issue-<N>-attempt-<A>.json`, keeping different issues' attempts distinct.

The authenticated guard enforces exact source/test paths and verifies HEAD, branch, index, refs,
Git configuration, hooks, ignored files, and `.startup/state.json`. It rejects GitHub
state, protected ignored state, unrelated docs/config, and all worker-authored commits.
Only after verification may the transaction use
`delivery-route.sh --guard-verified` and `check-diff --base "$BASE_SHA"`; unguarded
sensitive or credential state routes deep. Exit 2 fails closed; only `supervisor-commit.sh` stages the accepted candidate.
On failure, reset this worktree
and use a fresh writer; never patch product source in the supervisor.

For an autonomous light attempt, continuation requires exit 0, `profile=light`,
and `ui_touch=false`. A deep result from a lower profile permits exactly one
restart at `deep` and only through the escalation protocol below. A second
escalation is failure.

## Persistent escalation and cleanup

The model never writes or interprets cleanup facts. The escalated attempt result is
the input to the model-free cleanup helper:

```bash
ESCALATION_ARGS=(--repo-root "$REPO_ROOT" --worktree "$WT"
  --lease-state "$LEASE_STATE" --run-id "$RUN_ID" --issue "$N"
  --attempt "$ATTEMPT" --base-sha "$BASE_SHA" --branch "$ISSUE_BRANCH")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-escalation.sh" cleanup \
  "${ESCALATION_ARGS[@]}"
```

The helper validates the protected attempt result and lease identity, closes only
PRs tied to its exact branch/head, deletes only that exact remote/local branch,
resets and cleans to `BASE_SHA`, re-queries GitHub and the remote, and atomically
writes `.startup/maintain-loop/escalations/<RUN_ID>/issue-<N>-attempt-<A>.json`
in primary ignored state. Its canonical cleanup polarity is
`open_pr=false`, `remote_branch=false`, `head_at_base=true`, and
`worktree_clean=true`; malformed, contradictory, unsafe, or partially written
evidence fails closed.

Immediately before the deep writer, call `maintain-escalation.sh
authorize-restart "${ESCALATION_ARGS[@]}"`. It independently revalidates the
receipt and all four live facts and is the sole restart authority. Only its zero
exit sets `ESCALATED=1`, increments `ATTEMPT`, and permits one `PROFILE=deep`
restart. Keep queue eligibility unchanged; never perform another lower-to-deep restart.

## Supervisor delivery gates

After containment, the supervisor performs these steps in order:

1. Run the project deterministic check from the recorded base and keep its exact
   command/status evidence locally. `maintain-attempt.sh deliver` passes its
   in-memory authenticated trust receipt to `supervisor-commit.sh`; that helper
   owns staging, staged-size validation, hooks, and the commit. Never use
   `--no-verify`. Confirm the committed tree equals the checked tree and its sole
   parent equals `BASE_SHA`.
2. For browser-visible work, select an existing tracked project smoke command
   that asserts desktop, 375px, console, and task behavior. The delivery helper
   executes it later at the exact receipt commit. For other work, do not invent a
   QA pass; the helper's bound-diff classifier must prove not-applicability.
3. Before push or PR creation, persist `plan-pr --role normal` with the exact
   branch, base, and committed head. The one normal PR contains `Refs #N` and
   exactly one each of these lines, using receipt values:

   ```text
   Maintain-Loop-Issue: #N
   Maintain-Loop-Delivery: <DELIVERY_ID>
   Maintain-Loop-Role: normal
   Maintain-Loop-Action: <DELIVERY_ID>-normal
   ```

   Never use a closing keyword. After creation, or after a crash during creation,
   discover candidates by those markers, require exactly one, run `match-pr`, then
   `bind-pr --role normal` with its fresh JSON. Never open a second normal PR. Run
   `issue-closure-audit.sh --audit-issue "$N"`; the body also states recurrence
   class, red-before/green-after proof, durable guard, QA evidence, and risk.
4. Resolve the installed `tribunal-review` plugin root, then call
   `collect-tribunal --role normal --tribunal-plugin-root "$TRIBUNAL_PLUGIN_ROOT"`.
   The helper pins the installed runner bundle and owns the PR/head-bound provider
   collection. Read those retained provider files and apply the inline
   arbitration step from `tribunal-review:tribunal-loop` without rerunning its
   provider scripts. Set caller identity from the actual context. Its
   verdict must cover the current PR head and diff with zero critical/high
   findings. For `NEEDS_WORK` or `BLOCK`, apply
   `tribunal-review:closing-tribunal-loop`; a finding that needs source changes returns to a fresh tech-founder;
   then the supervisor rechecks, commits, pushes, reruns browser QA and closure
   audit, and restarts tribunal. Persist and increment `TRIBUNAL_ROUND` in this
   issue's run artifact before every invocation. Notify at round 3. Round 5 is the
   final allowed invocation; if it does not clear the gate, stop the issue as
   blocked. Never invoke round 6. Any HEAD or validation-fact change invalidates
   the prior verdict but does not reset the counter. Now read
   `maintain-proof-contract.md`. Call `record-proof --kind qa` with the tracked
   command, or `--not-applicable`; then call `record-proof --kind tribunal` with
   only the arbitration artifact and installed plugin root. The helper finalizes
   and verifies its retained collection; caller-supplied provider files are invalid.
5. Re-fetch default, enforce merge budget, and independently read the PR. Require
   a concrete numeric `PR_NUMBER`, state `OPEN`, expected base branch, local
   `PR_HEAD_SHA`, matching remote `headRefOid`, current tribunal SHA, successful
   required check runs for that SHA, and
   `git merge-base --is-ancestor "origin/$default" "$PR_HEAD_SHA"`. Call
   `authorize-merge --role normal` with no evidence input. It independently
   re-fetches the bound PR, checks, default ancestry, QA/tribunal receipts, and
   prospective closure audit through a trusted absolute `gh` executable.
   Then call `maintain-delivery.sh merge-pr --repo-root "$WT" --issue "$N"
   --role normal --merge-method squash`. It rechecks the unchanged default, PR,
   and checks, persists the method, and alone invokes
   `gh pr merge --match-head-commit <receipt-head> --squash`.
   Never invoke `gh pr merge` directly; pass no PR/default snapshot. A head
   mismatch stops instead of merging a newer commit.
6. Call `record-merge --role normal`; pass no counter, budget, PR, or default
   snapshot. The helper freshly
   requires the exact bound PR `MERGED`, its concrete merge on fetched default,
   and atomically advances the run-owned merge ledger. `merge-pr` checks that same
   ledger before mutation. This handles a crash after `gh pr merge`; it refuses a merged
   PR whose receipt never reached premerge authorization. Do not maintain a caller
   `MERGES_USED` counter: caller-supplied accounting is not authority. Each normal merge
   counts across every issue in the run; only the one emergency rollback may
   exceed the cap.
   Read `MERGE_SHA` only from the updated receipt's `.normal.merge.sha`, then call
   `maintain-attempt.sh reset --repo-root "$REPO_ROOT" --worktree "$WT"
   --base-sha "$MERGE_SHA" --lease-state "$LEASE_STATE" --run-id "$RUN_ID"`.
   Require an exact clean `WT` HEAD at `MERGE_SHA`; a squash merge does not leave
   the prior PR head eligible for live proof.
7. Select a concrete deploy run for `MERGE_SHA`; never trust "latest". Call
   `record-proof --kind live` with its numeric run ID, stable target-source code,
   and the project's tracked `monitor.custom_checks` hook when it covers the
   acceptance, otherwise an existing tracked structured smoke command, as defined
   in `maintain-proof-contract.md`.
   Then call `record-release` with only that run ID and target-source. Both actions
   independently require the exact run completed successfully at the merge SHA;
   caller-authored SHA, digest, or pass fields are not inputs. Remove and verify
   absence of `maintain:claimed`, then call `close-intent` with no snapshots or
   audit result. It freshly fetches the exact merged PR and full OPEN issue, runs
   the prospective audit itself, re-fetches both around the audit, and durably
   binds the unchanged issue revision and digest.
   Then call `maintain-delivery.sh close-issue --repo-root "$WT" --issue
   "$N"` with no snapshot argument. That helper alone fetches and compares the
   full current OPEN revision, invokes `gh issue close`, fetches the full CLOSED
   revision, and records it only when the digest is unchanged and
   `updatedAt == closedAt`. After a crash between close and the postfetch, call
   `observe-closed` with no snapshot; it freshly fetches and applies the same checks. A
   changed or reopened issue is unresolved and must never be reclosed under the
   old intent; a closed issue without a matching intent is also unresolved. Call
   `render-result` into a temporary regular file, then pass that exact file to
   `finalize`, which rerenders and byte-compares every receipt fact before atomically installing the run artifact
   and appends the `issue-outcome` once. A repeated finalize is a verified no-op.

On deploy/live failure, stop new issue work; recovery is rollback-or-stop, never
another corrective delivery merge. If
the normal merge is clearly causal and revert is safe, permit one receipt-owned
rollback action. From an exact fetched `ROLLBACK_BASE_SHA` containing `MERGE_SHA`,
derive the expected tree with `git revert --no-commit "$MERGE_SHA"`. The rollback
`plan-pr` call must supply a one-commit head whose sole parent is that base and
whose tree is the exact expected reverse of the recorded normal merge with no
unrelated diff; the helper persists and validates the target merge, base, head,
and expected tree. Ancestry or a commit-message claim alone is not revert proof.
Call `plan-pr --role rollback` before push/PR creation, use receipt markers with
role `rollback:1`, and run `bind-pr`, checks, `collect-tribunal`, and
`record-proof` for QA/tribunal,
and `authorize-merge`. Call `merge-pr --role rollback
--merge-method <squash|merge>`; that helper alone
   merges with `--match-head-commit` for the authorized rollback head. Continue
   through `record-merge` with no caller accounting (only this one rollback may
   exceed the run ledger by one). Read `ROLLBACK_MERGE_SHA` only from
   `.rollback.merge.sha`, then perform the same lease-validated
   `maintain-attempt.sh reset` of `$WT` to that SHA before rollback-SHA `record-proof --kind live`,
   `record-release` with only run/target identity, `render-result`, and
   `finalize`. Reuse that exact action after
interruption; never create a second rollback PR. Record
`merge_budget_overage:rollback` when necessary and stop. Otherwise stop blocked.
Infra, credentials, external dependency, migration-data, ambiguity, unresolved
deploy/live, or failed rollback remains failure. Never emit success, `fixed:`, or
increment delivered count for a rolled-back or unresolved issue.

## Authoritative outcome

`maintain-delivery.sh render-result` derives the result solely from the validated
receipt. The supervisor writes that output to a temporary regular file;
`finalize` rerenders it, requires an exact byte match, and installs the only result artifact under ignored primary state at
`.startup/maintain-loop/runs/<origin-RUN_ID>/issue-<N>.md`. Success requires:

- `fixed:PR#<number>`, `pr_number:<number>`, `pr_head_sha:<sha>`,
  `merge_sha:<sha>`, and `default_ancestry:passed`;
- `checks:passed`, its stable evidence ID, and evidence head equal to `pr_head_sha`;
- `qa:passed|not_applicable`, stable evidence ID/reason code, and exact head;
- `tribunal:passed`, stable evidence ID, and verdict SHA equal to `pr_head_sha`;
- `pr:merged`, `merge:merged`, and exact merge count/budget;
- `deployment:passed`, deploy run ID, and head SHA equal to `merge_sha`;
- `live_qa:passed` with target-source code, evidence digest, and verification timestamp;
- `ready_to_close:validated` with exact issue, PR, merge, prospective-audit, and
  `claim_label:removed` receipt fields;
- `issue:closed` from an independent post-live query;
- `rollback:not_run` and `outcome:success`.

The receipt transitions independently re-query those facts before putting `fixed:`
in a canonical render. Never hand-author or amend the rendered file: an omitted, duplicate, reordered, or
contradictory line fails finalization. Increment `ISSUES_DELIVERED` only after the
receipt reaches `finalized_success`. A rollback render instead binds both PR heads
and merge SHAs, its final checks/QA/tribunal evidence, exact count/budget,
rollback deploy/live proof, explicit no-close state, `rollback:rolled_back`, and
`outcome:rolled_back`; it never contains `fixed:`. Events contain statuses and routing reasons,
never issue text, URLs, paths, repository identity, prompts, or diffs. Worker
launcher `implementation` events prove process execution only. The supervisor
never writes an `implementation` event; its authority is limited to `issue-outcome`
and the single `pass-outcome`, so worker success cannot claim delivery success.
An unhandled interruption retains the launcher's explicit incomplete record;
handled interruption or failure adds a supervisor `cancelled` or `failure`
outcome event. No-op queues launch no worker and emit no worker event.

For success and rollback, `maintain-delivery.sh finalize` appends the exactly-once
supervisor `issue-outcome`; do not append another. Other handled terminal paths
append one observed failure/blocked/cancelled outcome. After issue processing ends,
stop all work and run the one cleanup before choosing
the aggregate terminal status. Cleanup is unconditional even when the later event
append fails. A nonzero foreground `hold` result is a terminal pass failure. A
nonzero cleanup result also makes the pass a failure. Then append exactly one supervisor terminal `pass-outcome`
event for this `RUN_ID` using the observed
status, and return immediately; never continue the queue. Do not retry the
terminal append, restart setup, or create another run from this invocation.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" append \
  --events "$REPO_ROOT/.startup/runs/agent-events.jsonl" \
  --run-id "$RUN_ID" --command maintain-loop --phase pass-outcome \
  --surface script --profile mechanical --writer-id "supervisor-$RUN_ID" \
  --attempt 1 --event-type completed --outcome "$PASS_OUTCOME"
```

Add each routing reason with `--routing-reason <stable-code>`; never use task text.
For any nonsuccess path, substitute the observed status codes and terminal
`failure`, `blocked`, `cancelled`, or `escalated` outcome before stopping.
Before applying `maintain:blocked`, call `maintain-blocked.sh upsert` for the
issue's `{number,reason,cooldown_until}` row in the persisted shared
`blocked_file`; a failed durable write stops the label mutation.

Stop on lease loss, unexplained queue state, malformed/missing escalation or
result evidence, exhausted cap/time/budget, hard tribunal ceiling, failed cleanup,
or any unresolved deploy/live/rollback. Under `--once`, stop after one terminal
issue result. Report only queue count, issue states, PR numbers, deploy/live
status, and actionable blockers; keep raw evidence local.
