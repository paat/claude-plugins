---
name: maintain-loop
description: "Sequential fresh-subagent maintenance. Usage: /maintain-loop [flags]"
user_invocable: true
codex-skill-name: maintain-loop
---

Coordinator: Never read issue bodies, source files, diffs, or `/maintain`;
never mutate delivery state.

Accept `/maintain` flags `--dry-run`, `--max-issues`, `--max-merges`,
`--max-pass-minutes`, and `--max-run-minutes`. `--once` means launch at most one
fresh pass. Reject others; always add child `--once`.

Repeat sequentially:

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain` with child flags.
   Exit 3 is a clean no-op, 4 is blocked, and other nonzero fails.
2. On exit 0, skip minting under `--dry-run`; otherwise mint once:

   ```bash
   LEASE_RUN_ID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)
   ```

   Then launch exactly one fresh isolated subagent:

   > Run `/saas-startup-team:maintain --once` with forwarded flags. On a normal pass
   > add exact `--lease-run-id <LEASE_RUN_ID>`. Let
   > `/maintain` own its normal triage, ordering, batching, limits, implementation,
   > QA, tribunal, merge, deployment, live verification, closure, and durable state.
   > Return issue/PR, merge/deploy/live, one blocker, and pass status.
   > `issue-blocked` requires removing `maintain:claimed`, recording terminal state,
   > and persisting an active cooldown. Return `pass-complete` after success or a
   > per-pass limit, including issue-local blocks; return `pass-blocked` for
   > preflight, lease/state/cleanup, or unresolved live work.

3. Wait. Never run two passes concurrently, reuse a completed subagent, or send
   follow-ups. Failed dispatch or unknown state fails closed; never run
   `/maintain` inline as a fallback. An unknown-terminal child is never reaped.
4. For a confirmed-terminal normal child, run `maintain-leases.sh reap-terminal`
   with `--run-id "$LEASE_RUN_ID"`, then `maintain-leases.sh available`; pass each
   `--repo-root "$(git rev-parse --show-toplevel)"`. Both must pass to continue.
   Under `--dry-run`, never mint or reap a lease.
5. Keep only its compact terminal result. Under outer `--once` or `--dry-run`, stop after this pass.
   Otherwise return to step 1 after `pass-complete`; the probe excludes cooled/parked
   issues. Stop on outer limit, no-work, `pass-blocked`, failed dispatch/pass, or unknown scope.
