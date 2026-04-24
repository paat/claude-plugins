#!/bin/bash
# auto-commit-growth.sh — PostToolUse hook for Write events
# Auto-commits docs/growth/ changes when growth content or metrics are updated.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a growth file
# Exit 2: committed work, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

rel_path="${file_path#"$repo_root"/}"

# Only handle docs/growth/ files
if ! echo "$rel_path" | grep -qE '^docs/growth/'; then
  exit 0
fi

# Determine commit type from path
filename=$(basename "$file_path")
commit_msg=""

if echo "$rel_path" | grep -qE '^docs/growth/channels/'; then
  commit_msg="growth: update channel ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/metrics/'; then
  commit_msg="growth: update metrics ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/leads/'; then
  commit_msg="growth: update pipeline ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/content/'; then
  commit_msg="growth: add content ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/brand/'; then
  commit_msg="growth: update brand ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/'; then
  commit_msg="growth: update ${filename%.md}"
else
  exit 0
fi

cd "$repo_root"
git add -A docs/growth/ || true

if git diff --cached --quiet 2>/dev/null; then
  exit 0
fi

git commit -m "${commit_msg}" --no-verify || true

jq -n --arg msg "Auto-committed growth work: ${commit_msg}" '{systemMessage: $msg}' >&2
exit 2
