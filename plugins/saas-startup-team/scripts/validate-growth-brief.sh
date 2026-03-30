#!/bin/bash
# validate-growth-brief.sh — PostToolUse hook for Write events
# Ensures growth briefs have required Objective and Target Customer sections.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a growth brief, or valid
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check growth briefs (business-to-growth handoffs)
if [[ ! "$file_path" =~ \.startup/handoffs/.*business-to-growth\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

violations=""

if ! echo "$content" | grep -q '## Objective'; then
  violations="${violations}Missing '## Objective' section. "
fi

if ! echo "$content" | grep -q '## Target Customer'; then
  violations="${violations}Missing '## Target Customer' section. "
fi

if [ -n "$violations" ]; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: Growth brief is incomplete. ${violations}Every growth brief MUST have an Objective (what we're trying to achieve) and Target Customer (who we're going after). Add the missing sections before proceeding."}
MSG
  exit 2
fi

exit 0
