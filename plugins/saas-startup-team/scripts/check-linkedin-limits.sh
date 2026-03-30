#!/bin/bash
# check-linkedin-limits.sh — PostToolUse hook for Write events
# Enforces LinkedIn rate limits by parsing counters in docs/growth/channels/linkedin.md.
# Triggers on writes to linkedin.md — checks if counters exceed limits.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not linkedin.md, or within limits
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check linkedin.md writes
if [[ ! "$file_path" =~ docs/growth/channels/linkedin\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

# Extract counters from the file — look for patterns like "connections sent: N/50"
connections=$(echo "$content" | grep -oP 'connections sent: \K[0-9]+' | tail -1 || echo "0")
messages=$(echo "$content" | grep -oP 'messages sent today: \K[0-9]+' | tail -1 || echo "0")
views=$(echo "$content" | grep -oP 'profiles viewed today: \K[0-9]+' | tail -1 || echo "0")

violations=""

if [ "$connections" -ge 50 ] 2>/dev/null; then
  violations="${violations}Weekly connection limit reached (${connections}/50). "
fi

if [ "$messages" -ge 20 ] 2>/dev/null; then
  violations="${violations}Daily message limit reached (${messages}/20). "
fi

if [ "$views" -ge 40 ] 2>/dev/null; then
  violations="${violations}Daily profile view limit reached (${views}/40). "
fi

if [ -n "$violations" ]; then
  # Exit 0 to allow the counter write (agent needs to persist the limit-reached state).
  # The warning message tells the agent to stop further LinkedIn activity.
  cat >&2 <<MSG
{"systemMessage":"LinkedIn rate limit warning: ${violations}Pause LinkedIn activity for this period and shift effort to cold email or community engagement. See the LinkedIn Safety reference for cool-down protocol."}
MSG
  exit 0
fi

exit 0
