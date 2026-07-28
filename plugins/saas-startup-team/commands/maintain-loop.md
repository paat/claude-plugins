---
name: maintain-loop
description: "Scheduler for maintain ticks. Usage: /maintain-loop [--once] [--shadow|--mutate]"
argument-hint: "[--once] [--dry-run] [--shadow|--mutate] [limits]"
user_invocable: true
codex-skill-name: maintain-loop
transitional: true
---

# /maintain-loop

Expeditor for one tick. never read issue bodies, source files, or diffs.

1. Probe: `workflow-probe.sh maintain` (exit 3 is no-op). Legacy receipts → once `legacy-drain.sh drain --repo-root "$(git rev-parse --show-toplevel)" --apply`.
2. Prefer v3: `maintain-v3.sh tick --shadow --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees`. `--dry-run`→shadow; `--mutate` after agreement.
3. When work available, launch exactly one fresh isolated subagent as `/saas-startup-team:maintain --once`. never run two passes concurrently. no inline as a fallback. Keep only the child's compact terminal result. Empty timeouts are not progress or immediately retry them. Completed subagent identities are not reused.

Normal triage, ordering, batching, limits, implementation remain inside `/maintain`. `--once` launches at most one child. Coordinator: `references/workflows/maintain.md`.
