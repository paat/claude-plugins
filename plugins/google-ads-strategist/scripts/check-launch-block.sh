#!/bin/bash
# check-launch-block.sh — PreToolUse hook for Chrome navigate events
# The ads-strategist MAY create campaigns (navigates to /aw/campaigns/new etc.)
# but must NEVER activate/enable/unpause them. Campaign is created as PAUSED;
# the human enables it after review.
#
# ALLOW: campaign/ad-group/ad/keyword creation and editing URLs
# WARN: any ads.google.com/aw navigation (remind agent: PAUSED only)
# BLOCK: billing changes
#
# Input: JSON on stdin with tool_input.url (for mcp__claude-in-chrome__navigate)
# Exit 0: safe or allowed with warning
# Exit 2: blocked

set -euo pipefail

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$tool_name" ] && exit 0

if [[ "$tool_name" != "mcp__claude-in-chrome__navigate" ]]; then
  exit 0
fi

url=$(echo "$input" | jq -r '.tool_input.url // empty' 2>/dev/null)
[ -z "$url" ] && exit 0

# Hard-block: billing (irreversible money operations)
if echo "$url" | grep -qiE 'ads\.google\.com/aw/billing'; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: Navigation to Google Ads billing is not allowed. The strategist manages campaigns, not payment methods."}
MSG
  exit 2
fi

# Warn (but allow) on any ads.google.com/aw navigation — remind about PAUSED state
if echo "$url" | grep -qiE 'ads\.google\.com/aw'; then
  cat >&2 <<MSG
{"systemMessage":"REMINDER: You are navigating inside Google Ads dashboard. All campaigns MUST be created in PAUSED state. NEVER click Enable, Activate, or Resume on any campaign, ad group, or ad. The investor reviews and enables manually after your work is done."}
MSG
  exit 0
fi

exit 0
