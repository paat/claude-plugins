#!/bin/bash
# check-wait-gate.sh — PreToolUse hook for Write events
# For post-launch iterations, enforces that ≥ wait_days have passed since the
# previous iteration was applied to the live account.
#
# State mechanism: plain marker files (no markdown parsing):
#   docs/ads/<campaign>/launched_at        — presence = post-launch, contents = ISO timestamp
#   docs/ads/<campaign>/iterations/vN/applied_at — presence = applied, contents = ISO timestamp
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: pre-launch, or v1, or no prior applied_at, or gate open, or override present
# Exit 2: gate closed

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check iterations/vN/spec.md writes
if [[ ! "$file_path" =~ docs/ads/[^/]+/iterations/v([0-9]+)/spec\.md$ ]]; then
  exit 0
fi

current_v="${BASH_REMATCH[1]}"
[ "$current_v" -le 1 ] && exit 0  # v1 never has a prior iteration

campaign_dir=$(echo "$file_path" | sed -E 's|(docs/ads/[^/]+)/.*|\1|')

# Only enforce in post-launch mode — detected by presence of the launched_at marker file
launched_file="${campaign_dir}/launched_at"
[ -f "$launched_file" ] || exit 0

# Find the previous iteration's applied_at marker
prev_v=$((current_v - 1))
applied_file="${campaign_dir}/iterations/v${prev_v}/applied_at"

# If the previous iteration was never applied to the live account, allow
# (may happen during pre→post transition)
[ -f "$applied_file" ] || exit 0

applied_timestamp=$(head -1 "$applied_file")
applied_epoch=$(date -d "$applied_timestamp" +%s 2>/dev/null || echo "0")
[ "$applied_epoch" -eq 0 ] && exit 0  # unparseable, allow

now_epoch=$(date +%s)
days_passed=$(( (now_epoch - applied_epoch) / 86400 ))

# Check for force-override marker in the current hypothesis
hypothesis_file="$(dirname "$file_path")/hypothesis.md"
if [ -f "$hypothesis_file" ] && grep -qi 'force-wait-override' "$hypothesis_file"; then
  exit 0
fi

# Read wait_days override from optional marker file (default: 7)
wait_days_file="${campaign_dir}/wait_days"
wait_days=7
if [ -f "$wait_days_file" ]; then
  wait_days=$(head -1 "$wait_days_file" | grep -oE '^[0-9]+' || echo "7")
fi

if [ "$days_passed" -lt "$wait_days" ]; then
  remaining=$(( wait_days - days_passed ))
  cat >&2 <<MSG
{"systemMessage":"WAIT GATE CLOSED: previous iteration v${prev_v} was applied ${days_passed} days ago. Minimum wait is ${wait_days} days for statistical significance. ${remaining} day(s) remaining. If this is urgent (e.g., obvious tracking bug), add 'force-wait-override' to hypothesis.md with written justification."}
MSG
  exit 2
fi

exit 0
