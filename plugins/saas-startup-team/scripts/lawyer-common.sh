#!/usr/bin/env bash
# Shared helpers for the /lawyer subcommand scripts. Source this; do not execute.
#
# Every /lawyer script that talks to the datalake sources this file for:
#   - the DATALAKE_URL default (defined ONCE here, not scattered per call site),
#   - the superscript-aware citation-URL builder (was inlined 5x in lawyer.md),
#   - citation parsing, NFC normalisation, registry init, and the per-slug ack.

: "${DATALAKE_URL:=https://datalake.r-53.com}"
REGISTRY=".startup/law-registry.json"
LAWS_DIR=".startup/laws"

# Ensure the registry file exists (schema v2). Missing file is fine — created here.
lawyer_registry_init() {
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

# Build a /citation URL for a registered slug (reads citation_parts from registry).
lawyer_slug_cite_url() {
  local s="$1"
  lawyer_cite_url \
    "$(jq -r --arg s "$s" '.entries[$s].act_id' "$REGISTRY")" \
    "$(jq -r --arg s "$s" '.entries[$s].citation_parts.paragraph // ""' "$REGISTRY")" \
    "$(jq -r --arg s "$s" '.entries[$s].citation_parts.paragraph_qualifier // ""' "$REGISTRY")" \
    "$(jq -r --arg s "$s" '.entries[$s].citation_parts.section // ""' "$REGISTRY")" \
    "$(jq -r --arg s "$s" '.entries[$s].citation_parts.section_qualifier // ""' "$REGISTRY")" \
    "$(jq -r --arg s "$s" '.entries[$s].citation_parts.point // ""' "$REGISTRY")" \
    "$(jq -r --arg s "$s" '.entries[$s].citation_parts.point_qualifier // ""' "$REGISTRY")"
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

# Ack one slug: re-fetch /citation, refuse a non-valid redaction, else refresh the
# snapshot and clear flags. Sets globals ACK_ACT_ID / ACK_STATUS / ACK_IN_FORCE for
# the caller's message. Returns: 0 ok, 2 empty-text, 3 not-in-force,
# 4 snapshot-write-failed (registry left untouched).
lawyer_ack_one() {
  local SLUG="$1" resp text cite_url_resp red tail_seg ack_red_date ack_notvalid NOW normalised
  ACK_ACT_ID=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' "$REGISTRY")
  resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$(lawyer_slug_cite_url "$SLUG")")
  text=$(echo "$resp" | jq -r '.text // empty')
  cite_url_resp=$(echo "$resp" | jq -r '.url // empty')
  red=""
  if [ -n "$cite_url_resp" ]; then
    tail_seg="${cite_url_resp##*/akt/}"
    red="${tail_seg%%[!0-9]*}"
  fi
  [ -n "$text" ] || return 2

  # Lifecycle guard — a 200 + text does NOT mean the law is in force. Refuse to
  # re-bless a repealed/superseded/not-in-force redaction.
  ACK_STATUS=$(echo "$resp" | jq -r '.status // empty')
  ACK_IN_FORCE=$(echo "$resp" | jq -r 'if has("in_force") and .in_force != null then (.in_force|tostring) else "" end')
  ack_red_date=$(echo "$resp" | jq -r '.redaktsioon_date // empty')
  ack_notvalid=0
  [ "$ACK_IN_FORCE" = "false" ] && ack_notvalid=1
  { [ -n "$ACK_STATUS" ] && [ "$ACK_STATUS" != "valid" ]; } && ack_notvalid=1
  [ "$ack_notvalid" = "1" ] && return 3

  # Snapshot first; only a verified write may clear registry flags.
  normalised=$(printf '%s' "$text" | lawyer_normalise)
  printf '%s\n' "$normalised" > "${LAWS_DIR}/${SLUG}.txt" || return 4

  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg slug "$SLUG" --arg now "$NOW" --arg red "$red" --arg rturl "$cite_url_resp" \
     --arg st "$ACK_STATUS" --arg reddate "$ack_red_date" '
    .entries[$slug].needs_review = false
    | .entries[$slug].change = null
    | .entries[$slug].change_detected_at = null
    | .entries[$slug].verified_at = $now
    | .entries[$slug].redaktsioon_id = (if $red == "" then null else $red end)
    | .entries[$slug].redaktsioon_date = (if $reddate == "" then .entries[$slug].redaktsioon_date else $reddate end)
    | .entries[$slug].status = (if $st == "" then .entries[$slug].status else $st end)
    | .entries[$slug].rt_url = (if $rturl == "" then .entries[$slug].rt_url else $rturl end)
  ' "$REGISTRY" > "${REGISTRY}.tmp"
  mv "${REGISTRY}.tmp" "$REGISTRY"
  return 0
}
