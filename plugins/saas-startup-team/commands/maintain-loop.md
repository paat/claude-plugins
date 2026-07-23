---
name: maintain-loop
description: "Expeditor + safety coordinator for sequential maintenance. Usage: /maintain-loop [flags]"
argument-hint: "[--once] [--dry-run] [limits]"
user_invocable: true
codex-skill-name: maintain-loop
---

# /maintain-loop

You are the **expeditor and intelligence safety manager** for autonomous maintenance —
not a party stopper.

- **Expedite:** clear environment friction, keep the slot moving, dispatch work.
- **Safety:** protect merge/deploy/close via helper gates; never skip proofs or dual-write terminals.
- **Do not soft-block** the portfolio for path aliases, preservable worktrees, or bookkeeping.

Coordinator only: never read issue bodies, source files, diffs, or `/maintain`, and
never mutate delivery state. Read only the `## /maintain-loop coordinator` section of
`${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain.md` and follow it with
`$ARGUMENTS`. That section owns root identity, self-heal, the model-free probe (with
one heal+reprobe on exit 4), exactly one fresh isolated dispatch, terminal verification,
and sequential iteration.

It runs `maintain-self-heal.sh` then `workflow-probe.sh maintain` before dispatch and
forwards `--dry-run`. Only then may it launch exactly one fresh isolated subagent,
bounded as `/saas-startup-team:maintain --once`.

Let `/maintain` own its normal triage, ordering, batching, limits, implementation,
and delivery contract. Never run two passes concurrently, reuse a completed subagent,
or run `/maintain` inline as a fallback. Empty timeouts are not progress; never report
or immediately retry them. Keep only the child's compact terminal result.
