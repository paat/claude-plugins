---
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
description: Run the show over a queue of work — epic, issue list, discovery goal, or workitem scan — through multi-model worker and reviewer legs with adversarial gates, crash-safe handoffs, and tribunal close-out
argument-hint: "<mission brief: what to achieve> | --resume [handoff-path]"
---

# /multi-model-orchestrator:meta-orchestrate

Load `skills/meta-orchestration/SKILL.md` and execute it for `$ARGUMENTS`.

## Arguments

- `<mission brief>` — free-form: WHAT to achieve. An epic ref, an issue list or query, a goal to
  discover tasks for, or a scan request — plus any priorities, autonomy bounds, stop conditions,
  or provider/model restrictions. HOW is the skill's responsibility.
- `--resume [handoff-path]` — continue from a handoff. Without an explicit path, use the newest
  `handoff-*.md` under `${MMO_HANDOFF_DIR:-.claude/handoffs}` in the target repository.
  Trailing text is pre-answered open decisions and brief deltas.

Reject `--resume` when no handoff exists.

## Preflight deltas vs /orchestrate

- Require `gh` authenticated against the repository's GitHub remote, and that any issues or
  workitems the brief references exist.
- A clean worktree is required only for a fresh start. On resume, the handoff State block is the
  authoritative baseline; unexplained divergence from it is a stop condition, not something to
  clean up.
- Every CLI leg runs in YOLO mode inside the development-container boundary; reviewer mutation
  control lives in prompts and tool lists, exactly as in `/orchestrate`.
