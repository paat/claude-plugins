#!/usr/bin/env bash
# SessionStart: send a meta-orchestrator back to its skill and handoff.
# clear: wake the fresh session (asyncRewake, exit 2) only for a .reset-pending marker written in
#   the last 5 minutes that names an existing handoff; the marker is claimed atomically.
# compact: point at the run's handoff when a handoff was updated within 24h.
input=$(cat)
source=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
dir="${MMO_HANDOFF_DIR:-.claude/handoffs}"
case "$dir" in /*) ;; *) dir="${CLAUDE_PROJECT_DIR:-$PWD}/$dir" ;; esac
skill="Skill('multi-model-orchestrator:meta-orchestration')"

case "$source" in
  clear)
    marker="$dir/.reset-pending"
    [ -f "$marker" ] || exit 0
    claimed="$marker.$$"
    mv "$marker" "$claimed" 2>/dev/null || exit 0
    handoff=$(head -n 1 "$claimed")
    fresh=$(find "$claimed" -mmin -5)
    rm -f "$claimed"
    [ -n "$fresh" ] && [ -f "$handoff" ] || exit 0
    printf '%s\n' "Checkpoint reset by the meta-orchestrator. Invoke $skill and run it as --resume \"$handoff\"." >&2
    exit 2
    ;;
  compact)
    handoff=$(ls -t "$dir"/handoff-*.md 2>/dev/null | head -n 1)
    [ -n "$handoff" ] && [ -n "$(find "$handoff" -mmin -1440)" ] || exit 0
    printf '%s\n' "If this session was running /multi-model-orchestrator:meta-orchestrate: invoke $skill, re-read the handoff this run was using (the summary names it; newest here is \"$handoff\"), and continue as --resume. The compaction summary is not authoritative."
    ;;
esac
