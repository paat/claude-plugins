#!/bin/bash
# auto-commit.sh — PostToolUse hook for Write events
# Auto-commits all work when a milestone file is written:
#   - .startup/handoffs/NNN-*-to-*.md  (handoffs between founders)
#   - .startup/signoffs/*.md            (feature signoffs)
#   - .startup/reviews/*.md             (review documents)
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

# Determine commit type from file path
filename=$(basename "$file_path")
commit_msg=""

if echo "$file_path" | grep -qE '\.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$'; then
  # Handoff file
  handoff_num=$(echo "$filename" | grep -oE '^[0-9]{3}')
  direction=$(echo "$filename" | sed 's/^[0-9]*-//; s/\.md$//')
  case "$direction" in
    business-to-tech) founder="business-founder" ;;
    tech-to-business) founder="tech-founder" ;;
    *) founder="unknown" ;;
  esac
  commit_msg="${founder}: handoff ${handoff_num} — ${direction}"
elif echo "$file_path" | grep -qE '\.startup/signoffs/.*\.md$'; then
  # Signoff file
  signoff_name=$(echo "$filename" | sed 's/\.md$//')
  commit_msg="signoff: ${signoff_name}"
elif echo "$file_path" | grep -qE '\.startup/reviews/.*\.md$'; then
  # Review file
  review_name=$(echo "$filename" | sed 's/\.md$//')
  commit_msg="review: ${review_name}"
else
  # Not a milestone file — skip
  exit 0
fi

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
git commit -m "${commit_msg}" --no-verify || true

# Signal to Claude that we committed
echo '{"systemMessage":"Auto-committed all work: '"${commit_msg}"'"}' >&2
exit 2
