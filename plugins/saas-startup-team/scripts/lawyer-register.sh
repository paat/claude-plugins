#!/usr/bin/env bash
# /lawyer register <slug> <act_id> <citation> <purpose> [--force]
# Registers one load-bearing Estonian legal paragraph: resolves act metadata,
# fetches + snapshots the paragraph text, and writes the registry entry.
# --force overrides the lifecycle guard (register a paragraph the datalake
# reports as not in force). Hard-fails without leaving a partial snapshot/entry.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

# Strip an optional --force flag from anywhere in the args before positional
# assignment.
FORCE=0
_args=()
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=1; else _args+=("$a"); fi
done
set -- "${_args[@]}"

SLUG="${1:-}"
ACT_ID="${2:-}"
CITATION="${3:-}"
PURPOSE="${4:-}"
if [ -z "$SLUG" ] || [ -z "$ACT_ID" ] || [ -z "$CITATION" ] || [ -z "$PURPOSE" ]; then
  echo "Usage: lawyer-register.sh <slug> <act_id> <citation> <purpose> [--force]"
  exit 1
fi

[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "Error: slug must match [a-z0-9-]+"; exit 1; }
[[ "$ACT_ID" =~ ^[0-9]+$ ]] || { echo "Error: act_id must be an integer — use /laws/search .id, not rt_id or RT URL segment"; exit 1; }

IFS='|' read -r PARAGRAPH PARAGRAPH_Q SECTION SECTION_Q POINT POINT_Q <<< "$(lawyer_parse_citation "$CITATION")"
[ -n "$PARAGRAPH" ] || { echo "Error: could not parse paragraph (§ N) from citation '$CITATION'"; exit 1; }

lawyer_registry_init
mkdir -p "$LAWS_DIR"

# Idempotency on (act_id, citation)
existing=$(jq -r --argjson act "$ACT_ID" --arg cit "$CITATION" \
  '.entries | to_entries[] | select(.value.act_id == $act and .value.citation == $cit) | .key' \
  "$REGISTRY")
if [ -n "$existing" ] && [ "$existing" != "$SLUG" ]; then
  echo "Entry (act_id=$ACT_ID, citation=$CITATION) already registered as '$existing'. Reusing; no action taken."
  exit 0
fi

# Resolve act metadata (rt_id, title, type) via the cheap /graph endpoint.
graph_resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/${ACT_ID}/graph")
graph_code=$(printf '%s' "$graph_resp" | tail -n1)
graph_body=$(printf '%s' "$graph_resp" | sed '$d')
if [ "$graph_code" != "200" ]; then
  echo "Error: /laws/${ACT_ID}/graph returned HTTP $graph_code — act_id is probably wrong"
  echo "       Try: $DATALAKE_URL/api/v1/laws/search?q=<act-name> to find the correct .id"
  exit 1
fi
RT_ID=$(echo "$graph_body" | jq -r '.act.rt_id // empty')
ACT_TITLE=$(echo "$graph_body" | jq -r '.act.title // "Teadmata seadus"')
ACT_TYPE=$(echo "$graph_body" | jq -r '.act.act_type // ""')
[ -n "$RT_ID" ] || { echo "Error: /laws/${ACT_ID}/graph has no .act.rt_id"; exit 1; }

cite_url=$(lawyer_cite_url "$ACT_ID" "$PARAGRAPH" "$PARAGRAPH_Q" "$SECTION" "$SECTION_Q" "$POINT" "$POINT_Q")
cite_resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
cite_code=$(printf '%s' "$cite_resp" | tail -n1)
cite_body=$(printf '%s' "$cite_resp" | sed '$d')
if [ "$cite_code" != "200" ]; then
  echo "Error: /laws/${ACT_ID}/citation returned HTTP $cite_code — citation '$CITATION' parses as paragraph=${PARAGRAPH}${PARAGRAPH_Q:+ (qual=$PARAGRAPH_Q)} section=${SECTION}${SECTION_Q:+ (qual=$SECTION_Q)} point=${POINT}${POINT_Q:+ (qual=$POINT_Q)}"
  exit 1
fi
text=$(echo "$cite_body" | jq -r '.text // empty')
REDAKTSIOON_URL=$(echo "$cite_body" | jq -r '.url // empty')
REDAKTSIOON_ID=""
if [ -n "$REDAKTSIOON_URL" ]; then
  tail_seg="${REDAKTSIOON_URL##*/akt/}"
  REDAKTSIOON_ID="${tail_seg%%[!0-9]*}"
fi
[ -n "$text" ] || { echo "Error: citation endpoint returned empty text"; exit 1; }

# Lifecycle guard — a 200 + text does NOT mean the law is in force. Refuse a
# repealed/superseded/never-in-force act unless --force. Absent fields (older
# datalake) are unknown → non-blocking.
CITE_STATUS=$(echo "$cite_body" | jq -r '.status // empty')
CITE_IN_FORCE=$(echo "$cite_body" | jq -r 'if has("in_force") and .in_force != null then (.in_force|tostring) else "" end')
REDAKTSIOON_DATE=$(echo "$cite_body" | jq -r '.redaktsioon_date // empty')
NOT_IN_FORCE=0
[ "$CITE_IN_FORCE" = "false" ] && NOT_IN_FORCE=1
{ [ -n "$CITE_STATUS" ] && [ "$CITE_STATUS" != "valid" ]; } && NOT_IN_FORCE=1
if [ "$NOT_IN_FORCE" = "1" ] && [ "$FORCE" != "1" ]; then
  echo "Error: act ${ACT_ID} is status=${CITE_STATUS:-unknown}, in_force=${CITE_IN_FORCE:-unknown} — not in force."
  echo "       Refusing to register a repealed/superseded/never-in-force paragraph as a load-bearing dependency."
  echo "       A 200 from /citation does NOT mean the law is current law. Re-check the act in Riigi Teataja,"
  echo "       or pass --force to override (e.g. you are intentionally tracking a soon-to-enter-force redaction)."
  exit 1
fi
if [ "$NOT_IN_FORCE" = "1" ]; then
  echo "WARNING: overriding lifecycle guard (--force): act ${ACT_ID} is status=${CITE_STATUS:-unknown}, in_force=${CITE_IN_FORCE:-unknown}."
fi

# Future-effective-date watch: store expected_effective_date when the served
# redaction is future-dated, or when --force overrode a not-yet-valid act — the
# /changes/feed cannot see a later postponement of either. Absent (null) for an
# already-effective act registered normally.
TODAY=$(date -u +%Y-%m-%d)
EXPECTED_EFFECTIVE_DATE=""
if [ -n "$REDAKTSIOON_DATE" ]; then
  if [[ "$REDAKTSIOON_DATE" > "$TODAY" ]] || { [ "$NOT_IN_FORCE" = "1" ] && [ "$FORCE" = "1" ]; }; then
    EXPECTED_EFFECTIVE_DATE="$REDAKTSIOON_DATE"
  fi
fi

# Write snapshot first — on crash before index write, re-run sees an orphan
# snapshot (warning), not an orphan index entry.
normalised=$(printf '%s' "$text" | lawyer_normalise)
printf '%s\n' "$normalised" > "${LAWS_DIR}/${SLUG}.txt" \
  || { echo "Error: could not write snapshot ${LAWS_DIR}/${SLUG}.txt — no registry entry written."; exit 1; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -n \
  --argjson act "$ACT_ID" \
  --arg rt "$RT_ID" \
  --arg red "$REDAKTSIOON_ID" \
  --arg title "$ACT_TITLE" \
  --arg atype "$ACT_TYPE" \
  --arg cit "$CITATION" \
  --arg para "$PARAGRAPH" \
  --arg para_q "$PARAGRAPH_Q" \
  --arg sec "$SECTION" \
  --arg sec_q "$SECTION_Q" \
  --arg pt "$POINT" \
  --arg pt_q "$POINT_Q" \
  --arg rturl "$REDAKTSIOON_URL" \
  --arg now "$NOW" \
  --arg by "${REGISTERED_BY:-lawyer}" \
  --arg purp "$PURPOSE" \
  --arg status "$CITE_STATUS" \
  --arg reddate "$REDAKTSIOON_DATE" \
  --arg expeff "$EXPECTED_EFFECTIVE_DATE" \
  '{
    act_id: $act,
    rt_id: $rt,
    redaktsioon_id: (if $red == "" then null else $red end),
    redaktsioon_date: (if $reddate == "" then null else $reddate end),
    status: (if $status == "" then null else $status end),
    expected_effective_date: (if $expeff == "" then null else $expeff end),
    act_title: $title,
    act_type: $atype,
    citation: $cit,
    citation_parts: {
      paragraph: $para,
      paragraph_qualifier: $para_q,
      section: $sec,
      section_qualifier: $sec_q,
      point: $pt,
      point_qualifier: $pt_q
    },
    rt_url: $rturl,
    registered_at: $now,
    verified_at: $now,
    registered_by: $by,
    purpose: $purp,
    needs_review: false,
    change_detected_at: null,
    change: null,
    gh_issue_url: null
  }')

jq --arg slug "$SLUG" --argjson e "$entry" '.entries[$slug] = $e' \
  "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

echo "Registered: $SLUG (act_id=$ACT_ID, rt_id=$RT_ID, $ACT_TITLE)"
echo "Lisa marker koodi: // LAW: $SLUG"
exit 0
