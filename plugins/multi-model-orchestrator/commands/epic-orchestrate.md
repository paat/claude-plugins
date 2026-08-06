---
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
description: Drive a GitHub epic through multi-model worker and reviewer legs with adversarial gates, crash-safe handoffs, and tribunal close-out
argument-hint: "<epic issue ref> | --resume [handoff-path]"
---

# /multi-model-orchestrator:epic-orchestrate

Load `skills/epic-orchestration/SKILL.md` and execute it for `$ARGUMENTS`.

## Arguments

- `<epic issue ref>` — a GitHub epic issue (number or URL) starts a fresh epic.
- `--resume [handoff-path]` — continue from a handoff. Without an explicit path, use the newest
  `handoff-*.md` under `${MMO_HANDOFF_DIR:-.claude/epic-handoffs}` in the target repository.
  Text after the flag and path is treated as pre-answered open decisions for the handoff.

Reject a call that supplies both an epic ref and `--resume`, and a resume when no handoff exists.

## Preflight deltas vs /orchestrate

- Require `gh` authenticated against the repository's GitHub remote, and that the epic issue
  (fresh start) or handoff file (resume) exists.
- A clean worktree is required only for a fresh start. On resume, the handoff State block is the
  authoritative baseline; unexplained divergence from it is a stop condition, not something to
  clean up.
- Every CLI leg runs in YOLO mode inside the development-container boundary; reviewer mutation
  control lives in prompts and tool lists, exactly as in `/orchestrate`.
