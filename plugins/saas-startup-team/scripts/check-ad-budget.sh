#!/bin/bash
# check-ad-budget.sh — PostToolUse hook for Write events
# Hard stop at 100% of approved ad budget.
# Checks docs/growth/channels/ads.md for spend vs approved budget.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not ads.md, or within budget
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check ads.md writes
if [[ ! "$file_path" =~ docs/growth/channels/ads\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

# Extract approved budget and total spend — look for patterns like "Approved budget: $500" and "Total spend: $450"
approved=$(echo "$content" | grep -oP 'Approved budget: \$\K[0-9]+' | tail -1 || echo "0")
spent=$(echo "$content" | grep -oP 'Total spend: \$\K[0-9]+' | tail -1 || echo "0")

if [ "$approved" -eq 0 ] 2>/dev/null; then
  # No budget line found — can't validate
  exit 0
fi

if [ "$spent" -ge "$approved" ] 2>/dev/null; then
  cat >&2 <<MSG
{"systemMessage":"AD BUDGET HARD STOP: Total spend (\$${spent}) has reached or exceeded approved budget (\$${approved}). Do NOT make any further ad purchases. Add a human task requesting the investor to approve additional budget with ROAS data."}
MSG
  exit 2
fi

# Warn at 80%
threshold=$(( approved * 80 / 100 ))
if [ "$spent" -ge "$threshold" ] 2>/dev/null; then
  cat >&2 <<MSG
{"systemMessage":"Ad budget warning: \$${spent} of \$${approved} spent ($(( spent * 100 / approved ))%). Add a human task alerting the investor that budget is running low."}
MSG
  exit 2
fi

exit 0
