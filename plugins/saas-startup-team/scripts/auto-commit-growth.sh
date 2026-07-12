#!/bin/bash
# auto-commit-growth.sh — PostToolUse hook for Write events
# Auto-commits only the docs/growth artifact that triggered this hook.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a growth file
# Exit 2: committed work, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
repo_root=$(realpath -e -- "$repo_root" 2>/dev/null) || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/guard-active.sh" && exit 0
case "$file_path" in /*) candidate="$file_path" ;; *) candidate="$repo_root/$file_path" ;; esac
canonical_path=$(realpath -m -- "$candidate" 2>/dev/null) || exit 0
case "$canonical_path" in
  "$repo_root"/*) rel_path="${canonical_path#"$repo_root"/}" ;;
  *) exit 0 ;;
esac

# Only handle docs/growth/ files
if ! echo "$rel_path" | grep -qE '^docs/growth/'; then
  exit 0
fi

# Determine commit type from path
filename=$(basename "$canonical_path")
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
rc=0
bash "$SCRIPT_DIR/commit-artifact.sh" --path "$rel_path" --message "$commit_msg" >/dev/null || rc=$?
if [ "$rc" -eq 3 ]; then
  exit 0
elif [ "$rc" -ne 0 ]; then
  echo "auto-commit-growth: artifact commit failed; unrelated staged changes were not committed" >&2
  exit 0
fi

jq -n --arg msg "Auto-committed growth work: ${commit_msg}" '{systemMessage: $msg}' >&2
exit 2
