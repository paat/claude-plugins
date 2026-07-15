---
name: maintain-loop
description: "Run sequential maintenance passes in fresh subagents so issue and delivery context never accumulates in the caller. Usage: /maintain-loop [maintain flags]"
user_invocable: true
codex-skill-name: maintain-loop
---

# /maintain-loop

Act only as a thin sequential coordinator. Never read issue bodies, source files,
diffs, or the `/maintain` playbook, and never implement, review, merge, deploy, or
mutate delivery state in this session.

Accept the `/maintain` flags `--dry-run`, `--max-issues`, `--max-merges`,
`--max-pass-minutes`, and `--max-run-minutes`. `--once` means launch at most one
fresh pass. Reject other flags. Always add `--once` to the child invocation.

Repeat sequentially:

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain` with the child
   flags. Exit 3 is a clean no-op: stop without launching a subagent. Exit 4 is a
   blocked environment: report its diagnosis and stop. Any other nonzero exit is
   a failure.
2. On exit 0, launch exactly one fresh isolated subagent. Its complete task is:

   > Run `/saas-startup-team:maintain --once` to termination with forwarded flags. Let
   > `/maintain` own its normal triage, ordering, batching, limits, implementation,
   > QA, tribunal, merge, deployment, live verification, closure, and durable state.
   > Return issue states, PRs, merge/deploy/live status, one blocker, and pass status.
   > An `issue-blocked` state requires removing `maintain:claimed`, recording terminal
   > state, and persisting an active cooldown. Return `pass-complete` after success or a
   > per-pass limit, including handled issue-local blocks; return `pass-blocked` for
   > preflight, lease/state/cleanup, or unresolved live work.

3. Wait for that subagent to terminate. Never run two passes concurrently, reuse a
   completed subagent, or send it follow-up work. If fresh isolated dispatch is not
   available or its terminal state is unknown, fail closed; never run `/maintain`
   inline as a fallback.
4. Keep only its compact terminal result. Under outer `--once` or `--dry-run`, stop after this pass.
   Otherwise return to step 1 after `pass-complete`; the probe excludes cooled or
   parked issues. Stop on outer run limit, no-work, `pass-blocked`, failed
   dispatch/pass, or unknown scope.
