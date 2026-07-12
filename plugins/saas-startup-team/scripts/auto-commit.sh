#!/bin/bash
# auto-commit.sh — PostToolUse hook for Write events
# Auto-commits only the durable artifact file that triggered the hook.
# Product source, tests, workflow specs, and unrelated staged changes are owned by
# the supervisor commit path and are never staged or swept into this commit.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: no action (non-milestone file or no git repo)
# Exit 2: committed work, systemMessage on stderr

set -euo pipefail

# Read JSON from stdin
input=$(cat)

# Extract file_path from tool_input
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Find git repo root early — needed to normalize absolute paths
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

# Determine commit type from file path
filename=$(basename "$canonical_path")
commit_msg=""

if echo "$rel_path" | grep -qE '^docs/research/.*\.md$'; then
  commit_msg="research: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/legal/.*\.md$'; then
  commit_msg="legal: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/architecture/.*\.md$'; then
  commit_msg="architecture: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/ux/.*\.md$'; then
  commit_msg="ux: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/seo/.*\.md$'; then
  commit_msg="seo: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/business/.*\.md$'; then
  commit_msg="business: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/.*\.md$'; then
  # Let auto-commit-growth.sh handle these with more specific commit messages
  exit 0
elif echo "$rel_path" | grep -qE '^\.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$'; then
  # Handoffs are delivery signals, not commit triggers. In particular, never stage
  # the source diff merely because a tech handoff was written.
  exit 0
elif echo "$rel_path" | grep -qE '^\.startup/signoffs/.*\.md$'; then
  commit_msg="signoff: ${filename%.md}"
elif echo "$rel_path" | grep -qE '^\.startup/reviews/.*\.md$'; then
  commit_msg="review: ${filename%.md}"
else
  # Not a milestone file — skip
  exit 0
fi

cd "$repo_root"
rc=0
bash "$SCRIPT_DIR/commit-artifact.sh" --path "$rel_path" --message "$commit_msg" >/dev/null || rc=$?
if [ "$rc" -eq 3 ]; then
  exit 0
elif [ "$rc" -ne 0 ]; then
  echo "auto-commit: artifact commit failed; product diff was not committed" >&2
  exit 0
fi

# Signal to Claude that we committed
jq -n --arg msg "Auto-committed artifact only: ${commit_msg}" '{systemMessage: $msg}' >&2
exit 2
