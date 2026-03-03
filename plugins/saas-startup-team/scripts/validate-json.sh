#!/bin/bash
# validate-json.sh — PostToolUse hook for Edit|Write events
# Validates JSON syntax after any .json file is written or edited.
# Catches trailing commas, missing brackets, and other syntax errors.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a JSON file or valid JSON
# Exit 2: invalid JSON, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check .json files
if [[ ! "$file_path" =~ \.json$ ]]; then
  exit 0
fi

# File must exist
[ -f "$file_path" ] || exit 0

# Validate JSON syntax
if ! python3 -m json.tool "$file_path" > /dev/null 2>&1; then
  error_detail=$(python3 -m json.tool "$file_path" 2>&1 | tail -1 || true)
  cat >&2 <<EOF
{"systemMessage":"JSON syntax error in ${file_path##*/}: ${error_detail}. Fix the JSON before continuing — common causes: trailing commas, missing quotes, unclosed brackets."}
EOF
  exit 2
fi

exit 0
