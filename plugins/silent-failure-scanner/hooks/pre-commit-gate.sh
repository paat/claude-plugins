#!/usr/bin/env bash
# silent-failure-scanner PreToolUse commit gate.
#
# Fires before a Bash tool call. When the command is a `git commit`, it scans the
# STAGED diff for silent-failure signatures and, if any are found, DENIES the commit
# and hands the findings back to Claude to arbitrate. Claude must then either fix the
# real swallowed errors or re-run the commit prefixed with SILENT_FAILURE_ACK="reason"
# to record a justification and proceed. Everything else is allowed silently.
#
# Deterministic finder (scan.sh) + in-session LLM arbiter (Claude). No network, no cost.
# Dependencies: bash 4+, awk, git, jq.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HOOK_DIR/../scripts/scan.sh"

allow() { exit 0; }   # no output ⇒ default-allow

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$command" ]] && allow

# Explicit, reasoned acknowledgement bypasses the gate (and leaves an audit trail).
[[ "$command" == *SILENT_FAILURE_ACK=* ]] && allow

# Is any &&/;/newline-separated segment actually a `git … commit`?
is_git_commit() {
  local seg
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim
    [[ "$seg" =~ ^git([[:space:]]|$) && "$seg" =~ [[:space:]]commit([[:space:]]|$) ]] && return 0
  done < <(printf '%s\n' "$command" | tr ';&|' '\n')
  return 1
}
is_git_commit || allow

# Scan the staged diff from within the repo. On any trouble, fail open (allow).
# scan.sh exits 0 = clean, 1 = findings, >1 = usage/internal error → only the last fails open.
[[ -n "$cwd" ]] && { cd "$cwd" 2>/dev/null || allow; }
report="$(bash "$SCAN" --staged --format json 2>/dev/null)"; rc=$?
[[ "$rc" -gt 1 ]] && allow
total="$(printf '%s' "$report" | jq -r '.summary.total // 0' 2>/dev/null)"
[[ "${total:-0}" =~ ^[0-9]+$ ]] || allow
[[ "$total" -eq 0 ]] && allow

# Findings → build a concise list and DENY with arbitration instructions.
findings="$(printf '%s' "$report" | jq -r '.findings[] | "  - \(.file):\(.line) [\(.severity)] \(.code): \(.snippet)"' 2>/dev/null)"
reason="silent-failure-scanner blocked this commit — ${total} finding(s) in the staged diff:
${findings}

Arbitrate each finding before committing:
  • Real swallowed error / ghost transaction → FIX it (rethrow or handle the error,
    restore the removed await, surface the dropped response), then commit again.
  • Genuinely benign → re-run the SAME commit prefixed with
    SILENT_FAILURE_ACK=\"<one-line reason>\" to record the justification and proceed.
Do not bypass with --no-verify."

jq -nc --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  },
  systemMessage: $r
}'
exit 0
