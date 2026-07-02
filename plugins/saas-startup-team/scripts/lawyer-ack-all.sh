#!/usr/bin/env bash
# /lawyer ack-all — ack every flagged (needs_review=true) entry. Use only when the
# PR's code changes cover every flagged slug; otherwise use per-slug `ack`.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

FLAGGED=$(jq -r '.entries | to_entries[] | select(.value.needs_review == true) | .key' "$REGISTRY")
[ -z "$FLAGGED" ] && { echo "No flagged entries to ack."; exit 0; }

while IFS= read -r SLUG; do
  [ -z "$SLUG" ] && continue
  echo "Ack-ing: $SLUG"
  lawyer_ack_one "$SLUG"; rc=$?
  case "$rc" in
    2) echo "Error: datalake returned empty text for act_id=$ACK_ACT_ID — skipping $SLUG"; continue ;;
    3) echo "WARNING: skipping $SLUG: act $ACK_ACT_ID is status=${ACK_STATUS:-unknown}, in_force=${ACK_IN_FORCE:-unknown} — not in force; flag kept."; continue ;;
    4) echo "Error: could not write snapshot .startup/laws/${SLUG}.txt — registry left untouched; flag kept. Skipping $SLUG."; continue ;;
  esac
done <<< "$FLAGGED"

echo "Ack-all complete. Remember to commit .startup/law-registry.json and .startup/laws/*.txt in this PR alongside your code changes."
exit 0
