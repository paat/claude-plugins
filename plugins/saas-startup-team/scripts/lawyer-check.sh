#!/usr/bin/env bash
# /lawyer change detection. Runs the feed poll + feed-independent lifecycle
# re-check and persists new flags. Reads only the index JSON; snapshots untouched.
# Used by both the `check` subcommand and the start of every /lawyer run.
# Prints only WARNING lines; the caller prints any completion summary.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

lawyer_registry_init

# One feed call per run: query without ?domain= and match client-side by rt_id.
# The server's ?domain= enum doesn't match the plugin's historical domain strings.
RT_IDS=$(jq -r '.entries | to_entries[] | .value.rt_id // empty' "$REGISTRY" | sort -u)

if [ -z "$RT_IDS" ]; then
  echo "Registry is empty; nothing to check."
else
  SINCE=$(jq -r '.last_feed_check_at // ""' "$REGISTRY")
  if [ -z "$SINCE" ]; then
    # First run against a non-empty registry — look back 90 days.
    SINCE=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  fi

  feed_url="$DATALAKE_URL/api/v1/changes/feed?since=${SINCE}&limit=500"
  resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$feed_url")
  body=$(printf '%s' "$resp" | sed '$d')
  code=$(printf '%s' "$resp" | tail -n1)

  FEED_OK=1
  if [ "$code" != "200" ]; then
    echo "WARNING: seaduste muudatuste kontroll ebaõnnestus ($code) — vaata üle käsitsi"
    FEED_OK=0
    events='[]'
  else
    events=$(echo "$body" | jq '.items // []')
  fi

  # Match feed events against registered rt_ids (domain ignored — rt_id is identity).
  rt_ids_json=$(printf '%s\n' "$RT_IDS" | jq -R . | jq -s .)
  matched=$(echo "$events" | jq --argjson rts "$rt_ids_json" '[.[] | select(.rt_id as $r | $rts | index($r))]')

  # Re-detection while an issue is open (gh_issue_url != null) updates change info
  # but does NOT re-create an issue — surfaced as a reminder elsewhere.
  updated=$(jq --argjson matched "$matched" '
    reduce ($matched[]) as $e (.;
      .entries |= with_entries(
        if .value.rt_id == $e.rt_id then
          .value.needs_review = true
          | .value.change_detected_at = $e.detected_at
          | .value.change = {
              feed_event_id: $e.id,
              type: $e.change_type,
              summary: $e.description,
              effective_date: $e.effective_date
            }
        else . end
      )
    )
  ' "$REGISTRY")

  # Advance last_feed_check_at only on a clean query so a failed run retries the window.
  if [ "$FEED_OK" = "1" ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > "$REGISTRY"
  else
    echo "$updated" > "$REGISTRY"
  fi
fi

# Lifecycle re-check (feed-independent). The feed can miss a repeal/supersession.
# For each not-yet-flagged entry, re-fetch /citation and read status/in_force — a
# 200 + text does NOT mean the paragraph is still in force. Flag any served
# redaction that is no longer valid so it flows through the same fix path.
LC_SLUGS=$(jq -r '.entries | to_entries[] | select(.value.needs_review != true) | .key' "$REGISTRY")
while IFS= read -r lcslug; do
  [ -z "$lcslug" ] && continue
  lc_act=$(jq -r --arg s "$lcslug" '.entries[$s].act_id' "$REGISTRY")
  lc_resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$(lawyer_slug_cite_url "$lcslug")" 2>/dev/null || echo "")
  echo "$lc_resp" | jq empty 2>/dev/null || continue
  lc_status=$(echo "$lc_resp" | jq -r '.status // empty')
  lc_in_force=$(echo "$lc_resp" | jq -r 'if has("in_force") and .in_force != null then (.in_force|tostring) else "" end')
  lc_notvalid=0
  [ "$lc_in_force" = "false" ] && lc_notvalid=1
  { [ -n "$lc_status" ] && [ "$lc_status" != "valid" ]; } && lc_notvalid=1
  [ "$lc_notvalid" = "1" ] || continue
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg s "$lcslug" --arg st "$lc_status" --arg now "$NOW" '
    .entries[$s].needs_review = true
    | .entries[$s].status = (if $st == "" then .entries[$s].status else $st end)
    | .entries[$s].change_detected_at = $now
    | .entries[$s].change = {
        feed_event_id: null,
        type: "lifecycle",
        summary: ("Akt ei ole enam jõus (status=" + (if $st == "" then "not_in_force" else $st end) + ") — tuvastatud /citation elutsükli-kontrolliga, mitte feed-sündmusega"),
        effective_date: null
      }
  ' "$REGISTRY" > "${REGISTRY}.tmp"
  mv "${REGISTRY}.tmp" "$REGISTRY"
  echo "WARNING: $lcslug: akt $lc_act ei ole enam jõus (status=${lc_status:-not_in_force}) — märgitud läbivaatamiseks"
done <<< "$LC_SLUGS"

# Future-effective-date watch (feed- and lifecycle-independent). /changes/feed
# only reports events it detects; a postponement of a not-yet-in-force act's
# effective date is not itself an "event" the feed necessarily surfaces, so an
# entry can silently drift out of sync with reality. Poll RT directly for any
# entry carrying expected_effective_date and compare against the served
# redaction's "Jõustumise kp:" header. Best-effort: a curl failure or
# unparseable header skips that entry silently — never fails the run.
FE_SLUGS=$(jq -r '.entries | to_entries[] | select(.value.expected_effective_date != null and .value.needs_review != true) | .key' "$REGISTRY")
TODAY=$(date -u +%Y-%m-%d)
while IFS= read -r feslug; do
  [ -z "$feslug" ] && continue
  fe_rt_id=$(jq -r --arg s "$feslug" '.entries[$s].rt_id' "$REGISTRY")
  fe_expected=$(jq -r --arg s "$feslug" '.entries[$s].expected_effective_date' "$REGISTRY")
  [ -n "$fe_rt_id" ] || continue
  fe_html=$(curl --max-time 30 -s "$RT_PUBLIC_API/akt/${fe_rt_id}/blob-html" 2>/dev/null) || continue
  fe_new=$(printf '%s' "$fe_html" | lawyer_extract_effective_date 2>/dev/null) || continue
  [ -n "$fe_new" ] || continue
  if [ "$fe_new" != "$fe_expected" ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Re-baseline to the announced date so the same postponement is flagged
    # once, not again on every run after ack.
    jq --arg s "$feslug" --arg now "$NOW" --arg old "$fe_expected" --arg new "$fe_new" '
      .entries[$s].needs_review = true
      | .entries[$s].change_detected_at = $now
      | .entries[$s].expected_effective_date = $new
      | .entries[$s].change = {
          feed_event_id: null,
          type: "postponement",
          summary: ("Jõustumise kp muutus: " + $old + " -> " + $new),
          effective_date: $new
        }
    ' "$REGISTRY" > "${REGISTRY}.tmp"
    mv "${REGISTRY}.tmp" "$REGISTRY"
    echo "WARNING: $feslug: jõustumise kuupäev muutus ($fe_expected -> $fe_new) — märgitud läbivaatamiseks"
  elif [[ "$fe_expected" < "$TODAY" || "$fe_expected" == "$TODAY" ]]; then
    jq --arg s "$feslug" '.entries[$s].expected_effective_date = null' "$REGISTRY" > "${REGISTRY}.tmp"
    mv "${REGISTRY}.tmp" "$REGISTRY"
  fi
done <<< "$FE_SLUGS"
