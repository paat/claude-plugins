#!/bin/bash
# auto-commit.sh — PostToolUse hook for Write events
# Auto-commits work when durable knowledge files are written to docs/.
# Also commits implementation code when handoffs are written (handoffs
# themselves are gitignored, but backend/frontend code is not).
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

# Normalize to repo-relative path for anchored matching
rel_path="${file_path#"$repo_root"/}"

# Determine commit type from file path
filename=$(basename "$file_path")
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
elif echo "$rel_path" | grep -qE '^\.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$'; then
  # Handoffs are gitignored but we still auto-commit implementation code
  # that was changed alongside the handoff
  handoff_num=$(echo "$filename" | grep -oE '^[0-9]{3}')
  direction=$(echo "$filename" | sed 's/^[0-9]*-//; s/\.md$//')
  case "$direction" in
    business-to-tech) founder="business-founder" ;;
    tech-to-business) founder="tech-founder" ;;
    *) founder="unknown" ;;
  esac
  commit_msg="${founder}: handoff ${handoff_num} — ${direction}"
else
  # Not a milestone file — skip
  exit 0
fi

# Stage docs/ and implementation files (avoid staging sensitive files like .env)
cd "$repo_root"
git add -A docs/ || true
git add -A backend/ frontend/ || true
git add -A CLAUDE.md || true

# Check if there's anything to commit
if git diff --cached --quiet 2>/dev/null; then
  # Nothing staged — skip
  exit 0
fi

# Commit with --no-verify to skip project-level pre-commit hooks
git commit -m "${commit_msg}" --no-verify || true

# Signal to Claude that we committed
jq -n --arg msg "Auto-committed all work: ${commit_msg}" '{systemMessage: $msg}' >&2
exit 2
