#!/usr/bin/env bash
# PostToolUse / PostInvocation: warn a meta-orchestrator once when context crosses MMO_CONTEXT_WARN_TOKENS.
# Context size comes from the transcript's last usage record: Claude Code assistant usage
# (input + cache read + cache creation), Codex token_count (last_token_usage.input_tokens),
# Antigravity (agy) step input_tokens + cache_read_tokens, or Grok/Muse usage records.
# Re-arms when context drops below the threshold again (after compaction).
is_agy=0
[ "${HOOK_RUNTIME:-}" = agy ] && is_agy=1
noop() { [ "$is_agy" -eq 1 ] && printf '{}\n'; exit 0; }

command -v jq >/dev/null 2>&1 || { cat >/dev/null; noop; }
input=$(cat)
if [ "$is_agy" -eq 0 ] && printf '%s' "$input" | jq -e 'type == "object" and has("conversationId")' >/dev/null 2>&1; then
  is_agy=1
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // .conversationId // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
[ -f "$transcript" ] && [ -n "$session" ] || noop
limit="${MMO_CONTEXT_WARN_TOKENS:-400000}"
case "$limit" in ''|*[!0-9]*) noop ;; esac

reverse="tac"; command -v tac >/dev/null 2>&1 || reverse="tail -r"
tokens=$($reverse "$transcript" | grep -m 1 -E '"type":"assistant"|"last_token_usage"|"input_tokens"|"inputTokens"' | jq -R '
  fromjson? |
  if (.message.usage? | type) == "object" then .message.usage
  elif (.payload.info.last_token_usage? | type) == "object" then .payload.info.last_token_usage
  elif (.usage? | type) == "object" then .usage
  elif has("input_tokens") or has("inputTokens") then .
  else empty end
  | if has("cache_read_input_tokens") or has("cache_creation_input_tokens")
    then (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    elif has("cache_read_tokens")
    then (.input_tokens // 0) + (.cache_read_tokens // 0)
    else (.input_tokens // .inputTokens // 0) end' 2>/dev/null)
case "$tokens" in ''|*[!0-9]*) noop ;; esac

marker="${TMPDIR:-/tmp}/mmo-context-warned-$session"
if [ "$tokens" -lt "$limit" ]; then rm -f "$marker"; noop; fi
[ -e "$marker" ] && noop
# An invocation, not a mention: every session's skill listing names the skill.
# Skill tool input, a slash or $ command opening a message, loaded workflow heading, or agy skill read.
grep -qE '"skill":"multi-model-orchestrator:meta-orchestrat|[^\\]"[/$]multi-model-orchestrator:meta-orchestrat|<command-name>/?multi-model-orchestrator:meta-orchestrat|# /multi-model-orchestrator:meta-orchestrate Codex Workflow|skills/meta-orchestration/SKILL\.md' "$transcript" || noop
: > "$marker"

msg="Context is at $tokens tokens (MMO_CONTEXT_WARN_TOKENS=$limit). If this session is running /multi-model-orchestrator:meta-orchestrate: bring the handoff current now, and keep this item lean (legs return verdicts, no full-file reads here); compaction resumes from the handoff."
if [ "$is_agy" -eq 1 ]; then
  jq -cn --arg m "$msg" '{injectSteps:[{systemMessage:{systemMessage:$m}}]}'
  exit 0
fi
jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
