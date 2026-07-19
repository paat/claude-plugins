---
name: goal-deliver
description: Reusable playbook that delivers a set of tasks (GitHub issues, a milestone, a markdown spec, or free text) end-to-end — plan into manageable chunks, then for each chunk run the /improve build cycle, close the tribunal loop, and merge to main; after the final merge, monitor and fix the GitHub Actions deploy. Pairs with built-in /goal for autonomous looping. Usage: /goal-deliver #12 #15 | --milestone v2 | docs/roadmap.md | <free text>
user_invocable: true
---

# /goal-deliver — Goal Delivery Playbook

You are the **Team Lead** (orchestrator); the human is a **silent investor**.
This command is a **playbook**: it expands a set of tasks into the full
deliver-to-production workflow so you don't retype it. It is a prompt, not a
script — **you** decide how to chunk, order, and re-plan the work using your
judgment. The structure and quality bars below are the guardrails, not a rigid
sequence that replaces your reasoning.

The build cycle per chunk is reused from `/improve`
(`${CLAUDE_PLUGIN_ROOT}/commands/improve.md`); the quality gate is the
`tribunal-review` plugin (hard dependency).

Load `${CLAUDE_PLUGIN_ROOT}/references/workflows/routing-telemetry.md` before
routing or launching a role.

## Invocation and caller contract

`SAAS_INVOCATION_ID` is the root workflow identity and matches
`^run-[0-9a-f]{32}$`. A standalone call reuses a canonical inherited value or, when
absent, mints it exactly once with `agent-events.sh new-run-id`; a present invalid value
fails closed and is never replaced. Export the resolved identity before preflight.

`SAAS_INVOCATION_COMMAND` has the finite values `maintain-loop`, `maintain`, and
`goal-deliver`. A standalone call defaults an absent value to `goal-deliver`, rejects
every other value as inconsistent, and exports it. The standalone root append uses this
resolved value.

The only embedded form is `SAAS_EMBEDDED_CALLER=maintain`. It must inherit an already
canonical `SAAS_INVOCATION_ID` and all four nonempty bindings:
`SAAS_EMBEDDED_WORKTREE`, `SAAS_EMBEDDED_CLAIM`,
`SAAS_EMBEDDED_LEASE_STATE`, and `SAAS_EMBEDDED_REMAINING_SECONDS`. Require the real
current worktree to equal the real embedded worktree and require inherited
`SAAS_INVOCATION_COMMAND` to be `maintain` or `maintain-loop`. The claim must match the
exact canonical marker shape `<!-- maintain:claim:ID -->`, where `ID` matches
`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`. Independently re-fetch the path's facts: new work
requires the one authored issue marker and no linked PR, while resume requires the exact
same uniquely authored marker on the issue and selected PR. Carry that exact marker
into the eventual new PR body. This accepts a prior canonical run ID and the bounded
legacy-promoted compatibility ID; it does not require the marker ID to equal the current
invocation. Require the remaining seconds to be a positive integer, and
`maintain-leases.sh heartbeat --state-file "$SAAS_EMBEDDED_LEASE_STATE"
--repo-root "$SAAS_EMBEDDED_WORKTREE" --worktree "$SAAS_EMBEDDED_WORKTREE"
--run-id "$SAAS_INVOCATION_ID"` to confirm the live inherited lease holder. A missing,
invalid, expired, or mismatched binding is `blocked/context_binding_violation` and no
delivery starts. Current ownership is proved by binding the canonical current
`SAAS_INVOCATION_ID` inside that heartbeat to the live inherited lease. Reject every
other nonempty embedded caller or invocation command.

Only after all embedded bindings pass, load
`${CLAUDE_PLUGIN_ROOT}/references/workflows/goal-deliver-maintain-receipts.md` once and
apply that maintain-specific receipt adapter to every new or resumed issue. A standalone
invocation does not load the adapter and keeps the normal goal paths below unchanged.

For each delivery attempt, including a retry, mint a fresh child ID and export it as
`SAAS_RUN_ID`; never reuse the root or a completed child. Every goal work event appends
with `--run-id "$SAAS_RUN_ID" --parent-run-id "$SAAS_INVOCATION_ID"`. Root totals are
never computed from child events.

A standalone `/goal-deliver` is the sole writer for its root and appends exactly one
completed `--phase pass-outcome --once` event on every handled terminal path. Success
has no terminal reason; blocked, failure, cancelled, and escalated paths use only the
finite v2 registry in `routing-telemetry.md`. Append conflict or malformed lifecycle
fails closed and never gets a competing terminal. Under the maintain embedded caller,
`/goal-deliver` never writes a root pass outcome; `/maintain` alone does so.
The standalone append uses `agent-events.sh append --run-id "$SAAS_INVOCATION_ID"
--command "$SAAS_INVOCATION_COMMAND" --phase pass-outcome --event-type completed --once` plus the
verified outcome, actual host surface/profile, stable supervisor writer, and optional
registered reason.

## Delivery safety invariants

Use the repository's documented test/dev target. If it is unavailable, make one repair
using only documented setup/start commands before classifying the target as externally
blocked.

For `SAAS_EMBEDDED_CALLER=maintain`, every new or resumed PR uses the caller-verified
claim marker and a non-closing issue reference such as `Refs #N`; never use `Closes`,
`Fixes`, or `Resolves`. Resume only the one freshly bound existing PR, never open a
replacement PR, and revalidate issue eligibility, claim/PR identity, current default,
and exact current-head binding before mutation and every latest-head gate. The embedded
receipt adapter owns helper-authorized merge, release/live proof, delayed issue close,
crash recovery, rollback-or-stop, and canonical finalization. Maintain consumes that
result but never repeats an irreversible transition. A blocked, failed, rolled-back, or
unverified deployment leaves the issue open.

## Autonomy (optional but recommended)

You cannot arm the built-in `/goal` loop yourself — it is user-typed. For an
autonomous, no-human-in-the-loop run, the investor pairs the two commands,
setting a short completion condition once:

```
/goal all target issues are merged to main and the deploy pipeline is green
/goal-deliver #12 #15 #20
```

Invoked alone (without `/goal`), work through the whole playbook continuously in
this one invocation. If the investor used `/goal`, the goal evaluator re-runs you
until the condition holds.

## Pre-Flight (all gates must pass)

0. **Reusable health preflight.** Run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
   ```
   In Codex, include `--require-codex` when a separate Codex worker may be used. Missing
   Codex CLI/auth is a blocker for Codex surfaces that need it; do not route the work to
   Claude as a fallback.
1. **tribunal-review installed.** Confirm the `tribunal-review:tribunal-loop`
   skill is available. If not:
   > `/goal-deliver` requires the `tribunal-review` plugin (the tribunal gate is
   > non-negotiable). Install it, then re-run.
   Stop.
2. **Solution signoff is valid:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/solution-signoff-gate.sh" \
     --source-root "$(git rev-parse --show-toplevel)"
   ```
   If the executable gate fails, stop and direct the investor to `/startup` (this
   command delivers new work onto a finished product, like `/improve`).
3. **On the default branch and clean tree (standalone only):**
   ```bash
   current=$(git rev-parse --abbrev-ref HEAD)
   default=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/default-branch.sh")
   git status --porcelain
   ```
   If `current != default` or the tree is dirty, stop and ask the investor to
   switch/commit.
   Under `SAAS_EMBEDDED_CALLER=maintain`, skip this standalone primary-checkout gate;
   the caller-bound primary tree and claim above are authoritative. Do not reset,
   clean, or switch the tree here.
4. **`gh` authenticated with a remote:** `gh auth status` and
   `git remote get-url origin` both succeed; else stop and report.
5. **Defer `active_role` mutation.** Do not reset it until the delivery-scope lease in
   Step 1.25 is acquired. **Never write `active_role: "team-lead"`.**

## Step 1: Understand the Tasks

**First, strip flags.** If the arguments contain `--full`, set `FULL_MODE=1` and
remove the token from the argument list before resolving the input form below.
`FULL_MODE` forces the normal gated path (Step 1.5 is skipped entirely). All other
arguments resolve as usual; `--full` is never treated as spec text.

If no arguments were given, run market scouting before asking for feedback. The scout uses
configured external market evidence when available and falls back to internal demand
discovery when browsing/source data is unavailable:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

If `.startup/demand/market-scout.jsonl` contains one or more candidates, take the top
ranked candidate as the selected market need and continue without asking the investor.
If no candidate exists, ask:
> What should I deliver? Give me GitHub issues (`#12 #15`), `--milestone <name>`,
> a markdown spec path, or describe the features.

Resolve the input form (handle inline — no scripts):
- **`#<n>` tokens** → issues: save `gh issue view <n> --json title,body,labels,comments`
  as `issue_json` for each. Keep the numbers to close on merge.
- **`--milestone <name>`** → `gh issue list --milestone "<name>" --state open
  --json number,title,body`. Keep the numbers.
- **a single existing file path** → read it; it is the spec.
- **anything else** → the argument text is the spec.
- **demand candidate JSON** → treat it as the implementation brief: customer segment,
  discovered need, evidence, desired outcome, acceptance packs, non-goals, validation plan,
  and rollout checks.

## Step 1.25: Claim the Delivery Scope

Before entering a mechanical, light, or full founder path, derive a privacy-safe stable
scope identifier from the resolved input (sorted issue numbers; milestone identity; file
blob ID; or a checksum of free text), then acquire one delivery lease. Do not put issue
text, a path, or a repository name in the key or owner filename.

Under `SAAS_EMBEDDED_CALLER=maintain`, skip this acquisition and use only the inherited
whole-pass lease binding. Acquiring a second goal or chunk delivery-scope lease would
conflict with caller ownership. Heartbeat `SAAS_EMBEDDED_LEASE_STATE` at every phase
where the standalone path heartbeats its goal lease. All task-specific routing,
implementation, QA, tribunal, PR, merge, deployment, rollback, and live-verification
gates below remain mandatory.

```bash
if [ -z "${SAAS_EMBEDDED_CALLER:-}" ]; then
  goal_fingerprint=$(printf '%s' "$resolved_scope_identity" | git hash-object --stdin)
  GOAL_LEASE_KEY="goal-deliver:${goal_fingerprint}"
  GOAL_OWNER_FILE=".startup/leases/.owners/goal-deliver-${goal_fingerprint}.owner"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
    --acquire "$GOAL_LEASE_KEY" --state-dir .startup/leases \
    --owner-file "$GOAL_OWNER_FILE" --ttl-seconds 1800
fi
```

On the standalone path, the owner file is the stable identity across routing, script, founder, QA, tribunal,
push, PR, merge, and deploy processes. If acquisition refuses, mutate neither state nor
Git/GitHub; inspect the live owner and resume its artifacts or stop. After acquisition,
reset `active_role` for founder dispatches. The embedded caller already performed this
under its inherited lease and skips this mutation:

```bash
if [ -z "${SAAS_EMBEDDED_CALLER:-}" ] && [ -f .startup/state.json ]; then
  jq '.active_role = "business-founder-maintain"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

Heartbeat with the exact key and owner file after every route, implementation, check,
tribunal, PR, merge, and deployment phase. Release on success and every handled terminal
failure. Escalating light to deep keeps this same lease; never acquire a second delivery
identity for the retry.

## Step 1.5: Autonomous Light Fast Path (single issue only)

The fast path is available only for one GitHub issue when `--full` is absent.
Everything else continues at Step 2. Write the issue title/body and labels to separate
temporary files, then use the shared semantic classifier:

```bash
route_file="$(mktemp)"
task_file="$(mktemp)"
labels_file="$(mktemp)"
jq -r '[.title, .body, .comments[]?.body] | map(select(. != null)) | join("\n\n")' \
  "$issue_json" > "$task_file"
jq '[.labels[]?.name]' "$issue_json" > "$labels_file"
route_rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-route.sh" classify --mode autonomous \
  --task-file "$task_file" --labels-file "$labels_file" > "$route_file" || route_rc=$?
```

Exit 2 is a hard routing failure. Exit 20 continues at Step 2 with `PROFILE=deep`.
The fast path is accepted only when `profile=light` and `ui_touch=false`; mechanical,
standard, UI, sensitive, ambiguous, and judgment-bearing work all continue at Step 2.
Capture `profile`, `ui_touch`, and the comma-joined reasons, then remove all routing
temporary files.

If the profile is `mechanical`, do not enter founder/chunk planning. Run only the exact
existing repository script named by the issue on a dedicated branch, apply shared
post-diff containment, deterministic checks, `supervisor-commit.sh`, PR/CI, and deploy
gates, and record `surface=script`, `profile=mechanical` progress/terminal events. If
the script or expected output is not objective, set `PROFILE=standard` and continue at
Step 2; never improvise edits or launch a model under the mechanical profile.
The supervisor applies the exact-path role guard and trusted-commit preflight from
`mutation-ownership.md` around this script just as it would around a tech writer.
Under the maintain embedded caller, execute that exact script through the receipt
adapter's authenticated `maintain-attempt.sh` transaction rather than the standalone
branch path.

For an accepted light route, the maintain embedded caller uses the receipt adapter's
`maintain-attempt.sh` transaction and durable transitions; it does not enter the
standalone `tweak-run.sh`, direct merge, checkout, cleanup, or immediate-close path
below. The selected light profile and all applicable common goal predicates remain
unchanged. The following numbered path is standalone only:

1. Set `LIGHT_BRANCH="tweak/<slug>"`, record `LIGHT_BASE_SHA` from
   `origin/$default`, and prepare one minimal unified diff in a temporary file outside
   the repository; do not edit product files directly.
2. Reuse the routing context and invoke the trapped helper:

   ```bash
   export SAAS_RUN_ID="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)"
   export SAAS_PARENT_RUN_ID="$SAAS_INVOCATION_ID"
   export SAAS_COMMAND=goal-deliver
   export SAAS_ROUTING_REASONS="$routing_reasons"
   helper_rc=0
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/tweak-run.sh" \
     --routing-mode autonomous --patch "$patch_file" \
     --message "tweak: <summary> (#<n>)" --mode new-branch \
     --branch "$LIGHT_BRANCH" --parent "$default" --push || helper_rc=$?
   ```

   The helper runs staged-size and shared post-diff containment, preserves commit hooks,
   and rejects any UI or non-light diff. It also restores `active_role` on every exit.
3. If the helper fails, run the verified cleanup below. Exit 20 is a deep escalation;
   do not attempt the light route again.
4. Open a non-draft PR and record the number returned by GitHub. Use `Fixes #<n>`.
   Require at least one reported CI check and poll with
   `scripts/poll-gate.sh --pr "$pr_num"`. Never treat absent checks as green.
5. If push, PR creation, or checks fail or remain absent, run the verified cleanup.
   Continue at Step 2 with a fresh deep attempt only after every cleanup postcondition
   passes. Otherwise stop the goal and release its lease; never launch a deep worker from
   a contaminated branch, open PR, remote branch, or dirty worktree.
6. If every check passes, the supervisor may squash-merge and delete the branch.
   Close the issue, then continue to the existing deployment watch in Step 4. If the merge
   command fails, query that exact PR before doing anything else. A confirmed merged PR
   continues by syncing `$default`; a confirmed unmerged PR follows cleanup; unknown PR
   state stops. A merge failure never directly starts a deep retry.

**Verified light/mechanical cleanup.** This contract also applies to a mechanical branch
failure; set `$LIGHT_BRANCH` to that exact script-attempt branch before it starts.
Identify only the exact attempt branch. Close every open PR for that head and
verify the open-PR query returns an empty list. Delete that exact remote branch when it
exists and verify `git ls-remote --heads origin "refs/heads/$LIGHT_BRANCH"` returns no
ref. Return to `$default`, pull it with `--ff-only`, delete only the exact local attempt
branch, and require both `git branch --show-current == $default` and an empty
`git status --porcelain`. Do not use a broad clean/reset. If any query or postcondition
is unknown or fails, preserve evidence, append a blocked terminal event, release
`$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`, and stop. Only a fully verified cleanup may
transition once to `PROFILE=deep`.

After PR creation, CI, and merge, append goal-level progress events with `pr`, `checks`,
and `merge` status codes. The helper's successful mutation event is only a subphase and
does not mean the goal delivery succeeded.

No founder, model worker, QA, or tribunal launches on an accepted light path. The
supervisor still owns Git, GitHub, checks, merge, and deployment operations.

## Step 2: Plan Into Manageable Chunks (use judgment)

Break the work into **PR-sized chunks** — each a coherent unit that produces one
PR (the `/improve` sweet spot, ~15–30 min of implementation). Order them so any
chunk's dependencies merge first; note which chunks depend on which.

Before planning a direct architecture or implementation request, read and apply
`${CLAUDE_PLUGIN_ROOT}/templates/delivery-scope-contract.md`. The supervisor is the
primary planner and makes one targeted repository-discovery pass.
Do not dispatch a planning role by default. Add exactly one appropriate specialist only when an
independent business, legal, or technical evidence gap can materially change `Done`;
do not ask the investor about choices safely inferred from repository conventions.

For a new product or major pivot, a business-founder planning phase followed by a tech
feasibility check remains available. On Claude Code, use the registered
`saas-startup-team:business-founder-maintain` and one matching tech-founder maintenance
agent. On Codex, use the `business-founder` or `tech-founder` skill in the current
session, or `scripts/codex-run-role.sh` with the classified profile and a task file;
never route to `tech-founder-claude*`. The supervisor owns the final chunk list and
dependency order.

Track the chunks with a **TodoWrite list** (in-context) so progress is visible.
Do not write a state file or build an ordering engine.

For every chunk, attach selected acceptance packs from
`${CLAUDE_PLUGIN_ROOT}/scripts/acceptance-packs.sh --render <pack ids>` to the brief and
final verification. When a selected candidate has no packs, run
`acceptance-packs.sh --select --category <category> --text <need>` and use the result.

## Step 3: Deliver Each Chunk

For each chunk, in dependency order (a chunk is ready once everything it depends
on has merged):

0. **Claim the work unit.** Before dispatch or branch creation:
   ```bash
   if [ -z "${SAAS_EMBEDDED_CALLER:-}" ]; then
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
       --acquire "goal-deliver:${chunk_slug}" \
       --state-dir .startup/leases \
       --owner-file ".startup/leases/.owners/goal-deliver-${chunk_slug}.owner" \
       --ttl-seconds 1800
   fi
   ```
   The maintain embedded caller skips this second delivery-scope lease acquisition and
   continues to use and heartbeat `SAAS_EMBEDDED_LEASE_STATE`; it does not weaken any
   following delivery gate.
   If an active owner exists, inspect its heartbeat, logs, and completion artifact. Resume
   from existing artifacts when possible; replace only with `--replace-stale --reason`
   after recording heartbeat/log evidence.
   Heartbeat after each delivery/tribunal phase and release the chunk lease after merge
   or any handled final blocked/skipped result, always using the same owner file.
1. **Build via `/improve`.** On the standalone path, follow
   `${CLAUDE_PLUGIN_ROOT}/commands/improve.md` in `new-branch` mode off the default
   branch, using the chunk's description as the improvement instruction. This runs
   business → tech → business-QA and opens a PR on `improve/<chunk-slug>`. The maintain
   embedded caller instead uses the loaded receipt adapter for its source transaction,
   one bound PR, and persisted recovery while applying the same acceptance and quality
   requirements.
   Before implementation, identify the root-cause/recurrence class and fix the class,
   with red-before/green-after proof. For bug, monitor, customer, accounting, replay,
   and incident work, add a mechanical regression guard that fails on the old behavior;
   if no durable guard is possible, split/file the gap or use `Refs` instead of silently
   closing it. Apply §Delivery safety invariants for project test-target diagnostics.
2. **Close the tribunal loop** on the PR branch. Load and follow
   `tribunal-review:closing-tribunal-loop`. Run `tribunal-review:tribunal-loop`;
   include this explicit issue-closure question in the review request whenever the PR
   body/title uses `Closes`, `Fixes`, or `Resolves`: **Does this PR satisfy every
   material promise in the full issue body and comments it closes, or only a subset?**
   If the arbiter returns **zero critical and zero high**, the gate is closed
   (leftover medium/low → YAGNI triage: file a follow-up only if real and worth
   acting on, else drop with a PR-body note). While any critical/high remains:
   - **Rounds 1–2:** fix directly (tech founder), push, re-run.
   - **Round 3+:** step-back mode — simplify, descope (remove mechanism + file
     follow-up), or have the arbiter down-rate the class; never guard-pile.
   - **Round 3:** notify the investor without stopping.
   - **Round 5:** stop and escalate to the investor with the standing finding.
   Then **skip the chunks that depend on it** and continue with independent ones.
   Record the latest-head tribunal status as a goal-level progress event; never infer it
   from the implementation worker's exit code.
3. **Issue-closure audit, then merge.** Before merging any PR whose title/body contains
   `Closes`, `Fixes`, or `Resolves`, run:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-closure-audit.sh" --pr "<pr url>"
   ```
   If the audit fails, do not merge. Either implement the missing named surface, add a
   `## Closure audit` PR-body explanation with a follow-up issue for remaining acceptance,
   or change the closing keyword to `Refs #<n>` so GitHub does not close the parent issue.
   Then re-run the audit.

   Merge follows the standing policy + carve-outs (`${CLAUDE_PLUGIN_ROOT}/templates/merge-policy.md`),
   only after the audit passes. Update from the current default, rerun the complete
   latest-HEAD gates, bind `BOUND_SHA` to local HEAD, and require the freshly fetched PR
   `headRefOid` to equal it. On the standalone path, merge atomically with `gh pr merge
   "<pr url>" --match-head-commit "$BOUND_SHA" --squash --delete-branch`; any
   default/head advance restarts final validation. Then close the chunk's issues
   (`gh issue close <n> --comment "Delivered in <pr url>"`) and run
   `git checkout "${default}" && git pull --ff-only`.

   The maintain embedded caller performs none of those direct merge, close, checkout,
   or pull commands. It records the same current-head gates and delegates the pinned
   merge, post-deploy release, delayed close, and crash recovery to the loaded receipt
   adapter. Continue only after the applicable path's verified transition completes.
   Note: if a chunk resolves an incident-labeled issue (`bug`/`monitor`/`customer-issue`)
   the merge is **blocked by the regression-test gate** unless the PR diff adds a test —
   ensure the tech founder's Bug Fix Protocol test landed in the PR (or record
   `Regression-Test: none — <reason>` in the PR body) before merging.
   Append PR/check/merge progress status after the supervisor verifies each gate.

## Step 4: Monitor the Deploy

After the last chunk merges (and at least one merged), watch the run(s) for the
exact final merge commit — never "the latest run", which in a repo with several
`push` workflows can be an unrelated CI/docs/concurrent run reading falsely green:

```bash
merge_sha=$(gh pr view "<final pr url>" --json mergeCommit -q .mergeCommit.oid)
```
If the local config block (`.claude/saas-startup-team.local.md`) has a `deploy:`
section with `workflow: <name>`, pass `--workflow "<name>"` so only the deployment
workflow's matching run counts. Poll with backoff — never a blocking `--watch`:
repeatedly `bash "${CLAUDE_PLUGIN_ROOT}/scripts/poll-gate.sh" --deploy-sha
"$merge_sha" --branch "${default}" [--workflow "<name>"]` — `green`=passed,
`red`=failed, `pending`→`sleep` a 60s backoff doubling to a 480s cap, then re-poll.
A matching run that never appears stays `pending` and fails closed at the budget.
Treat as failed after a 30-minute total budget. Each probe and sleep is its own short Bash call.
Without a pinned workflow, green covers only the runs that exist for the SHA at
probe time — a chained (`workflow_run`-triggered) deployment may not have appeared
yet, so on first green sleep 60s and re-poll once; pin `deploy.workflow` in the
config block when the repo deploys through a chained workflow.

On failure: find the failing matching run's id (`gh run list --branch "${default}"
--json databaseId,headSha,conclusion` filtered to `headSha == $merge_sha`), read
its logs (`gh run view "$run_id" --log-failed`),
dispatch the tech founder to fix on a `deploy-fix/<slug>` branch → open a PR →
close the tribunal loop on it → merge → refresh `merge_sha` from the deploy-fix
PR's `mergeCommit` → re-watch with the new SHA. Repeat until green or you judge
it needs the investor.

For `SAAS_EMBEDDED_CALLER=maintain`, classify deploy failure from the failed command,
logs, concurrent default-branch movement, and health/migration signals. A code
regression is eligible only for the receipt adapter's one causal safe rollback; do not
start a post-merge corrective delivery. Infra, flaky, external-dependency, credential,
migration-data, or low-confidence failure returns `deploy-blocked` and stops further
pass merges. A clearly broken deploy may roll back only this receipt's own merge and
must verify recovery; never revert another actor's commit. A rollback that cannot go
green returns a hard escalation. The adapter records the resulting release or rollback
and canonical outcome for maintain's cooldown/digest handling.

After green, when `scripts/ui-touch.sh --range <pre-run SHA>..HEAD` over this run's merged range prints anything but `no-ui`,
run the post-deploy visual smoke per the post-deploy section of
`${CLAUDE_PLUGIN_ROOT}/skills/ux-tester/references/design-review-leg.md`. A render
regression attributable to a merged chunk → roll it back via `/maintain`'s
`revert/<pr-slug>` block; non-attributable or ambiguous → escalate to the investor.
Append deployment and rollback progress events using only stable status codes.

After the final verified green deployment, the standalone path appends its terminal
event with the root binding and releases `$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`;
a handled blocked/cancelled outcome releases it after recording the
terminal event as well. The embedded receipt adapter instead records live/release
evidence, performs its delayed close when eligible, and finalizes the sole issue outcome;
it heartbeats but never releases its caller's lease. Do not release while a PR, merge-state
query, rollback, or deployment action is still running. If cleanup cannot be verified,
record that blocked outcome and preserve the evidence; standalone releases its goal
lease, while embedded returns blocked without releasing the caller's lease.

```bash
if [ -z "${SAAS_EMBEDDED_CALLER:-}" ]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
    --release "$GOAL_LEASE_KEY" --state-dir .startup/leases \
    --owner-file "$GOAL_OWNER_FILE"
fi
```

## Step 5: Final Report

Before reporting, the standalone path appends one child terminal event per work unit
with `--parent-run-id "$SAAS_INVOCATION_ID"` and its check, QA, tribunal, PR, merge,
deployment, rollback, and outcome status. Every handled CI/deploy failure, blocked
dependency, escalation, or cancellation gets an explicit terminal outcome; a light
helper success never masks a later failure. On the embedded path,
`maintain-delivery.sh finalize` is the sole child `issue-outcome` writer; do not append a
second terminal event from the goal playbook or maintain supervisor.

After all work events and cleanup, the standalone caller appends its one root
`pass-outcome`; the embedded caller returns verified status to `/maintain` without a
root append. Neither caller derives root duration, tokens, or outcome by aggregating
children.

Report to the investor (English): chunks **merged** (PR links), chunks
**blocked/skipped** (reasons + draft-PR links), GitHub issues **filed** for
out-of-scope findings (links), and **deploy status** (green/failed + run link).
Every completed run must include a completion artifact in the PR body or final report:
the market/customer need addressed, what changed, how it was verified, selected
acceptance packs, remaining risks, and any follow-up issues filed. Ask the investor only
for true blockers: missing secrets/credentials, paid external access, destructive
production action, legal approval or regulated claims needing human signoff, or ambiguity
that materially changes customer promise or pricing. Of these, only the narrow
push-blocker set (deploy broken and unrevertable, spend gate, legal — §Blocker vs
non-blocker escalation in `/maintain`) triggers a `notify.sh --blocker` push (per the
rc-handling snippet there: exit 3 = no channel is a silent no-op, but a real send
failure is surfaced to stderr; the run never blocks on it); the rest are parked into the
daily `/digest`. Either way the run continues — never wait on them.

## Communication

Investor-communication language: see `${CLAUDE_PLUGIN_ROOT}/templates/communication.md`
(team lead speaks English for status updates and the final report).
