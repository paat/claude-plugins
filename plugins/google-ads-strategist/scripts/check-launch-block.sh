#!/bin/bash
# check-launch-block.sh — PreToolUse hook for Chrome navigate events
# Blocks navigation to Google Ads campaign-creation or campaign-edit URLs.
# The ads-strategist is design-only — it must never launch, pause, or mutate
# a live Google Ads campaign autonomously.
#
# Input: JSON on stdin with tool_input.url (for mcp__claude-in-chrome__navigate)
# Exit 0: not a Chrome navigation, or URL is safe
# Exit 2: blocked — launch URL detected

set -euo pipefail

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$tool_name" ] && exit 0

# Only check Chrome navigate calls
if [[ "$tool_name" != "mcp__claude-in-chrome__navigate" ]]; then
  exit 0
fi

url=$(echo "$input" | jq -r '.tool_input.url // empty' 2>/dev/null)
[ -z "$url" ] && exit 0

# Block patterns — specific campaign creation/edit/delete endpoints inside ads.google.com
# Kept narrow to avoid false positives on troubleshooting/reports pages that happen to
# contain "enable" or "pause" as substrings.
blocked_patterns=(
  'ads\.google\.com/aw/campaigns/new'
  'ads\.google\.com/aw/campaigns/[^/?#]+/edit'
  'ads\.google\.com/aw/campaigns/[^/?#]+/settings'
  'ads\.google\.com/aw/billing'
  'ads\.google\.com/aw/adgroups/new'
  'ads\.google\.com/aw/adgroups/[^/?#]+/edit'
  'ads\.google\.com/aw/ads/new'
  'ads\.google\.com/aw/ads/[^/?#]+/edit'
  'ads\.google\.com/aw/keywords/new'
  'ads\.google\.com/aw/(overview|campaigns|adgroups|ads|keywords)/[^/?#]+/(pause|enable|remove|delete)'
)

for pattern in "${blocked_patterns[@]}"; do
  if echo "$url" | grep -qiE "$pattern"; then
    cat >&2 <<MSG
{"systemMessage":"LAUNCH BLOCK: navigation to '${url}' is blocked. The ads-strategist is design-only — it must not launch, pause, edit, or mutate live Google Ads campaigns. Verification uses ads.google.com/anon/AdPreview (public) or ads.google.com/aw/tools/adpreview (authenticated read-only). If the human wants to launch this campaign, they do it manually — hand them the spec."}
MSG
    exit 2
  fi
done

exit 0
