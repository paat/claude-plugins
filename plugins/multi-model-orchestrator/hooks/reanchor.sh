#!/usr/bin/env bash
# SessionStart reanchor: send a meta-orchestrator back to its skill and the run's handoff when a
# handoff was updated within 24h. Works across Claude Code, Codex, Antigravity (agy), Grok, and Muse.
input=$(cat)
is_agy=0
[ "${HOOK_RUNTIME:-}" = agy ] && is_agy=1
if [ "$is_agy" -eq 0 ] && printf '%s' "$input" | grep -q '"conversationId"'; then
  is_agy=1
fi

if [ "$is_agy" -eq 0 ]; then
  source=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
  [ "$source" = compact ] || exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ] && command -v jq >/dev/null 2>&1; then
  project_dir=$(printf '%s' "$input" | jq -r '.cwd // (.workspacePaths[0] // empty)' 2>/dev/null)
fi
project_dir="${project_dir:-$PWD}"

dir="${MMO_HANDOFF_DIR:-.claude/handoffs}"
case "$dir" in /*) ;; *) dir="${project_dir}/$dir" ;; esac
skill="Skill('multi-model-orchestrator:meta-orchestration')"

handoff=$(ls -t "$dir"/handoff-*.md 2>/dev/null | head -n 1)
if [ -z "$handoff" ] || [ -z "$(find "$handoff" -mmin -1440 2>/dev/null)" ]; then
  [ "$is_agy" -eq 1 ] && printf '{}\n'
  exit 0
fi

msg="If this session was running /multi-model-orchestrator:meta-orchestrate: invoke $skill, re-read the handoff this run was using (the summary names it; newest here is \"$handoff\"), and continue as --resume. The compaction summary is not authoritative."
if [ "$is_agy" -eq 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg m "$msg" '{injectSteps:[{systemMessage:{systemMessage:$m}}]}'
  else
    printf '{}\n'
  fi
  exit 0
fi
printf '%s\n' "$msg"
