#!/usr/bin/env bash
# Shared helpers for run-claude/codex/grok:
# - review terminal-verdict check
# - provider failure classification (transient → 75, auth → 77)
#
# Verdict check: case-insensitive. A line must be either a bare APPROVE/APPROVED or
# NEEDS_WORK / NEEDS WORK token, or the same token prefixed by VERDICT:.
# Markdown headings and bold decoration around the prefix or token are
# tolerated; empty output and prose containing those words are rejected.
mmo_has_review_verdict() {
  grep -Eiq '^[[:space:]]*#*[[:space:]]*\**(VERDICT\**[[:space:]]*:[[:space:]]*\**[[:space:]]*)?(APPROVE[D]?|NEEDS[ _]WORK)\**[[:space:]]*$' "$1"
}

# Classify provider failure text from stderr (and optional extra files such as a
# Claude stream-json is_error result). Prints "transient", "auth", or nothing.
# Callers must not pass model stdout/stream success bodies.
mmo_classify_provider_failure() {
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -s "$f" ] || continue
    if grep -Eiq '\b(429|529|503)\b|overloaded|rate[[:space:]_-]?limit|temporarily[[:space:]]+unavailable' "$f"; then
      printf 'transient\n'
      return 0
    fi
  done
  for f in "$@"; do
    [ -n "$f" ] && [ -s "$f" ] || continue
    if grep -Eiq '\b401\b|unauthorized|not[[:space:]]+logged[[:space:]]+in|login[[:space:]]+required|(expired|invalid)[[:space:]]+(api[[:space:]]*key|token)|(api[[:space:]]*key|token).*(expired|invalid)' "$f"; then
      printf 'auth\n'
      return 0
    fi
  done
}
