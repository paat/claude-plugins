#!/usr/bin/env bash
# /lawyer fix-plan input collector. Args: <tmpdir>
# For every flagged-and-unacked slug (needs_review=true AND gh_issue_url=null),
# re-fetches the current paragraph text and writes <tmpdir>/<slug>.json with
# old_text + new_text + lifecycle status + feed change + datalake impact, plus
# fetch_error (the refusal reason when the citation cannot be resolved to a URL,
# else null; new_text is then empty because nothing was fetched). Also
# writes <tmpdir>/markers.tsv (slug → file:line) via the marker scan. The Lawyer
# agent reads these to write the fix plan.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

TMP="${1:-}"
[ -n "$TMP" ] || { echo "Usage: lawyer-fixplan-collect.sh <tmpdir>"; exit 1; }

FLAGGED_SLUGS=$(jq -r '.entries | to_entries[] | select(.value.needs_review == true and .value.gh_issue_url == null) | .key' "$REGISTRY")

while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  resp="" fetch_error=""
  if lawyer_slug_cite_url "$slug"; then
    resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$SLUG_CITE_URL")
  else
    fetch_error="$SLUG_CITE_ERROR"
    echo "WARNING: $fetch_error — new text not fetched." >&2
  fi
  new_text=$(echo "$resp" | jq -r '.text // ""')
  old_text=$(cat "${LAWS_DIR}/${slug}.txt" 2>/dev/null || echo "")

  # Lifecycle signals — when the change is a repeal/supersession there is no "new
  # text to adopt"; the fix is to remove or replace the dependency.
  cite_status=$(echo "$resp" | jq -r '.status // empty')
  cite_in_force=$(echo "$resp" | jq -r 'if has("in_force") and .in_force != null then (.in_force|tostring) else "" end')

  # Augment with the datalake's own impact analysis when a feed change_id exists.
  change_id=$(jq -r --arg s "$slug" '.entries[$s].change.feed_event_id // empty' "$REGISTRY")
  impact="{}"
  if [ -n "$change_id" ]; then
    impact=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
      "$DATALAKE_URL/api/v1/changes/${change_id}/impact" 2>/dev/null || echo "{}")
    echo "$impact" | jq empty 2>/dev/null || impact="{}"
  fi

  jq -n --arg slug "$slug" --arg old "$old_text" --arg new "$new_text" \
    --arg status "$cite_status" --arg inforce "$cite_in_force" --arg err "$fetch_error" \
    --argjson change "$(jq -c --arg s "$slug" '.entries[$s].change' "$REGISTRY")" \
    --argjson impact "$impact" \
    '{slug:$slug, old_text:$old, new_text:$new,
      status:(if $status == "" then null else $status end),
      in_force:(if $inforce == "" then null else ($inforce == "true") end),
      change:$change, impact:$impact,
      fetch_error:(if $err == "" then null else $err end)}' \
    > "$TMP/${slug}.json"
done <<< "$FLAGGED_SLUGS"

if ! bash "$(dirname "$0")/lawyer-marker-scan.sh" > "$TMP/markers.tsv"; then
  rm -f "$TMP/markers.tsv"
  echo "lawyer-fixplan-collect.sh: marker scan failed" >&2
  exit 1
fi
