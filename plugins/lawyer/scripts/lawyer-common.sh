#!/usr/bin/env bash
# Shared helpers for the /lawyer subcommand scripts. Source this; do not execute.
#
# Every /lawyer script that talks to the datalake sources this file for:
#   - the DATALAKE_URL default (defined ONCE here, not scattered per call site),
#   - the superscript-aware citation-URL builder (was inlined 5x in lawyer.md),
#   - citation parsing, NFC normalisation, registry init, and the per-slug ack.

: "${DATALAKE_URL:=https://datalake.r-53.com}"
: "${RT_PUBLIC_API:=https://www.riigiteataja.ee/public-api/api/v1}"
REGISTRY=".startup/law-registry.json"
LAWS_DIR=".startup/laws"

# Ensure the registry file exists (schema v2). Missing file is fine — created here.
lawyer_registry_init() {
  mkdir -p "${REGISTRY%/*}"
  [ -f "$REGISTRY" ] || echo '{"version":2,"last_feed_check_at":null,"entries":{}}' > "$REGISTRY"
}

# Build a /citation URL. Args: act para para_q sec sec_q pt pt_q
# Qualifiers carry superscript digits (e.g. "1" for the ¹ in "lõige 1¹"); they are
# re-attached as unicode superscripts and URL-encoded — passing the bare digit
# fetches the wrong clause with a 200 OK.
lawyer_cite_url() {
  python3 -c '
import sys, urllib.parse
base, act, para, pq, sec, sq, pt, kq = sys.argv[1:9]
SUP = {"0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹"}
def enc(v, q): return urllib.parse.quote(v + "".join(SUP[c] for c in q))
parts = ["paragraph=" + enc(para, pq)]
if sec: parts.append("section=" + enc(sec, sq))
if pt:  parts.append("point="   + enc(pt,  kq))
print(f"{base}/api/v1/laws/{act}/citation?" + "&".join(parts))
' "$DATALAKE_URL" "$@"
}

# Build the /citation URL for a registered slug into SLUG_CITE_URL. Stored
# citation_parts are reconciled with the entry's citation via the parser: legacy
# v2 entries that predate the qualifier fields get them recovered from the
# citation (not persisted; recomputed per call). Any other mismatch, or an
# unparseable citation, sets SLUG_CITE_ERROR and returns 1 without a URL.
lawyer_slug_cite_url() {
  local s="$1" act cit stored parsed i
  local -a st pa
  SLUG_CITE_URL="" SLUG_CITE_ERROR=""
  act=$(jq -r --arg s "$s" '.entries[$s].act_id' "$REGISTRY")
  cit=$(jq -r --arg s "$s" '.entries[$s].citation // ""' "$REGISTRY")
  # "?" marks an absent qualifier field (legacy); bases default to "" as before.
  stored=$(jq -r --arg s "$s" '(.entries[$s].citation_parts // {}) as $c
    | [$c.paragraph // "", $c.paragraph_qualifier // "?", $c.section // "",
       $c.section_qualifier // "?", $c.point // "", $c.point_qualifier // "?"]
    | map(tostring) | join("|")' "$REGISTRY")
  parsed=$(lawyer_parse_citation "$cit")
  IFS='|' read -r st[0] st[1] st[2] st[3] st[4] st[5] <<< "$stored"
  IFS='|' read -r pa[0] pa[1] pa[2] pa[3] pa[4] pa[5] <<< "$parsed"
  for i in 0 2 4; do
    [ "${st[i+1]}" = "?" ] && st[i+1]="${pa[i+1]}"
  done
  if [ -z "${pa[0]}" ] || [ "${st[*]}" != "${pa[*]}" ]; then
    SLUG_CITE_ERROR="$s: citation_parts ($stored) do not match citation '$cit' ($parsed) — refusing to fetch a different clause; re-register the slug with its intended citation: /lawyer register $s $act \"<citation>\" \"<purpose>\""
    return 1
  fi
  SLUG_CITE_URL=$(lawyer_cite_url "$act" "${st[@]}")
}

# Parse an Estonian compound citation ("§ 10 lõige 1 punkt 3") into six
# pipe-separated fields: paragraph|para_q|section|sec_q|point|point_q. Pipe (not
# whitespace) keeps consecutive empty qualifiers from collapsing under bash read.
lawyer_parse_citation() {
  printf '%s' "$1" | python3 -c '
import re, sys
SUP_TO_ASCII = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹", "0123456789")
SUP = r"[⁰¹²³⁴-⁹]"
t = sys.stdin.read()
p = re.search(rf"§\s*(\d+)({SUP}*)", t)
s = re.search(rf"l[oõ]ige\s*(\d+)({SUP}*)", t, re.IGNORECASE)
k = re.search(rf"punkt\s*(\d+)({SUP}*)", t, re.IGNORECASE)
def parts(m):
    if not m: return ("", "")
    return (m.group(1), m.group(2).translate(SUP_TO_ASCII))
pb, pq = parts(p); sb, sq = parts(s); kb, kq = parts(k)
print("|".join([pb, pq, sb, sq, kb, kq]))
'
}

# Trim + NFC-normalise stdin.
lawyer_normalise() {
  python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))'
}

# Extract the "Jõustumise kp:" (effective date) header from a blob-html page and
# normalise dd.mm.yyyy to ISO (yyyy-mm-dd). blob-html is server-rendered HTML, not
# JSON — tags are stripped defensively so markup between the label and the date
# doesn't break the match. Prints nothing and exits 1 if the header is absent or
# unparseable; callers must treat that as best-effort and skip the entry.
lawyer_extract_effective_date() {
  python3 -c '
import re, sys
html = sys.stdin.read()
text = re.sub(r"<[^>]+>", " ", html)
text = text.replace("&nbsp;", " ")
m = re.search(r"J[oõ]ustumise\s+kp\.?:?\s*([0-3]?\d)\.([01]?\d)\.(\d{4})", text)
if not m:
    sys.exit(1)
d, mo, y = m.groups()
print(f"{int(y):04d}-{int(mo):02d}-{int(d):02d}")
'
}

# Extract the trailing numeric segment after /akt/ from an RT URL (e.g.
# https://www.riigiteataja.ee/akt/106032026010 -> 106032026010). Prints empty
# for an empty or unparsable URL.
lawyer_redaction_id_from_url() {
  local u="${1:-}" tail_seg id
  [ -n "$u" ] || return 0
  case "$u" in
    */akt/*)
      tail_seg="${u##*/akt/}"
      id="${tail_seg%%[!0-9]*}"
      [ -n "$id" ] && printf '%s\n' "$id"
      ;;
  esac
}

# Fetch and classify one /citation result. Globals CITE_* are reset per call;
# only a successful request with complete lifecycle evidence can be verified.
lawyer_fetch_citation() {
  local resp code
  CITE_BODY="" CITE_STATUS="" CITE_IN_FORCE=""
  CITE_LIFECYCLE=unknown CITE_FAILURE="transport failure"
  resp=$(curl --max-time 30 -s -w '\n%{http_code}' \
    -H "X-API-Key: $EST_DATALAKE_API_KEY" "$1") || return 0
  code=$(printf '%s' "$resp" | tail -n1)
  CITE_BODY=$(printf '%s' "$resp" | sed '$d')
  CITE_FAILURE="HTTP $code"
  [[ "$code" =~ ^2[0-9][0-9]$ ]] || return 0
  CITE_FAILURE="invalid response or missing lifecycle fields"
  CITE_LIFECYCLE=$(printf '%s' "$CITE_BODY" | jq -sr '
    if length != 1 then "unknown"
    elif (.[0] | type) != "object" then "unknown"
    else .[0] |
      if has("detail") or has("error") then "unknown"
      elif (.status | type) != "string" or .status == ""
        or (.in_force | type) != "boolean" then "unknown"
      elif .status == "valid" and .in_force == true then "verified-valid"
      else "verified-invalid" end
    end
  ' 2>/dev/null) || CITE_LIFECYCLE=unknown
  [ "$CITE_LIFECYCLE" != unknown ] || return 0
  CITE_STATUS=$(printf '%s' "$CITE_BODY" | jq -r '.status')
  CITE_IN_FORCE=$(printf '%s' "$CITE_BODY" | jq -r '.in_force')
  CITE_FAILURE=""
}

# Ack one slug: re-fetch /citation, require a verified-valid redaction, then refresh the
# snapshot and clear flags. Sets globals ACK_ACT_ID / ACK_STATUS / ACK_IN_FORCE for
# the caller's message. Returns: 0 ok, 2 empty-text, 3 not-in-force,
# 4 snapshot-write-failed (registry left untouched), 5 unknown lifecycle,
# 6 citation_parts irreconcilable with the citation (SLUG_CITE_ERROR; no fetch).
lawyer_ack_one() {
  local SLUG="$1" resp text cite_url_resp red ack_red_date ack_next_red_date NOW normalised
  ACK_ACT_ID=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' "$REGISTRY")
  lawyer_slug_cite_url "$SLUG" || return 6
  lawyer_fetch_citation "$SLUG_CITE_URL"
  ACK_STATUS="$CITE_STATUS" ACK_IN_FORCE="$CITE_IN_FORCE"
  case "$CITE_LIFECYCLE" in
    unknown) return 5 ;;
    verified-invalid) return 3 ;;
  esac
  resp="$CITE_BODY"
  text=$(echo "$resp" | jq -r '.text // empty')
  cite_url_resp=$(echo "$resp" | jq -r '.url // empty')
  red=$(lawyer_redaction_id_from_url "$cite_url_resp")
  [ -n "$text" ] || return 2

  ack_red_date=$(echo "$resp" | jq -r '.redaktsioon_date // empty')
  ack_next_red_date=$(echo "$resp" | jq -r '.next_redaktsioon_date // empty')

  # Snapshot first; only a verified write may clear registry flags.
  normalised=$(printf '%s' "$text" | lawyer_normalise)
  printf '%s\n' "$normalised" > "${LAWS_DIR}/${SLUG}.txt" || return 4

  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg slug "$SLUG" --arg now "$NOW" --arg red "$red" --arg rturl "$cite_url_resp" \
     --arg st "$ACK_STATUS" --arg reddate "$ack_red_date" --arg nextdate "$ack_next_red_date" '
    .entries[$slug].needs_review = false
    | .entries[$slug].change = null
    | .entries[$slug].change_detected_at = null
    | .entries[$slug].verified_at = $now
    | .entries[$slug].redaktsioon_id = (if $red == "" then null else $red end)
    | .entries[$slug].redaktsioon_date = (if $reddate == "" then .entries[$slug].redaktsioon_date else $reddate end)
    | .entries[$slug].next_redaktsioon_date = (if $nextdate == "" then null else $nextdate end)
    | .entries[$slug].status = (if $st == "" then .entries[$slug].status else $st end)
    | .entries[$slug].rt_url = (if $rturl == "" then .entries[$slug].rt_url else $rturl end)
  ' "$REGISTRY" > "${REGISTRY}.tmp"
  mv "${REGISTRY}.tmp" "$REGISTRY"
  return 0
}
