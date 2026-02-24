#!/bin/bash
# enforce-tone.sh — PostToolUse hook for Write events
# Flags MVP, prototype, and "good enough" language in handoff files.
# Non-matching files exit 0 silently. Violations exit 2 with systemMessage.
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# Only check .startup/handoffs/ files
if [[ ! "$file_path" =~ \.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$ ]]; then
  exit 0
fi

# Read the handoff content
content=$(cat "$file_path" 2>/dev/null || exit 0)

# Check for tone violations — case-insensitive grep for anti-patterns
# Exclude lines that are themselves rules/guidelines (contain NEVER/ALWAYS)
filtered=$(echo "$content" | grep -v -E '(NEVER|ALWAYS|do not|must not)' || true)
violations=$(echo "$filtered" | grep -iE '\bMVP\b|prototype|good enough|quick fix|placeholder|hack|band.?aid|bare.?bones|rough draft|cut corners' || true)

if [ -n "$violations" ]; then
  cat >&2 <<'MSG'
{"systemMessage":"The handoff you just wrote contains language suggesting less-than-production quality ('MVP', 'prototype', 'good enough', 'placeholder', etc.). This is a production business — rewrite those sections to target production standard. Replace 'MVP' with 'initial release', replace 'prototype' with 'production implementation', remove any language that implies corner-cutting."}
MSG
  exit 2
fi

exit 0
