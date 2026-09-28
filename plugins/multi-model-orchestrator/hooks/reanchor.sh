#!/usr/bin/env bash
# SessionStart: send a meta-orchestrator back to its skill and handoff after compaction or a
# checkpoint reset. clear: wake the fresh session (asyncRewake, exit 2) only when the orchestrator
# left a .reset-pending marker naming the handoff. compact: add a pointer to a handoff fresh within 24h.
input=$(cat)
dir="${CLAUDE_PROJECT_DIR:-$PWD}/${MMO_HANDOFF_DIR:-.claude/handoffs}"
skill="Skill('multi-model-orchestrator:meta-orchestration')"
case "$input" in
  *'"source"'*'"clear"'*)
    [ -f "$dir/.reset-pending" ] || exit 0
    handoff=$(head -n 1 "$dir/.reset-pending")
    rm -f "$dir/.reset-pending"
    printf '%s\n' "Checkpoint reset by the meta-orchestrator. Invoke $skill and run it as --resume $handoff." >&2
    exit 2
    ;;
esac
handoff=$(ls -t "$dir"/handoff-*.md 2>/dev/null | head -n 1)
[ -n "$handoff" ] && [ -n "$(find "$handoff" -mmin -1440)" ] || exit 0
printf '%s\n' "If this session was running /multi-model-orchestrator:meta-orchestrate: invoke $skill, re-read $handoff, and continue as --resume. The compaction summary is not authoritative."
