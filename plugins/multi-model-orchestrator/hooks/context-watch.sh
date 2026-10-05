#!/usr/bin/env bash
# PostToolUse: warn a meta-orchestrator once when context crosses MMO_CONTEXT_WARN_TOKENS.
# Context size comes from the transcript's last usage record: Claude Code assistant usage
# (input + cache read + cache creation) or Codex token_count (last_token_usage.input_tokens).
# Re-arms when context drops below the threshold again (after compaction).
command -v jq >/dev/null 2>&1 || { cat >/dev/null; exit 0; }
input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
[ -f "$transcript" ] && [ -n "$session" ] || exit 0
limit="${MMO_CONTEXT_WARN_TOKENS:-400000}"
case "$limit" in ''|*[!0-9]*) exit 0 ;; esac

reverse="tac"; command -v tac >/dev/null 2>&1 || reverse="tail -r"
tokens=$($reverse "$transcript" | grep -m 1 -E '"type":"assistant"|"last_token_usage"' | jq -R '
  fromjson? | (.message.usage // .payload.info.last_token_usage // empty)
  | if has("cache_read_input_tokens") or has("cache_creation_input_tokens")
    then (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    else (.input_tokens // 0) end' 2>/dev/null)
case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac

marker="${TMPDIR:-/tmp}/mmo-context-warned-$session"
if [ "$tokens" -lt "$limit" ]; then rm -f "$marker"; exit 0; fi
[ -e "$marker" ] && exit 0
grep -qF 'multi-model-orchestrator:meta-orchestrat' "$transcript" || exit 0
: > "$marker"

msg="Context is at $tokens tokens (MMO_CONTEXT_WARN_TOKENS=$limit). If this session is running /multi-model-orchestrator:meta-orchestrate: bring the handoff current now, and keep this item lean (legs return verdicts, no full-file reads here); compaction resumes from the handoff."
jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
