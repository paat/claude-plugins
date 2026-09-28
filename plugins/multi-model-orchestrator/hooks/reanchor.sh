#!/usr/bin/env bash
# SessionStart(compact): point a compacted meta-orchestrator back at its skill and newest handoff.
cat >/dev/null
dir="${CLAUDE_PROJECT_DIR:-$PWD}/${MMO_HANDOFF_DIR:-.claude/handoffs}"
handoff=$(ls -t "$dir"/handoff-*.md 2>/dev/null | head -n 1)
[ -n "$handoff" ] && [ -n "$(find "$handoff" -mmin -1440)" ] || exit 0
printf '%s\n' "If this session was running /multi-model-orchestrator:meta-orchestrate: invoke Skill('multi-model-orchestrator:meta-orchestration'), re-read $handoff, and continue as --resume. The compaction summary is not authoritative."
