---
name: maintain-loop
description: Codex-first GitHub issue delivery loop with a source-only worker and supervisor-owned delivery gates. Usage: /maintain-loop [--once] [--dry-run] [--issue N] [--label LABEL] [--max-issues N] [--max-merges N] [--max-run-minutes N]
user_invocable: true
---

# /maintain-loop - Fresh-Context Delivery Playbook

Use this after `/maintain` has produced deliverable issues. Scheduled runners call
`scripts/workflow-probe.sh maintain-loop` before loading this file; exit 3 is a
model-free no-op. Load `references/workflows/routing-telemetry.md` once.

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

## Flags and preflight

- `--dry-run`: list the eligible queue and profiles without acquiring leases,
  creating a worktree, or launching a worker.
- `--once`: set `MAX_ISSUES=1`.
- `--issue N`, `--label LABEL`: restrict queue selection.
- `--max-issues N`: delivery cap; unset means no issue-count cap.
- `--max-merges N`: forward-merge cap, default `5`. A single emergency rollback
  may exceed it only to restore production, then the pass stops.
- `--max-run-minutes N`: pass wall-clock cap, default `120`; `0` is unlimited.

Run `scripts/health-preflight.sh --require-gh --require-codex --check-sync` and
require its `codex:worker-shell` smoke check. Require `jq`, `flock`, Playwright or
the project's existing Playwright runner, and both tribunal-review skills. Do not
install dependencies during a pass. Resolve the default branch with the shared
repository mechanism — `default=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/default-branch.sh")` —
and stop if it cannot resolve; do not assume a conventional branch name.

Mint one `RUN_ID`, then acquire pass and worktree single-flight leases before
creating or resetting the dedicated `.worktrees/maintain-loop` worktree. Persist
each owner token in a separate ignored owner file so heartbeat and release work
from different shell PIDs. An active owner stops the pass. Replace a proven-stale
owner only through `single-flight.sh --replace-stale --reason <specific reason>`.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
RUN_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)
LEASE_DIR="$REPO_ROOT/.startup/leases"
PASS_OWNER="$LEASE_DIR/.owners/maintain-loop-pass-$RUN_ID.owner"
WT_OWNER="$LEASE_DIR/.owners/maintain-loop-worktree-$RUN_ID.owner"
WT="$REPO_ROOT/.worktrees/maintain-loop"
WT_KEY="maintain-loop:worktree:$(printf '%s' "$WT" | cksum | awk '{print $1}')"
GUARDIAN_PID_FILE="$LEASE_DIR/.owners/maintain-loop-$RUN_ID.guardian.json"
HEARTBEAT_FAILED="$REPO_ROOT/.startup/maintain-loop/$RUN_ID-heartbeat-failed"
RUN_STATE="$REPO_ROOT/.startup/maintain-loop/current-run.json"
PASS_ACQUIRED=0 WT_ACQUIRED=0 SETUP_COMPLETE=0
cleanup_failed_setup() {
  [ "$SETUP_COMPLETE" -eq 0 ] || return 0
  [ "$WT_ACQUIRED" -eq 0 ] || bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
    --release "$WT_KEY" --state-dir "$LEASE_DIR" --owner-file "$WT_OWNER" >/dev/null || true
  [ "$PASS_ACQUIRED" -eq 0 ] || bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
    --release maintain-loop:pass --state-dir "$LEASE_DIR" --owner-file "$PASS_OWNER" >/dev/null || true
}
trap cleanup_failed_setup EXIT

bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" --acquire maintain-loop:pass \
  --state-dir "$LEASE_DIR" --owner-file "$PASS_OWNER" --ttl-seconds 900
PASS_ACQUIRED=1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" --acquire "$WT_KEY" \
  --state-dir "$LEASE_DIR" --owner-file "$WT_OWNER" --ttl-seconds 900
WT_ACQUIRED=1
mkdir -p "$(dirname "$RUN_STATE")"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lease-guardian.sh" start \
  --state-dir "$LEASE_DIR" --pid-file "$GUARDIAN_PID_FILE" \
  --failure-file "$HEARTBEAT_FAILED" --interval-seconds 60 --max-seconds 14400 \
  --lease maintain-loop:pass "$PASS_OWNER" --lease "$WT_KEY" "$WT_OWNER"
jq -n --arg run_id "$RUN_ID" --arg repo_root "$REPO_ROOT" --arg lease_dir "$LEASE_DIR" \
  --arg pass_owner "$PASS_OWNER" --arg wt_owner "$WT_OWNER" \
  --arg wt_key "$WT_KEY" --arg guardian "$GUARDIAN_PID_FILE" --arg failure "$HEARTBEAT_FAILED" \
  '{schema_version:1,run_id:$run_id,repo_root:$repo_root,lease_dir:$lease_dir,
    pass_owner:$pass_owner,wt_owner:$wt_owner,
    wt_key:$wt_key,guardian_pid_file:$guardian,failure_file:$failure}' > "$RUN_STATE"
SETUP_COMPLETE=1
trap - EXIT
```

Before and after every worker, check, GitHub mutation, merge, deploy poll, and
live verification, read `current-run.json`, run `lease-guardian.sh check`, and
synchronously heartbeat both leases with their persisted owner files.
Never rely on shell variables or traps surviving a Bash tool call. On every handled success,
failure, cancellation, or signal path, stop the guardian, release both leases with
the persisted owner files, and remove `current-run.json`. If the supervisor dies
unhandled, the guardian has a hard lifetime; afterward the normal lease TTL makes
the abandoned owners replaceable rather than immortal.

Use the persisted state, not reconstructed tokens, for each boundary and terminal
cleanup:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
RUN_STATE="$REPO_ROOT/.startup/maintain-loop/current-run.json"
LEASE_DIR=$(jq -r .lease_dir "$RUN_STATE")
GUARDIAN_PID_FILE=$(jq -r .guardian_pid_file "$RUN_STATE")
HEARTBEAT_FAILED=$(jq -r .failure_file "$RUN_STATE")
PASS_OWNER=$(jq -r .pass_owner "$RUN_STATE")
WT_OWNER=$(jq -r .wt_owner "$RUN_STATE")
WT_KEY=$(jq -r .wt_key "$RUN_STATE")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lease-guardian.sh" check \
  --pid-file "$GUARDIAN_PID_FILE" --failure-file "$HEARTBEAT_FAILED"
```

On a terminal path, after loading the same fields, require this cleanup:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lease-guardian.sh" stop \
  --pid-file "$GUARDIAN_PID_FILE" --failure-file "$HEARTBEAT_FAILED"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" --release "$WT_KEY" \
  --state-dir "$LEASE_DIR" --owner-file "$WT_OWNER"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" --release maintain-loop:pass \
  --state-dir "$LEASE_DIR" --owner-file "$PASS_OWNER"
rm -f "$RUN_STATE"
```

Fetch `origin/<default>` and create or reset the detached worktree only while its
lease is held. Exclude `.worktrees/` through `.git/info/exclude`. The supervisor,
not the worker, creates `issue/<N>-<slug>` from the current remote default.

## Queue and routing

Build the queue only with `scripts/maintain-queue.sh`; pass `--issue`, `--label`,
and `.startup/maintain/blocked.jsonl` when present. Exclude `needs-human`,
`maintain:blocked`, `epic`, open-PR claims, and unresolved explicit dependencies.
Order dependency-ready issues by severity then age. A zero queue is valid only
when the builder accounts for every candidate under `excluded`; otherwise fail.

For each issue, the supervisor reads its current title, body, labels, comments,
and linked PR state. Put task text and labels in temporary files, classify with
`delivery-route.sh classify --mode autonomous`, then delete the temporary files.
Exit 2 stops the pass; exit 20 selects `deep`. Autonomous `light` additionally
requires `ui_touch=false`. Mechanical work runs only an exact existing script
with objective output; uncertainty becomes `standard`.

Write the attempt prompt under the ignored primary path
`.startup/maintain-loop/prompts/<RUN_ID>/issue-<N>-attempt-<A>.md`. Include the
issue acceptance criteria, profile, base SHA, assigned worktree, and a narrow
source/test mutation contract. Do not put issue text or the prompt in events.

## Source attempt and containment

For each attempt, the supervisor fetches default, records `BASE_SHA`, resets the
worktree, creates the local issue branch, and confirms no open PR or remote branch
claims it. Record HEAD, branch, index tree, state fingerprint, and relevant refs.
Then launch exactly one writer:

```bash
MUTATION_AUTH=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutation-auth-token.sh")
ROLE_GUARD=$(git -C "$WT" rev-parse --git-path \
  "saas-startup-team/role-$RUN_ID-$ATTEMPT.json")
role_guard=(bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh"
  --repo-root "$WT" --snapshot "$ROLE_GUARD" --auth-stdin)
for path in "${ROLE_ALLOWED_PATHS[@]}"; do role_guard+=(--allow "$path"); done
"${role_guard[@]}" <<<"$MUTATION_AUTH"
COMMIT_TRUST=$(git -C "$WT" rev-parse --git-path \
  "saas-startup-team/commit-$RUN_ID-$ATTEMPT.json")
commit_trust=(bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh"
  --repo-root "$WT" --snapshot-trust "$COMMIT_TRUST"
  --auth-stdin)
for path in "${ROLE_ALLOWED_PATHS[@]}"; do commit_trust+=(--allow "$path"); done
"${commit_trust[@]}" <<<"$MUTATION_AUTH"
(cd "$WT" && env SAAS_RUN_ID="$RUN_ID" SAAS_ATTEMPT="$ATTEMPT" \
  SAAS_COMMAND=maintain-loop SAAS_PHASE=implementation \
  SAAS_ROUTING_REASONS="$ROUTING_REASONS" \
  SAAS_AGENT_EVENTS_FILE="$REPO_ROOT/.startup/runs/agent-events.jsonl" \
  SAAS_CODEX_LOG_DIR="$REPO_ROOT/.startup/runs/codex" \
  CODEX_SANDBOX=workspace-write \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run-role.sh" \
    --role tech-founder --profile "$PROFILE" --task-file "$PROMPT")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh" \
  --repo-root "$WT" --verify "$ROLE_GUARD" --auth-stdin <<<"$MUTATION_AUTH"
```

Always verify `ROLE_GUARD`, including after worker failure, before inspecting or
resetting the attempt. The authenticated guard mechanically rejects changes outside
the exact task-required source/test paths and verifies HEAD, branch, index, refs,
Git configuration, hooks, ignored files, and `.startup/state.json`. Also reject
GitHub state, source-free success, generated runtime artifacts in the worktree,
unrelated docs/config, and all worker-authored commits. On failure, reset only this
worktree and stop or launch a fresh writer with a focused fix task; never patch in
the supervisor.

The supervisor verifies the approved-path boundary and runs
`delivery-route.sh check-diff --base "$BASE_SHA"` on the working tree. Exit 2 fails closed;
only `supervisor-commit.sh` stages the accepted candidate, in its disposable clone.
For an autonomous light attempt, continuation requires exit 0, `profile=light`,
and `ui_touch=false`. A deep result from a lower profile permits exactly one
restart at `deep` and only through the escalation protocol below. A second
escalation is failure.

## Persistent escalation and cleanup

Before cleanup, the supervisor atomically writes
`.startup/maintain-loop/escalations/<RUN_ID>/issue-<N>-attempt-<A>.json` in the
primary ignored checkout. It contains only schema version, run ID, numeric issue,
attempt, base SHA, branch, from/to profiles, routing reason codes, timestamp, and
cleanup booleans. It is never placed in or deleted with the disposable worktree.

```bash
ESCALATION="$REPO_ROOT/.startup/maintain-loop/escalations/$RUN_ID/issue-$N-attempt-$ATTEMPT.json"
```

The supervisor then closes every open PR for the branch, deletes the remote
branch if present, resets the local branch/worktree to `BASE_SHA`, removes its
untracked files, and independently re-queries GitHub and `git ls-remote`. Update
the artifact atomically to record `open_pr=false`, `remote_branch=false`,
`head_at_base=true`, and `worktree_clean=true`. Do not start the deep attempt
unless the persistent artifact exists, validates, and all four facts are true.
Keep queue eligibility unchanged. Set `ESCALATED=1`, increment `ATTEMPT`, and
restart once with `PROFILE=deep`; never perform another lower-to-deep restart.

## Supervisor delivery gates

After containment, the supervisor performs these steps in order:

1. Run the project deterministic check from the recorded base and keep its exact
   command/status evidence locally. Commit only through
   `scripts/supervisor-commit.sh --repo-root "$WT" --message "$COMMIT_MESSAGE"
   --check "$CHECK_SCRIPT" --trust-receipt "$COMMIT_TRUST"
   --auth-stdin <<<"$MUTATION_AUTH"`;
   it owns staging, staged-size validation, hooks, and the commit. Never use
   `--no-verify`. Confirm the committed tree equals the checked tree.
2. Run Playwright acceptance QA directly in the supervisor at desktop and 375px,
   with console errors and task assertions. Snapshot/verify the product state
   around QA with `delivery-mutation-guard.sh`; browser evidence lives only in
   ignored primary state. If not browser-visible, record
   `Business-founder Playwright QA: not applicable - <reason>`.
3. The supervisor pushes the branch, opens or updates one PR with `Closes #N`,
   and runs `issue-closure-audit.sh`. The PR body states recurrence class,
   red-before/green-after proof, durable guard, QA evidence, and risk.
4. Run `tribunal-review:closing-tribunal-loop` from the supervisor as a read-only
   review/arbitration gate. Set caller identity from the actual context. Its
   verdict must cover the current PR head and diff with zero critical/high
   findings. A finding that needs source changes returns to a fresh tech-founder;
   then the supervisor rechecks, commits, pushes, reruns browser QA and closure
   audit, and restarts tribunal. Any HEAD or validation-fact change invalidates
   the prior verdict.
5. Re-fetch default, enforce merge budget, and independently read the PR. Require
   a concrete numeric `PR_NUMBER`, state `OPEN`, expected base branch, local
   `PR_HEAD_SHA`, matching remote `headRefOid`, current tribunal SHA, successful
   required check runs for that SHA, and
   `git merge-base --is-ancestor "origin/$default" "$PR_HEAD_SHA"`. Only then may
   the supervisor run `gh pr merge "$PR_NUMBER" --squash --delete-branch`.
6. Re-read the PR and require state `MERGED` plus a concrete `MERGE_SHA`. Fetch
   default and require `git merge-base --is-ancestor "$MERGE_SHA" "origin/$default"`.
   Count a merge only after this proof.
7. Select a deploy run whose `headSha` equals `MERGE_SHA`; never trust "latest".
   Poll its concrete run ID with `scripts/poll-gate.sh --run "$DEPLOY_RUN_ID"` and
   require a successful conclusion. Then run the acceptance smoke against the
   configured live URL with Playwright and store timestamped assertion evidence.
   Missing URL, mismatched SHA, missing run, inconclusive deploy, or failed live
   QA is not success.

On deploy/live failure, stop new issue work. If the loop's merge is clearly the
cause and forward budget remains, use a fresh tech-founder for a minimal fix and
repeat every gate. Otherwise the supervisor reverts only this pass's merge,
verifies the rollback PR/SHA is on default, waits for the rollback-SHA deploy,
reruns live QA, records `merge_budget_overage:rollback` when necessary, and stops.
Infra, credentials, external dependency, migration-data, ambiguous, unresolved
deploy/live, or failed rollback remains blocked/failure. Never emit success,
`fixed:`, or increment the delivered count for a rolled-back or unresolved issue.

## Authoritative outcome

The supervisor writes the only result artifact under ignored primary state:
`.startup/maintain-loop/runs/<RUN_ID>/issue-<N>.md`. Success requires all of:

- `fixed:PR#<number>`, `pr_number:<number>`, `pr_head_sha:<sha>`,
  `merge_sha:<sha>`, and `default_ancestry:passed`;
- `checks:passed` plus concrete local/CI check evidence tied to `pr_head_sha`;
- `qa:passed|not_applicable` and immutable evidence/reason;
- `tribunal:passed` and verdict SHA equal to `pr_head_sha`;
- `pr:merged`, `merge:merged`, and `merge_count:<N>` within budget;
- `deployment:passed`, deploy run ID and head SHA equal to `merge_sha`;
- `live_qa:passed` with target source, timestamp, and Playwright assertions;
- `rollback:not_run` and `outcome:success`.

Parse and independently re-query those facts before writing `fixed:`, adding to
`MERGES_USED`, incrementing `ISSUES_DELIVERED`, or appending the authoritative
terminal `agent-events.sh` event. Events contain status codes and routing reasons,
never issue text, URLs, paths, repository identity, prompts, or diffs. Worker
launcher events prove process execution only. An unhandled interruption retains
the launcher's explicit incomplete record; handled interruption or failure adds a
supervisor `cancelled` or `failure` terminal event. No-op queues launch no worker
and emit no worker event.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" append \
  --events "$REPO_ROOT/.startup/runs/agent-events.jsonl" \
  --run-id "$RUN_ID" --command maintain-loop --phase issue-outcome \
  --surface script --profile "$PROFILE" --writer-id "supervisor-$RUN_ID" \
  --attempt "$ATTEMPT" --event-type completed --base-sha "$BASE_SHA" \
  --result-sha "$MERGE_SHA" --checks passed --qa "$QA_STATUS" \
  --tribunal passed --pr merged --merge merged --deployment passed \
  --rollback not_run --outcome success
```

Add each routing reason with `--routing-reason <stable-code>`; never use task text.
For any nonsuccess path, substitute the observed status codes and terminal
`failure`, `blocked`, `cancelled`, or `escalated` outcome before stopping.

Stop on lease loss, unexplained queue state, malformed/missing escalation or
result evidence, exhausted cap/time/budget, hard tribunal ceiling, failed cleanup,
or any unresolved deploy/live/rollback. Under `--once`, stop after one terminal
issue result. Report only queue count, issue states, PR numbers, deploy/live
status, and actionable blockers; keep raw evidence local.
