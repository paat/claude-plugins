#!/usr/bin/env bash
# Shared review terminal-verdict check for run-claude/codex/grok.
# Case-insensitive. Accepts APPROVE/APPROVED and NEEDS_WORK / NEEDS WORK
# with non-letter/underscore boundaries. Rejects empty and prose-only output.
mmo_has_review_verdict() {
  grep -Eiq '(^|[^[:alpha:]_])(APPROVE[D]?|NEEDS[ _]?WORK)([^[:alpha:]_]|$)' "$1"
}
