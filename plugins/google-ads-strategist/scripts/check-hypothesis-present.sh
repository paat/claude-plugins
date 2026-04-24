#!/bin/bash
# check-hypothesis-present.sh — PreToolUse hook for Write events
# Blocks writing iterations/vN/spec.md if iterations/vN/hypothesis.md is missing.
# Enforces the "hypothesis before spec" discipline — the block happens BEFORE
# the write, so the invalid spec file is never created.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a spec.md, or hypothesis exists
# Exit 2: blocked — hypothesis.md missing

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check iterations/vN/spec.md writes
if [[ ! "$file_path" =~ docs/ads/[^/]+/iterations/v[0-9]+/spec\.md$ ]]; then
  exit 0
fi

# Compute the sibling hypothesis.md path
iteration_dir=$(dirname "$file_path")
hypothesis_file="${iteration_dir}/hypothesis.md"

if [ ! -f "$hypothesis_file" ]; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: ${file_path} was written without a sibling hypothesis.md. Discipline violation — every iteration must start with a hypothesis. Delete this spec.md, create ${hypothesis_file} first with variable_class + prediction + reasoning, then rewrite the spec."}
MSG
  exit 2
fi

exit 0
