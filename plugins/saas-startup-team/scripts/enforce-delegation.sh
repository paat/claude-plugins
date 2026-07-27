#!/bin/bash
# enforce-delegation.sh — PostToolUse hook for Edit|Write events
# Prevents the main orchestrator session from directly editing implementation
# code during an active .startup loop. Founder workers are launched with
# --agent-id and always pass. The team-lead active_role value is never written
# (see startup-orchestration), so enforcement keys off the main session +
# active loop rather than an unreachable role name (#381).
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

STATE_FILE="$GIT_ROOT/.startup/state.json"
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

active_role=$(jq -r '.active_role // empty' "$STATE_FILE" 2>/dev/null || true)
status=$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)
iteration=$(jq -r '.iteration // 0' "$STATE_FILE" 2>/dev/null || echo 0)
case "$iteration" in ''|*[!0-9]*) iteration=0 ;; esac

# Outside an active loop, stay inert.
if [ "$status" = "paused" ] || [ "$iteration" -lt 1 ]; then
  exit 0
fi

# Implementer roles edit product code; main orchestrator must not.
case "$active_role" in
  tech-founder|tech-founder-maintain|tech-founder-claude)
    exit 0
    ;;
esac

# Normalize to repo-relative path for anchored checks
rel_path="${file_path#"$GIT_ROOT"/}"

# Orchestrator may write to .startup/, docs/, and CLAUDE.md / AGENTS.md
if [[ "$rel_path" =~ ^\.startup/ ]]; then
  exit 0
fi

if [[ "$rel_path" =~ ^docs/ ]]; then
  exit 0
fi

if [[ "$rel_path" =~ (CLAUDE|AGENTS)\.md$ ]]; then
  exit 0
fi

# Block: main orchestrator is trying to edit implementation code
cat >&2 <<'EOF'
{"systemMessage":"You are the team lead/orchestrator. Do NOT edit implementation code directly — delegate to the tech founder via a handoff document instead. Write your requirements to .startup/handoffs/NNN-business-to-tech.md and let the tech founder implement. Only .startup/, docs/, and CLAUDE.md/AGENTS.md files may be edited by the orchestrator."}
EOF
exit 2
