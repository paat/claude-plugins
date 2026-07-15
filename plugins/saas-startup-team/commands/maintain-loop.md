---
name: maintain-loop
description: "Run sequential maintenance passes in fresh subagents so issue and delivery context never accumulates in the caller. Usage: /maintain-loop [maintain flags]"
user_invocable: true
codex-skill-name: maintain-loop
---

# /maintain-loop

Act only as a thin sequential coordinator. Never read issue bodies, source files,
diffs, the `/maintain` playbook, or mutate delivery state.

Accept the `/maintain` flags `--dry-run`, `--max-issues`, `--max-merges`,
`--max-pass-minutes`, and `--max-run-minutes`. `--once` means launch at most one
fresh pass. Reject other flags. Always add `--once` to the child invocation.

Repeat sequentially:

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain` with child flags.
   Exit 3 is a clean no-op; exit 4 reports blocked; other nonzero exits fail.
2. On exit 0, under `--dry-run` do not mint. Otherwise mint once:

   ```bash
   LEASE_RUN_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)
   ```

   Then launch exactly one fresh isolated subagent:

   > Invoke `/saas-startup-team:maintain --once` with the forwarded flags. On a
   > normal pass add the exact `--lease-run-id <LEASE_RUN_ID>`. Let
   > `/maintain` own its normal triage, ordering, batching, limits, implementation,
   > QA, tribunal, merge, deployment, live verification, closure, and durable state.
   > Return only after termination with issue states, PRs, merge/deploy/live status,
   > and at most one actionable blocker.

3. Wait for termination. Never run two passes concurrently, reuse a completed subagent,
   or send follow-up work. Unavailable dispatch or unknown terminal state fails closed;
   never run `/maintain` inline as a fallback. An unknown-terminal child is never reaped.
4. After a normal child is confirmed terminal, run exact-ID
   `maintain-leases.sh reap-terminal`, then `maintain-leases.sh available`, with `--repo-root
   "$(git rev-parse --show-toplevel)"` and the reap with `--run-id "$LEASE_RUN_ID"`.
   Both must pass before another pass; otherwise stop. Under `--dry-run`, never mint or reap a lease.
5. Keep only its compact terminal result. Stop on no-work, blocked, failed, or
   human-action-required. Under outer `--once` or `--dry-run`, stop after this pass.
   Otherwise return to step 1 with a new subagent.
