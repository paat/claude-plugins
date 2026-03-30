#!/bin/bash
# enforce-delegation.sh — PostToolUse hook for Edit|Write events
# Prevents the team lead (main orchestrator) from directly editing implementation
# code. The team lead should delegate via handoffs, not code directly.
#
# Team members (business-founder, tech-founder) are allowed to edit anything.
# The team lead may only write to .startup/ directory and CLAUDE.md files.
#
# Detection (two methods, tried in order):
# 1. Process tree: team members have --agent-id in their parent chain
# 2. Fallback: state.json active_role is a team member role
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: allowed (team member, or writing to .startup/)
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Locate git root early — needed for state.json check and .startup/ existence check
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_ROOT" ] || [ ! -d "$GIT_ROOT/.startup" ]; then
  exit 0
fi

# Check if we're inside a team member agent (has --agent-id in process tree)
is_team_member=false
ppid_check=$PPID
for _ in 1 2 3 4 5; do
  [[ "$ppid_check" =~ ^[0-9]+$ ]] || break
  [ "$ppid_check" -le 1 ] && break
  if tr '\0' ' ' < /proc/"$ppid_check"/cmdline 2>/dev/null | grep -q -- '--agent-id'; then
    is_team_member=true
    break
  fi
  ppid_check=$(grep -m1 '^PPid:' /proc/"$ppid_check"/status 2>/dev/null | awk '{print $2}')
done

# Fallback: check state.json active_role for team member roles
if [ "$is_team_member" = false ]; then
  active_role=$(jq -r '.active_role // empty' "$GIT_ROOT/.startup/state.json" 2>/dev/null || true)
  case "$active_role" in
    tech-founder|business-founder|lawyer|ux-tester|growth-hacker)
      is_team_member=true
      ;;
  esac
fi

# Team members can edit anything — they're the ones doing the work
if [ "$is_team_member" = true ]; then
  exit 0
fi

# Normalize to repo-relative path for anchored checks
rel_path="${file_path#"$GIT_ROOT"/}"

# Main orchestrator: only allow writes to .startup/, docs/, CLAUDE.md, and plugin files
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
