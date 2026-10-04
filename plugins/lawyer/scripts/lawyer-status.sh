#!/usr/bin/env bash
# /lawyer status — concise registry summary. No spawn, no feed call.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

if [ ! -f "$REGISTRY" ]; then
  echo "No law registry in this project. Run /lawyer with a topic to initialise."
  exit 0
fi

total=$(jq -r '.entries | length' "$REGISTRY")
flagged=$(jq -r '[.entries[] | select(.needs_review == true)] | length' "$REGISTRY")
open_issues=$(jq -r '[.entries[] | select(.needs_review == true and .gh_issue_url != null)] | length' "$REGISTRY")
pending_confirm=$(jq -r '[.entries[] | select(.needs_review == true and .gh_issue_url == null)] | length' "$REGISTRY")
last_check=$(jq -r '.last_feed_check_at // "never"' "$REGISTRY")

cat <<EOF
Law registry status
-------------------
Total entries:        $total
Flagged for review:   $flagged
  With open gh issue: $open_issues
  Awaiting issue:     $pending_confirm
Last feed check:      $last_check
EOF

if (( pending_confirm > 0 )); then
  echo ""
  echo "Slugs awaiting confirmation (will prompt on next /lawyer <topic>):"
  jq -r '.entries | to_entries[] | select(.value.needs_review == true and .value.gh_issue_url == null) | "  - " + .key' "$REGISTRY"
fi

exit 0
