#!/usr/bin/env bash
# SessionStart compact: send a meta-orchestrator back to its skill and the run's handoff when a
# handoff was updated within 24h.
input=$(cat)
source=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
[ "$source" = compact ] || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ] && command -v jq >/dev/null 2>&1; then
  project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
fi
project_dir="${project_dir:-$PWD}"

dir="${MMO_HANDOFF_DIR:-.claude/handoffs}"
case "$dir" in /*) ;; *) dir="${project_dir}/$dir" ;; esac
skill="Skill('multi-model-orchestrator:meta-orchestration')"

handoff=$(ls -t "$dir"/handoff-*.md 2>/dev/null | head -n 1)
[ -n "$handoff" ] && [ -n "$(find "$handoff" -mmin -1440 2>/dev/null)" ] || exit 0
printf '%s\n' "If this session was running /multi-model-orchestrator:meta-orchestrate: invoke $skill, re-read the handoff this run was using (the summary names it; newest here is \"$handoff\"), and continue as --resume. The compaction summary is not authoritative."
