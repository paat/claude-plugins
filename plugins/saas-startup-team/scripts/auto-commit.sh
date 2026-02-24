#!/bin/bash
# auto-commit.sh — PostToolUse hook for Write events
# Auto-commits all work when a handoff file is written to .startup/handoffs/
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: no action (non-handoff file or no git repo)
# Exit 2: committed work, systemMessage on stderr

set -euo pipefail

# Read JSON from stdin
input=$(cat)

# Extract file_path from tool_input
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only trigger for handoff files: .startup/handoffs/NNN-*.md
if ! echo "$file_path" | grep -qE '\.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$'; then
  exit 0
fi

# Extract handoff number and direction from filename
filename=$(basename "$file_path")
handoff_num=$(echo "$filename" | grep -oE '^[0-9]{3}')
direction=$(echo "$filename" | sed 's/^[0-9]*-//; s/\.md$//')

# Determine founder name from direction
case "$direction" in
  business-to-tech) founder="business-founder" ;;
  tech-to-business) founder="tech-founder" ;;
  *) founder="unknown" ;;
esac

# Find git repo root — if not in a git repo, exit silently
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Stage all files in the repo
cd "$repo_root"
git add -A . || true

# Check if there's anything to commit
if git diff --cached --quiet 2>/dev/null; then
  # Nothing staged — skip
  exit 0
fi

# Commit with --no-verify to skip project-level pre-commit hooks
git commit -m "${founder}: handoff ${handoff_num} — ${direction}" --no-verify || true

# Signal to Claude that we committed
echo '{"systemMessage":"Auto-committed all work at handoff '"${handoff_num}"' ('"${direction}"')"}' >&2
exit 2
