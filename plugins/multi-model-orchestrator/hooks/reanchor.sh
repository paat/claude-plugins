#!/usr/bin/env bash
# SessionStart compact: send a meta-orchestrator back to its skill and the run's handoff when a
# handoff was updated within 24h.
input=$(cat)
source=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
dir="${MMO_HANDOFF_DIR:-.claude/handoffs}"
case "$dir" in /*) ;; *) dir="${CLAUDE_PROJECT_DIR:-$PWD}/$dir" ;; esac
skill="Skill('multi-model-orchestrator:meta-orchestration')"
[ "$source" = compact ] || exit 0

handoff=$(ls -t "$dir"/handoff-*.md 2>/dev/null | head -n 1)
[ -n "$handoff" ] && [ -n "$(find "$handoff" -mmin -1440)" ] || exit 0
printf '%s\n' "If this session was running /multi-model-orchestrator:meta-orchestrate: invoke $skill, re-read the handoff this run was using (the summary names it; newest here is \"$handoff\"), and continue as --resume. The compaction summary is not authoritative."
