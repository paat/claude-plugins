---
name: maintain-loop
description: Codex-first GitHub issue delivery loop with a source-only worker and supervisor-owned delivery gates. Usage: /maintain-loop [--once] [--dry-run] [--issue N] [--label LABEL] [--max-issues N] [--max-merges N] [--max-run-minutes N]
user_invocable: true
---

# /maintain-loop - Fresh-Context Delivery Router

Use this after `/maintain` has produced deliverable issues. The calling session is
the supervisor and only delivery-state mutation owner. It owns queue and issue
reads, leases, worktrees, branches, `.startup/` state, deterministic checks,
commits, browser QA, tribunal, GitHub state, merges, deployment, live verification,
rollback, receipts, results, counters, and authoritative events.

Each implementation attempt is a fresh
`scripts/codex-run-role.sh --role tech-founder --profile "$PROFILE"` process. The
worker may edit only task-required product source and tests in its assigned
worktree. It must not stage, commit, mutate GitHub or delivery state, run browser
QA or tribunal, deploy, roll back, or write authoritative artifacts. The
supervisor never patches product source itself. Only one source writer runs at a
time; browser QA and tribunal are read-only. A source defect always returns to a
fresh tech-founder attempt.

Be token-frugal. Load `references/workflows/routing-telemetry.md` once. Use helper
interfaces without reading their implementations unless a failed call needs a
targeted diagnostic range of at most 20 lines.

## Detailed protocol loading

Detailed contracts live in
`${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain-loop-protocol.md`.
Never read that file wholesale. Locate a requested `##` heading, read only through the next
`##` heading, and load each section at most once per invocation. This path works
on Claude Code and Codex; Codex resolves `${CLAUDE_PLUGIN_ROOT}` to the installed
plugin root.

Parse `$ARGUMENTS` before mutation: `--dry-run`, `--once`, `--issue N`,
`--label LABEL`, `--max-issues N`, `--max-merges N`, and `--max-run-minutes N`.
Reject invalid or conflicting flags.

Load and execute protocol sections as follows:

1. Load `Ownership invariant`, then `Flags and preflight`. Scheduled runners have
   already called `workflow-probe.sh maintain-loop`, but its launch-time preflight
   remains authoritative. `--dry-run` follows the terminal read-only branch in
   that section and stops before normal setup.
2. On a normal run, load `Delivery receipt`, call `maintain-delivery.sh pending`,
   and resume its one pending receipt before selecting new work. A local receipt,
   never a public marker alone, is lifecycle authority.
3. For new work, load `Queue and routing`; build the full filtered queue through
   `maintain-queue.sh` and route one eligible issue at a time.
4. Before implementation, load `Source attempt and containment`. Use
   `maintain-attempt.sh` for reset, base-check, and the continuous authenticated
   deliver transaction. Exit 20 alone loads `Persistent escalation and cleanup`;
   an accepted persistent cleanup receipt permits one deep restart.
5. After an accepted commit, load `Supervisor delivery gates` and execute its
   checks, QA, non-closing PR, prospective audit, tribunal, merge, deploy/live,
   explicit-close, and rollback gates in order. Resume a receipt at its exact
   recorded gate; never infer a completed transition. Persist
   `authorize-merge --role normal` before merge. Post-merge recovery is rollback-or-stop.
6. On every handled terminal path, load `Authoritative outcome`. Finalize through
   `maintain-delivery.sh`, clean the persisted lease set before choosing aggregate
   status, append the one terminal pass outcome, and return immediately.

## Non-negotiable contracts

- `maintain-delivery.sh` is the only delivery lifecycle writer. A receipt is bound
  to one issue generation, one normal PR, exact authorization evidence, and at
  most one rollback action. Malformed, missing, contradictory, or untrusted state
  fails closed.
- Mint one run ID per invocation. Hold the shared/legacy/worktree lease set for
  every mutation and long operation. Lease or cleanup failure terminates the pass;
  no terminal path restarts setup or continues the queue.
- `--dry-run` acquires no lease, writes no state, launches no worker, mutates no
  worktree/ref/label/event, and never advances a delivery receipt.
- A worker result is never delivery success. The supervisor independently proves
  containment, exact checks, QA, current-head tribunal, merge ancestry, merge-SHA
  deployment, live assertions, prospective closure audit, claim-label removal,
  explicit close, and final receipt state.
- Normal PRs are non-closing. Issue closure occurs only after deploy and live QA,
  from a durable receipt-owned close intent. Crash recovery resumes only the exact
  receipt transition and performs result/event finalization exactly once.
- Any source or validation-fact change invalidates downstream evidence. Source
  repair uses a fresh writer and reruns containment, checks, commit, QA, closure
  audit, and tribunal as required by the protocol.
- Rollback is recovery, never success: it cannot contain `fixed:` or increment the
  delivered count. Unresolved deploy/live/rollback state blocks further work.
- Events contain status and stable routing codes only, never issue text, prompts,
  URLs, repository identity, paths, or diffs. No-op queues launch no worker and
  emit no worker event.

Under `--once`, stop after one terminal issue. Otherwise stop on lease loss,
unexplained queue state, malformed/missing evidence, cap/time/budget exhaustion,
tribunal ceiling, cleanup failure, or unresolved deploy/live/rollback. Report only
queue count, issue states, PR numbers, deploy/live status, and actionable blockers;
keep raw evidence local.
