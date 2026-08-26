#!/usr/bin/env bash
# Shared review terminal-verdict check for run-claude/codex/grok.
# Case-insensitive. A line must be either a bare APPROVE/APPROVED or
# NEEDS_WORK / NEEDS WORK token, or the same token prefixed by VERDICT:
# (optional surrounding whitespace). Rejects empty output and prose that
# merely contains those words mid-sentence.
mmo_has_review_verdict() {
  grep -Eiq '^[[:space:]]*(VERDICT[[:space:]]*:[[:space:]]*)?(APPROVE[D]?|NEEDS[ _]WORK)[[:space:]]*$' "$1"
}
