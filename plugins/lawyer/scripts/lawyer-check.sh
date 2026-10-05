#!/usr/bin/env bash
# /lawyer change detection. Runs the feed poll + feed-independent lifecycle
# re-check and persists new flags. Reads only the index JSON; snapshots untouched.
# Used by both the `check` subcommand and the start of every /lawyer run.
# Prints only WARNING lines; the caller prints any completion summary.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

[ -f "$REGISTRY" ] || { echo "Registry is empty; nothing to check."; exit 0; }

# Set when the change feed does not prove the window. Same exit as an unknown lifecycle.
FEED_INCOMPLETE=0
FEED_SATURATED=0
FEED_SATURATED_SOLO=0
FEED_LIMIT=500
FEED_REQUESTED_AT=""
SATURATED_MSG="window is saturated and cannot advance (limit=${FEED_LIMIT}, no continuation parameter)"

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

  # datalake-api.md: since, limit, and domain only — no offset or next page.
  # A page that fills limit is unproven; do not invent a continuation parameter.
  feed_url="$DATALAKE_URL/api/v1/changes/feed?since=${SINCE}&limit=${FEED_LIMIT}"
  # Issued-at, not processed-at: events that arrive during the request stay in the next window.
  FEED_REQUESTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  curl_rc=0
  resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$feed_url") || curl_rc=$?
  body=$(printf '%s' "$resp" | sed '$d')
  code=$(printf '%s' "$resp" | tail -n1)
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *) code=000 ;;
  esac

  events='[]'
  feed_reason=""
  feed_add_reason() {
    if [ -n "$feed_reason" ]; then
      feed_reason="$feed_reason; $1"
    else
      feed_reason="$1"
    fi
  }

  # Usable items are still applied when the page itself is partial, warned, or full.
  # Non-2xx, transport failure, and schema-invalid bodies are not a feed page.
  if [ "$curl_rc" -ne 0 ]; then
    feed_add_reason "transport (HTTP $code)"
  else
    case "$code" in
      2[0-9][0-9]) feed_http_ok=1 ;;
      *) feed_http_ok=0 ;;
    esac
    if [ "$feed_http_ok" != 1 ]; then
      feed_add_reason "HTTP $code"
    elif ! printf '%s' "$body" | jq -e 'type == "object" and (.items | type) == "array"' >/dev/null 2>&1; then
      feed_add_reason "malformed or schema-invalid feed"
    else
      events=$(printf '%s' "$body" | jq -c '.items')
      partial_flag=$(printf '%s' "$body" | jq -r 'if .partial == true then "yes" else "no" end')
      warn_flag=$(printf '%s' "$body" | jq -r 'if .warnings == null then "no" elif (.warnings | type) != "array" then "yes" elif (.warnings | length) > 0 then "yes" else "no" end')
      item_count=$(printf '%s' "$events" | jq -r 'length')
      [ "$partial_flag" = "yes" ] && feed_add_reason "partial"
      [ "$warn_flag" = "yes" ] && feed_add_reason "warnings"
      if [ "$item_count" -ge "$FEED_LIMIT" ]; then
        # Item order and whether since is inclusive are undocumented, so a full
        # page must not move last_feed_check_at past events this page did not return.
        FEED_SATURATED=1
      fi
    fi
  fi

  # Match feed events against registered rt_ids (domain ignored — rt_id is identity).
  rt_ids_json=$(printf '%s\n' "$RT_IDS" | jq -R . | jq -s .)
  matched=$(printf '%s' "$events" | jq -c --argjson rts "$rt_ids_json" '[.[] | select(.rt_id as $r | $rts | index($r))]') || {
    matched='[]'
    # A failed match is not an empty page: keep the cursor so the event is not skipped.
    feed_add_reason "feed item match failed"
  }

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
  ' "$REGISTRY") || updated=""

  if [ -z "$updated" ]; then
    feed_add_reason "registry update failed"
  fi
  if [ "$FEED_SATURATED" -eq 1 ]; then
    if [ -z "$feed_reason" ]; then
      FEED_SATURATED_SOLO=1
    else
      feed_add_reason "$SATURATED_MSG"
    fi
  fi
  if [ -n "$feed_reason" ]; then
    echo "WARNING: seaduste muudatuste kontroll ebaõnnestus ($feed_reason) — vaata üle käsitsi; incomplete coverage" >&2
    FEED_INCOMPLETE=1
  fi
  # Write beside the registry and replace it only after jq succeeds, so a bad
  # body cannot truncate last_feed_check_at or an existing pending flag.
  if [ -n "$updated" ]; then
    write_ok=0
    if [ -z "$feed_reason" ] && [ "$FEED_SATURATED_SOLO" -eq 0 ]; then
      printf '%s' "$updated" | jq --arg now "$FEED_REQUESTED_AT" '.last_feed_check_at = $now' > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY" && write_ok=1
    else
      printf '%s' "$updated" | jq '.' > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY" && write_ok=1
    fi
    if [ "$write_ok" = 0 ]; then
      rm -f "${REGISTRY}.tmp"
      if [ "$FEED_INCOMPLETE" -eq 0 ]; then
        feed_add_reason "registry write failed"
        if [ "$FEED_SATURATED_SOLO" -eq 1 ]; then
          feed_add_reason "$SATURATED_MSG"
        fi
        echo "WARNING: seaduste muudatuste kontroll ebaõnnestus ($feed_reason) — vaata üle käsitsi; incomplete coverage" >&2
      fi
      FEED_INCOMPLETE=1
      FEED_SATURATED_SOLO=0
    fi
  fi
fi

# Lifecycle re-check (feed-independent). The feed can miss a repeal/supersession.
# For each not-yet-flagged entry, re-fetch /citation and read status/in_force — a
# 200 + text does NOT mean the paragraph is still in force. Flag any served
# redaction that is no longer valid so it flows through the same fix path.
LC_SLUGS=$(jq -r '.entries | to_entries[] | select(.value.needs_review != true) | .key' "$REGISTRY")
LC_INCOMPLETE=0
LC_ACT_UNPROVEN=0
LC_NEXT_UNKNOWN=0
while IFS= read -r lcslug; do
  [ -z "$lcslug" ] && continue
  lc_act=$(jq -r --arg s "$lcslug" '.entries[$s].act_id' "$REGISTRY")
  if ! lawyer_slug_cite_url "$lcslug"; then
    echo "WARNING: $SLUG_CITE_ERROR — incomplete coverage; snapshot and review flags kept." >&2
    LC_INCOMPLETE=1
    continue
  fi
  lawyer_fetch_citation "$SLUG_CITE_URL"
  case "$CITE_LIFECYCLE" in
    unknown)
      echo "WARNING: $lcslug: citation lifecycle unknown ($CITE_FAILURE) — incomplete coverage; snapshot and review flags kept." >&2
      LC_INCOMPLETE=1
      continue ;;
    verified-valid)
      text=$(printf '%s' "$CITE_BODY" | jq -r '.text // empty')
      if [ -z "$text" ]; then
        echo "WARNING: $lcslug: citation text empty — incomplete coverage; snapshot and review flags kept." >&2
        LC_INCOMPLETE=1
        continue
      fi
      normalised=$(printf '%s' "$text" | lawyer_normalise)
      if [ -z "$normalised" ]; then
        echo "WARNING: $lcslug: citation text empty — incomplete coverage; snapshot and review flags kept." >&2
        LC_INCOMPLETE=1
        continue
      fi
      snap="${LAWS_DIR}/${lcslug}.txt"
      if [ ! -f "$snap" ] || [ ! -r "$snap" ]; then
        echo "WARNING: $lcslug: snapshot missing or unreadable — incomplete coverage; snapshot and review flags kept." >&2
        LC_INCOMPLETE=1
        continue
      fi
      if printf '%s\n' "$normalised" | cmp -s - "$snap"; then
        cite_url_val=$(printf '%s' "$CITE_BODY" | jq -r '.url // empty')
        served=$(lawyer_redaction_id_from_url "$cite_url_val")
        stored=$(jq -r --arg s "$lcslug" '.entries[$s].redaktsioon_id // empty' "$REGISTRY")
        rt=$(jq -r --arg s "$lcslug" '.entries[$s].rt_id // empty' "$REGISTRY")

        if [ -n "$stored" ] && [ -n "$served" ] && [ "$stored" != "$rt" ] && [ "$served" != "$rt" ] && [ "$served" != "$stored" ]; then
          cite_red_date=$(printf '%s' "$CITE_BODY" | jq -r '.redaktsioon_date // empty')
          NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          if jq --arg s "$lcslug" --arg now "$NOW" --arg stored "$stored" --arg served "$served" --arg reddate "$cite_red_date" '
            .entries[$s].needs_review = true
            | .entries[$s].change_detected_at = $now
            | .entries[$s].change = {
                feed_event_id: null,
                type: "redaction_change",
                summary: ("Akti redaktsioon muutus (" + $stored + " -> " + $served + "); tsiteeritud tekst on sama — kontrolli akti muid muudatusi"),
                effective_date: (if $reddate == "" then null else $reddate end)
              }
          ' "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY"; then
            echo "WARNING: $lcslug: akti redaktsioon muutus ($stored -> $served) — märgitud läbivaatamiseks"
          else
            rm -f "${REGISTRY}.tmp"
            echo "WARNING: $lcslug: registry write failed — incomplete coverage; snapshot and review flags kept." >&2
            LC_INCOMPLETE=1
          fi
          continue
        fi

        if [ -z "$stored" ] || [ "$stored" = "$rt" ] || [ -z "$served" ] || [ "$served" = "$rt" ]; then
          if [ "$FEED_SATURATED_SOLO" -eq 1 ]; then
            reason=""
            if [ -z "$stored" ] || [ "$stored" = "$rt" ]; then
              reason="stored redaktsioon_id missing or not redaction-unique — run /lawyer ack $lcslug"
            else
              reason="served citation URL has no redaction-unique id"
            fi
            echo "WARNING: $lcslug: akti redaktsiooni ei saa tõendada ($reason) — incomplete coverage; snapshot and review flags kept." >&2
            LC_ACT_UNPROVEN=1
          fi
        fi

        has_next=$(printf '%s' "$CITE_BODY" | jq -r 'has("next_redaktsioon_date")')
        if [ "$has_next" = "true" ]; then
          served_next_date=$(printf '%s' "$CITE_BODY" | jq -r '.next_redaktsioon_date // empty')
          stored_next_date=$(jq -r --arg s "$lcslug" '.entries[$s].next_redaktsioon_date // empty' "$REGISTRY")
          if [ -n "$served_next_date" ] && [ "$served_next_date" != "$stored_next_date" ]; then
            NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if jq --arg s "$lcslug" --arg now "$NOW" --arg nextdate "$served_next_date" '
              .entries[$s].needs_review = true
              | .entries[$s].change_detected_at = $now
              | .entries[$s].change = {
                  feed_event_id: null,
                  type: "future_amendment",
                  summary: ("Aktile on avaldatud tulevane redaktsioon (jõustub " + $nextdate + ") — kontrolli muudatust enne jõustumist"),
                  effective_date: $nextdate
                }
            ' "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY"; then
              echo "WARNING: $lcslug: aktile on avaldatud tulevane redaktsioon (jõustub $served_next_date) — märgitud läbivaatamiseks"
            else
              rm -f "${REGISTRY}.tmp"
              echo "WARNING: $lcslug: registry write failed — incomplete coverage; snapshot and review flags kept." >&2
              LC_INCOMPLETE=1
            fi
          fi
        else
          LC_NEXT_UNKNOWN=1
        fi
        continue
      fi
      NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      if jq --arg s "$lcslug" --arg now "$NOW" '
        .entries[$s].needs_review = true
        | .entries[$s].change_detected_at = $now
        | .entries[$s].change = {
            feed_event_id: null,
            type: "text_change",
            summary: "Tsiteeritud tekst erineb hetktõmmisest — tuvastatud /citation otsevõrdlusega, mitte feed-sündmusega",
            effective_date: null
          }
      ' "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY"; then
        echo "WARNING: $lcslug: tsiteeritud tekst erineb hetktõmmisest — märgitud läbivaatamiseks"
      else
        rm -f "${REGISTRY}.tmp"
        echo "WARNING: $lcslug: registry write failed — incomplete coverage; snapshot and review flags kept." >&2
        LC_INCOMPLETE=1
      fi
      continue ;;
  esac
  lc_status="$CITE_STATUS"
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

# Saturation fallback: advance cursor when all unflagged entries are proven directly.
if [ "$FEED_SATURATED_SOLO" -eq 1 ]; then
  if [ "$LC_INCOMPLETE" -eq 0 ] && [ "$LC_ACT_UNPROVEN" -eq 0 ]; then
    write_ok=0
    jq --arg now "$FEED_REQUESTED_AT" '.last_feed_check_at = $now' "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY" && write_ok=1
    if [ "$write_ok" = 0 ]; then
      rm -f "${REGISTRY}.tmp"
      echo "WARNING: seaduste muudatuste kontroll ebaõnnestus (registry write failed) — vaata üle käsitsi; incomplete coverage" >&2
      FEED_INCOMPLETE=1
    elif [ "$LC_NEXT_UNKNOWN" -eq 1 ]; then
      echo "NOTE: muudatuste aken oli küllastunud; tulevaste redaktsioonide etteteatamist ei saa tõendada (/citation ei tagasta next_redaktsioon_date)"
    fi
  else
    echo "WARNING: seaduste muudatuste kontroll ebaõnnestus ($SATURATED_MSG) — vaata üle käsitsi; incomplete coverage" >&2
    FEED_INCOMPLETE=1
  fi
fi

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
    # Re-baseline to the announced date so the same postponement/acceleration
    # is flagged once, not again on every run after ack. ISO date strings
    # compare correctly lexicographically; equality can't reach this branch
    # (guarded by the != check above).
    jq --arg s "$feslug" --arg now "$NOW" --arg old "$fe_expected" --arg new "$fe_new" '
      ($new > $old) as $later
      | .entries[$s].needs_review = true
      | .entries[$s].change_detected_at = $now
      | .entries[$s].expected_effective_date = $new
      | .entries[$s].change = {
          feed_event_id: null,
          type: (if $later then "postponement" else "acceleration" end),
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

check_rc=0
if [ "$FEED_INCOMPLETE" -ne 0 ] || [ "$LC_INCOMPLETE" -ne 0 ]; then
  check_rc=1
fi
exit "$check_rc"
