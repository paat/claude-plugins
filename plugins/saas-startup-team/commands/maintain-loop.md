---
name: maintain-loop
description: "Scheduler dispatcher for maintain ticks. Usage: /maintain-loop [--once] [--shadow|--mutate]"
argument-hint: "[--once] [--dry-run] [--shadow|--mutate] [limits]"
user_invocable: true
codex-skill-name: maintain-loop
transitional: true
---

# /maintain-loop

Expeditor for one bounded tick. never read issue bodies, source files, or diffs.

1. When a legacy pending receipt exists, run `workflow-probe.sh maintain` then
   launch exactly one fresh isolated subagent as `/saas-startup-team:maintain --once`.
2. Otherwise prefer v3:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --shadow \
     --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
   ```
   Forward `--dry-run` as shadow.

never run two passes concurrently. no inline as a fallback. Keep only the child's compact terminal result. Empty timeouts are not progress or immediately retry them. Completed subagent identities are not reused. Normal triage, ordering, batching, limits, implementation remain inside `/maintain`.

Legacy coordinator detail: `${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain.md`.
