#!/bin/bash
# enforce-delegation.sh — PostToolUse hook for Edit|Write events
# Prevents the team lead (main orchestrator) from directly editing implementation
# code during the /startup orchestration loop. The team lead should delegate via
# handoffs, not code directly.
#
# The hook only enforces when there is an explicit team-lead orchestrator:
# state.json active_role == "team-lead" AND no --agent-id in the process tree.
# Outside the /startup loop (e.g. /improve, /lawyer, /ux-test, direct agent
# invocation) there is no team-lead to enforce against, so the hook is inert.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: allowed
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Locate git root early — needed for state.json lookup and .startup/ existence check
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_ROOT" ] || [ ! -d "$GIT_ROOT/.startup" ]; then
  exit 0
fi

# Subagents (Task-spawned team members) always carry --agent-id in their process
# tree. If we're inside one, allow.
ppid_check=$PPID
for _ in 1 2 3 4 5; do
  [[ "$ppid_check" =~ ^[0-9]+$ ]] || break
  [ "$ppid_check" -le 1 ] && break
  if tr '\0' ' ' < /proc/"$ppid_check"/cmdline 2>/dev/null | grep -q -- '--agent-id'; then
    exit 0
  fi
  ppid_check=$(grep -m1 '^PPid:' /proc/"$ppid_check"/status 2>/dev/null | awk '{print $2}')
done

# Top-level Claude session: only block when state.json explicitly marks us as
# team-lead. Missing state.json, unset active_role, or any non-team-lead value
# (business-founder, tech-founder, tech-founder-maintain, lawyer, ux-tester,
# growth-hacker, etc.) means no orchestrator is active and we bypass.
active_role=$(jq -r '.active_role // empty' "$GIT_ROOT/.startup/state.json" 2>/dev/null || true)
if [ "$active_role" != "team-lead" ]; then
  exit 0
fi

# Normalize to repo-relative path for anchored checks
rel_path="${file_path#"$GIT_ROOT"/}"

# Team lead may write to .startup/, docs/, CLAUDE.md, and PLUGIN_ISSUES.md
if [[ "$rel_path" =~ ^\.startup/ ]]; then
  exit 0
fi

if [[ "$rel_path" =~ ^docs/ ]]; then
  exit 0
fi

if [[ "$rel_path" =~ CLAUDE\.md$ ]]; then
  exit 0
fi

if [[ "$rel_path" =~ PLUGIN_ISSUES\.md$ ]]; then
  exit 0
fi

# Block: orchestrator is trying to edit implementation code
cat >&2 <<'EOF'
{"systemMessage":"You are the team lead/orchestrator. Do NOT edit implementation code directly — delegate to the tech founder via a handoff document instead. Write your requirements to .startup/handoffs/NNN-business-to-tech.md and let the tech founder implement. Only .startup/, docs/, and CLAUDE.md files may be edited by the orchestrator."}
EOF
exit 2
