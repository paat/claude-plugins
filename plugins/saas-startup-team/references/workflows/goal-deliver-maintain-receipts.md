# Embedded `/maintain` Receipt Adapter

This file is a compatibility adapter for the one supported embedded caller of
`goal-deliver.md`: `SAAS_EMBEDDED_CALLER=maintain`. Load it only after the caller
envelope in `goal-deliver.md` has been validated. A standalone `/goal-deliver` must
never load or execute it.

`goal-deliver.md` remains the sole delivery contract. Its routing, implementation
quality, QA, tribunal, current-HEAD, merge-policy, deployment, and rollback decisions
remain authoritative. This adapter adds only the maintain-owned claim, lease, durable
receipt, crash-recovery, and helper sequencing needed to bind those decisions to one
issue and one PR. Do not copy the common gates into this file.

## Stable compatibility state

Existing deliveries remain valid. Do not rename or migrate these persisted paths or
receipt fields merely because the public coordinator is now thin:

- delivery receipts under the common Git directory at
  `saas-startup-team/maintain-runtime/deliveries/issue-<N>/current.json`;
- merge ledgers and protected proof artifacts under the same
  `saas-startup-team/maintain-runtime/` root;
- prompts at `.startup/maintain-loop/prompts/<origin-RUN_ID>/issue-<N>-attempt-<A>.md`;
- attempt results at `.startup/maintain-loop/attempt-results/<origin-RUN_ID>/issue-<N>-attempt-<A>.json`;
- escalation evidence at `.startup/maintain-loop/escalations/<origin-RUN_ID>/issue-<N>-attempt-<A>.json`;
- canonical results at `.startup/maintain-loop/runs/<origin-RUN_ID>/issue-<N>.md`.

The receipt's `origin_run_id` remains provenance and the run-ledger identity. A later
canonical maintain invocation may control a safe resume of a canonical bound receipt
through its live whole-pass lease; it never rewrites that origin. Historical schema-v1
receipts recover on the **primary working directory only** (no linked worktrees).
Only a matching live legacy controller may promote a nonterminal schema-v1 receipt, and that
schema-only promotion preserves its original `updated_at` claim timestamp. Its
`pending` projection exposes one `controller_route` object:
`{kind,mode,worktree}` with `worktree` always the primary path. That object synthesizes
the historical binding for schema v1 and retains the persisted binding after promotion.
Do not infer a route from the schema number. `maintain-delivery.sh`
is the only delivery lifecycle writer. Call its public actions rather than editing any
receipt or ledger.

## Recovery before new work

Before a normal queue item starts, call the read-only `maintain-delivery.sh` `pending`
inventory action:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-delivery.sh" pending \
  --repo-root "$REPO_ROOT"
```

Require a valid array containing zero or one nonterminal receipt and consume its exact
`controller_route` before lease/primary binding. More than one, malformed state,
or an unbound receipt fails closed. Resume the single pending receipt
before triage or new queue work; this is what lets an invocation recover a crash after claim, PR creation, merge, release, or close. `claimed` resumes at source preparation;
later states resume at the next helper-owned transition and never repeat an already
recorded irreversible action.

Under `--dry-run`, print the receipt identity, current state, and planned next transition,
then stop. Do not acquire a lease, enter `/goal-deliver`, advance the receipt, touch its
worktree or PR, emit an event, or perform recovery cleanup.

For recovery, re-fetch the complete issue and PR facts and re-prove the exact authored
`<!-- maintain:claim:ID -->` binding described by `maintain-protocol.md`. The active
invocation must still hold the whole-pass lease selected by that route, but the receipt
keeps its original run identity. A pending state without its issue, claim, bound primary tree, or
receipt-owned PR is unresolved and must not be silently archived or replaced — **except**
the exact salvage case handled by `archive-claimed` / the maintain probe reconciler:
`state=claimed`, issue exactly `CLOSED`, no delivery-owned PR marker, no merge-ledger
event, clean detached worktree at a validated base **or** the primary tip, and no
published remote claim branch. That path archives the receipt (and drops a stale
`maintain:claimed` label) so a human-salvaged close cannot soft-block the pinned slot
on `receipt_conflict` for hours. Ambiguous ownership still fails closed. A
terminal receipt is not pending; `finalize` is an idempotent verified no-op when its
canonical result and event already exist. A legacy recovery ends the pass after that
one receipt; `begin` rejects new work under its compatibility controller.

## Embedded binding and lease

Use only the validated values inherited from `goal-deliver.md`:

- `SAAS_EMBEDDED_WORKTREE` is the exact real current worktree;
- `SAAS_EMBEDDED_CLAIM` is the freshly verified issue/PR marker;
- `SAAS_EMBEDDED_LEASE_STATE` is the active whole-pass lease state;
- `SAAS_EMBEDDED_REMAINING_SECONDS` is the positive remaining pass budget;
- `SAAS_INVOCATION_ID` is the current canonical root and
  `SAAS_INVOCATION_COMMAND` is `maintain` or `maintain-loop`.

Keep the four identities separate throughout the adapter:

```bash
CONTROLLER_RUN_ID="$SAAS_INVOCATION_ID"
INVOCATION_COMMAND="$SAAS_INVOCATION_COMMAND"
DELIVERY_CONTROLLER_ARGS=(
  --lease-state "$SAAS_EMBEDDED_LEASE_STATE"
  --controller-run-id "$CONTROLLER_RUN_ID"
)
```

`ORIGIN_RUN_ID` is the immutable ID from the verified claim and delivery receipt. For
new work it is the ID already embedded in the freshly verified claim; for recovery it
comes from the existing receipt and may differ from `CONTROLLER_RUN_ID`. Never rewrite
the origin to the current controller. `CHILD_RUN_ID` is a fresh canonical ID minted for
each writer attempt, including the authorized deep retry; it must differ from both the
origin and controller. `DELIVERY_ID` is a separate fresh canonical child ID minted once
before `begin`; the receipt persists it as the stable `issue-outcome` event identity.
It must differ from `CONTROLLER_RUN_ID` and is never replaced during recovery.

Heartbeat and revalidate the inherited lease before every helper transition and every
external mutation. Never acquire or release a second goal lease. Run the source
transaction and all receipt-authorized GitHub transitions under the active controller lease;
shell loss does not invalidate a validated durable delivery receipt. Append the
exact `"${DELIVERY_CONTROLLER_ARGS[@]}"` tuple to every
mutating `maintain-delivery.sh` action; read-only actions need no controller tuple, and
`archive-claimed` acquires its own idle cleanup lease. The helper binds that explicit
controller to the repository and worktree before lock creation, heartbeat, receipt
change, or GitHub mutation. The origin ID is never used as controller authority.

## Source transaction and escalation

For a new issue, capture the complete classified issue scope in a private regular file.
Fetch current default, record `BASE_SHA`, and prepare the primary checkout through:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-attempt.sh" reset \
  --repo-root "$REPO_ROOT" --base-sha "$BASE_SHA" \
  --lease-state "$SAAS_EMBEDDED_LEASE_STATE" --run-id "$ORIGIN_RUN_ID" \
  --controller-run-id "$CONTROLLER_RUN_ID"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-attempt.sh" base-check \
  --repo-root "$WT" --base-sha "$BASE_SHA" \
  --lease-state "$SAAS_EMBEDDED_LEASE_STATE" --run-id "$ORIGIN_RUN_ID" \
  --controller-run-id "$CONTROLLER_RUN_ID" \
  --cache-dir "$BASE_GATE_DIR" --check "$CHECK_SCRIPT"
```

Only after the base gate is green:

Mint `DELIVERY_ID` with `agent-events.sh new-run-id`, then call
`maintain-delivery.sh begin` with the issue, origin run, that fresh delivery ID,
validated merge budget, exact `--scope-json`, and
`"${DELIVERY_CONTROLLER_ARGS[@]}"`. A resume never calls `begin` again. The receipt
must exist before branch creation or writer dispatch.

Create the bounded prompt at the stable compatibility path above. Execute the source
mutation only through `maintain-attempt.sh deliver`; it owns the paused worker phase,
route verification, checked thin commit, and protected attempt result.
The profile selected by `goal-deliver.md` still controls the writer, but embedded
mechanical/light work uses this transaction instead of the standalone `tweak-run.sh`
branch path.

```bash
CHILD_RUN_ID="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-attempt.sh" deliver \
  --repo-root "$WT" --base-sha "$BASE_SHA" \
  --lease-state "$SAAS_EMBEDDED_LEASE_STATE" --run-id "$ORIGIN_RUN_ID" \
  --controller-run-id "$CONTROLLER_RUN_ID" --child-run-id "$CHILD_RUN_ID" \
  --invocation-command "$INVOCATION_COMMAND" --attempt "$ATTEMPT" \
  --profile "$PROFILE" --task-file "$PROMPT" --message "$COMMIT_MESSAGE" \
  --check "$CHECK_SCRIPT" --routing-reasons "$ROUTING_REASONS"
```

Post-diff route exit 20 keeps the green candidate and continues commit (`promote_deep`);
do not discard/rewrite for routing alone. Reserve cleanup + `authorize-restart` for true
discards (failed checks or an untrusted tree):

```bash
ESCALATION_ARGS=(
  --repo-root "$REPO_ROOT"
  --lease-state "$SAAS_EMBEDDED_LEASE_STATE"
  --run-id "$ORIGIN_RUN_ID" --controller-run-id "$CONTROLLER_RUN_ID"
  --issue "$N" --attempt "$ATTEMPT" --base-sha "$BASE_SHA" --branch "$BRANCH"
)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-escalation.sh" cleanup "${ESCALATION_ARGS[@]}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-escalation.sh" authorize-restart "${ESCALATION_ARGS[@]}"
CHILD_RUN_ID="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)"
```

The helper's persisted polarity is `open_pr:false,remote_branch:false,head_at_base:true,worktree_clean:true`.
Only that exact evidence permits one fresh deep attempt after a real discard.

## One receipt-owned PR

Before push or PR creation, call `maintain-delivery.sh plan-pr --role normal` with the
exact branch, base, and committed head. The PR body carries the byte-exact claim marker,
uses `Refs #N` (never `Closes`, `Fixes`, or `Resolves`), and contains exactly one of each
stable compatibility line:

```text
Maintain-Loop-Issue: #N
Maintain-Loop-Delivery: <DELIVERY_ID>
Maintain-Loop-Role: normal
Maintain-Loop-Action: <DELIVERY_ID>-normal
```

After creation or an ambiguous create response, list candidates without truncation,
accept exactly one through `maintain-delivery.sh match-pr`, and bind freshly fetched PR
JSON through `bind-pr`. Never open a replacement PR. Resume re-fetches the exact issue,
claim, selected PR, current default, and PR head before checkout, before QA/tribunal,
and immediately before merge. Do not trust an earlier green check or receipt proof
after any HEAD, default, issue, or validation-fact drift.

### Rebinding the receipt head after a same-PR advance

When a later commit lands on the **same** open bound PR (e.g. a head-bound QA smoke
script after tribunal), the receipt `head_sha` must advance before any further
proof or merge step. Call:

```bash
maintain-delivery.sh rebind-head --repo-root "$ROOT" --issue "$N" \
  --role normal --head-sha "$NEW_HEAD" [--pr-json FILE]
```

Rules:

- Only from `normal_open` / `rollback_open`.
- `$NEW_HEAD` must be a descendant of both the receipt `base_sha` and the prior
  `head_sha` (advance-only; never rewind).
- The live (or snapshot) open PR head must equal `$NEW_HEAD` on the same branch.
- Clears `premerge` so checks/QA/tribunal must re-run at the new head.
- There is no other legal head-refresh path; do not hand-edit the receipt.

### Rebinding the receipt body after required evidence appends

When the **same** open bound PR keeps markers/branch/head fixed but the body gains
required evidence (e.g. a mandatory `## Design-review: PASS` block), call:

```bash
maintain-delivery.sh rebind-body --repo-root "$ROOT" --issue "$N" \
  --role normal --pr-json FILE
```

Rules:

- Only from `normal_open` / `rollback_open`.
- PR number, branch, and head must still match the receipt.
- Delivery markers must still match the receipt.
- Updates `body_digest` only; does **not** clear `premerge` (head-bound proofs remain).
- There is no other legal body-refresh path; do not hand-edit the receipt.

## Recording the canonical goal gates

Run the common delivery gates exactly where `goal-deliver.md` requires them. This
adapter does not redefine their content. It only binds their verified outputs:

- `record-proof --kind qa` records the exact receipt head and the canonical QA command,
  or the helper-verified not-applicable classification;
- `collect-tribunal` retains the provider bundle. If the active collection is sealed
  with a non-`APPROVE` proof (or bound to a different head), the helper **retires**
  that directory in place (`*.retired-<stamp>-<head>`) and collects a fresh round —
  up to 5 retires per delivery/role (plugin issue #339). Callers still must not
  delete or rewrite protected evidence themselves.
- `record-proof --kind tribunal`
  accepts only the canonical current-head arbitration artifact using
  `maintain-proof-contract.md`;
- any source, PR-body validation fact, rebase, default advance, or head change
  invalidates the recorded proof and reopens the corresponding goal gate.

The receipt helper validates these facts independently. A worker exit code, caller
boolean, stale snapshot, or hand-authored proof is not authority.

## Authorized merge, release, and close

After every common latest-head predicate passes, call `authorize-merge --role normal`
with no evidence input, then `merge-pr --role normal --merge-method squash`.
Pass no PR/default snapshot. The helper re-fetches the bound PR, checks, ancestry, closure
audit, and proof receipts, then alone invokes
`gh pr merge --match-head-commit <receipt-head> --squash`. Embedded delivery never invokes `gh pr merge` directly.

Call `record-merge --role normal` with no caller counter or snapshot.
Read `MERGE_SHA` only from the updated receipt and use `maintain-attempt.sh reset` to put the primary
working tree at that exact clean merge commit before live proof, passing the immutable
`--run-id "$ORIGIN_RUN_ID"` and current `--controller-run-id "$CONTROLLER_RUN_ID"` again.

Run the common deploy/live verification in `goal-deliver.md`. Once it is green at
`MERGE_SHA`, record the bound evidence through `record-proof --kind live`, then call `record-release` with only the verified deploy run and stable target-source code.
Release proof must exist before issue close intent. Remove `maintain:claimed`, verify
its absence, and call `close-intent` with no snapshots. It freshly re-fetches the exact merged PR and open issue and runs the prospective closure audit.

Then call `maintain-delivery.sh close-issue --repo-root "$WT" --issue "$N"` with no snapshot argument. That helper alone fetches and compares the complete open revision,
closes the issue, and verifies the complete closed revision. After a crash between close and verification, call `observe-closed` with no snapshot. Changed, reopened, or
unbound issue state remains unresolved; never re-close it under stale intent.

## Rollback-or-stop recovery

A failed or unverified live release stops new issue work. Apply the common causal/safe
rollback decision from `goal-deliver.md`; receipt recovery is rollback-or-stop, never a
fresh corrective delivery. If rollback is authorized, derive the exact expected inverse tree of the recorded normal merge, create one receipt-owned rollback PR, and use the
same `plan-pr`, `bind-pr`, proof-recording, `authorize-merge`, `merge-pr`, and
`record-merge` transitions with `--role rollback`. The helper accepts one rollback and
pins its authorized head; ancestry or a commit-message claim is not inverse proof.

Reset the worktree to the receipt's rollback merge SHA before rollback live proof.
After verified recovery, record live proof and release, then finalize a rolled-back
result without closing the issue. Never create a second rollback PR, emit `fixed:`, or
continue new issue delivery after rollback.

## Canonical result and telemetry

Call `maintain-delivery.sh render-result` into a private regular file and pass those exact bytes to `finalize`. Finalize rerenders and rejects omitted, duplicate, reordered, free-form, or contradictory facts before installing the stable compatibility result.
Success requires the helper-observed close; rollback requires the helper-observed
release and explicit no-close state.

`finalize` is the sole `issue-outcome` writer. Invoke it with the fresh child delivery
ID in `SAAS_RUN_ID`, `CONTROLLER_RUN_ID` in `SAAS_PARENT_RUN_ID`, and
`INVOCATION_COMMAND` in `SAAS_INVOCATION_COMMAND`. On the first binding all three values
are required: `SAAS_RUN_ID` must equal the receipt's immutable `delivery_id`, the parent
must equal the active lease controller run, and the explicit command must be the
inherited public root spelling (`maintain` or `maintain-loop`). The canonical lease mode
is `maintain` for either spelling; only a route-bound historical recovery uses the
`maintain-loop` compatibility lease. The public spelling never changes the selected
mode. The helper persists that binding before append;
a crash retry reuses the persisted command, parent, and profile rather than accepting
replacement context. It appends exactly once. Maintain consumes the canonical result
for queue/digest classification; it does not close the issue, remove the claim, merge,
or synthesize success itself.
