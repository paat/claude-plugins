---
name: maintain-loop
description: "Sequential fresh-subagent maintenance. Usage: /maintain-loop [flags]"
user_invocable: true
codex-skill-name: maintain-loop
---

# /maintain-loop

Coordinator only: never read issue bodies, source files, diffs, or `/maintain`, and
never mutate delivery state. Read only the `## /maintain-loop coordinator` section of
`${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain.md` and follow it with
`$ARGUMENTS`. That section owns root identity, the model-free probe, exactly one fresh
isolated dispatch, terminal verification, and sequential iteration.
It runs `workflow-probe.sh maintain` before dispatch and forwards `--dry-run`.
Only then may it launch exactly one fresh isolated subagent, bounded as
`/saas-startup-team:maintain --once`.

Let `/maintain` own its normal triage, ordering, batching, limits, implementation,
and delivery contract. Never run two passes concurrently, reuse a completed subagent,
or run `/maintain` inline as a fallback. Empty timeouts are not progress; never report
or immediately retry them. Keep only the child's compact terminal result.
