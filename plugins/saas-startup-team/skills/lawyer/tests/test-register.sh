#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup

# Mock datalake: route by URL path pattern.
# /graph matches as path suffix only (NOT "paragraph=..." in query string —
# that was the subtle bug that made the original mock route citation calls to
# the graph fixture and register to fail with "empty text").
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */graph)     cat "$FIXTURES/datalake/graph-iks.json"; printf '\n200'; exit 0 ;;
    */citation*) cat "$FIXTURES/datalake/citation-consent.json"; printf '\n200'; exit 0 ;;
  esac
done
echo '{}'; printf '\n200'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key
export DATALAKE_URL=https://datalake.r-53.com

# ---- inlined register flow (mirrors commands/lawyer.md § Register subcommand) ----
SLUG="consent-lawful-basis"
ACT_ID="30087"
CITATION="§ 10 lõige 1"
PURPOSE="Lawful basis for processing credit-default disclosures"

[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "FAIL: slug regex"; exit 1; }
[[ "$ACT_ID" =~ ^[0-9]+$ ]] || { echo "FAIL: act_id must be integer"; exit 1; }

read -r PARAGRAPH SECTION POINT <<< "$(printf '%s' "$CITATION" | python3 -c '
import re, sys
t = sys.stdin.read()
p = re.search(r"§\s*(\d+)", t)
s = re.search(r"l[oõ]ige\s*(\d+)", t, re.IGNORECASE)
k = re.search(r"punkt\s*(\d+)", t, re.IGNORECASE)
print((p.group(1) if p else ""), (s.group(1) if s else ""), (k.group(1) if k else ""))
')"
[ "$PARAGRAPH" = "10" ] || { echo "FAIL: paragraph parse (expected 10, got $PARAGRAPH)"; exit 1; }
[ "$SECTION" = "1" ] || { echo "FAIL: section parse (expected 1, got $SECTION)"; exit 1; }

[ -f .startup/law-registry.json ] || echo '{"version":2,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json
mkdir -p .startup/laws

# Graph call (rt_id resolution)
graph_resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/${ACT_ID}/graph")
graph_code=$(printf '%s' "$graph_resp" | tail -n1)
graph_body=$(printf '%s' "$graph_resp" | sed '$d')
[ "$graph_code" = "200" ] || { echo "FAIL: graph HTTP $graph_code"; exit 1; }
RT_ID=$(echo "$graph_body" | jq -r '.act.rt_id // empty')
ACT_TITLE=$(echo "$graph_body" | jq -r '.act.title // "?"')
ACT_TYPE=$(echo "$graph_body" | jq -r '.act.act_type // ""')
[ -n "$RT_ID" ] || { echo "FAIL: rt_id missing from graph"; exit 1; }

# Citation call (text + redaktsioon_id extraction)
cite_url="$DATALAKE_URL/api/v1/laws/${ACT_ID}/citation?paragraph=${PARAGRAPH}&section=${SECTION}"
cite_resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
cite_code=$(printf '%s' "$cite_resp" | tail -n1)
cite_body=$(printf '%s' "$cite_resp" | sed '$d')
[ "$cite_code" = "200" ] || { echo "FAIL: citation HTTP $cite_code"; exit 1; }
text=$(echo "$cite_body" | jq -r '.text // empty')
REDAKTSIOON_URL=$(echo "$cite_body" | jq -r '.url // empty')
REDAKTSIOON_ID=""
if [ -n "$REDAKTSIOON_URL" ]; then
  tail_seg="${REDAKTSIOON_URL##*/akt/}"
  REDAKTSIOON_ID="${tail_seg%%[!0-9]*}"
fi
[ -n "$text" ] || { echo "FAIL: empty text"; exit 1; }

normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -n \
  --argjson act "$ACT_ID" \
  --arg rt "$RT_ID" \
  --arg red "$REDAKTSIOON_ID" \
  --arg title "$ACT_TITLE" \
  --arg atype "$ACT_TYPE" \
  --arg cit "$CITATION" \
  --arg para "$PARAGRAPH" \
  --arg sec "$SECTION" \
  --arg pt "$POINT" \
  --arg rturl "$REDAKTSIOON_URL" \
  --arg now "$NOW" \
  --arg by "lawyer" \
  --arg purp "$PURPOSE" \
  '{act_id:$act, rt_id:$rt, redaktsioon_id:(if $red=="" then null else $red end), act_title:$title, act_type:$atype, citation:$cit, citation_parts:{paragraph:$para, section:$sec, point:$pt}, rt_url:$rturl, registered_at:$now, verified_at:$now, registered_by:$by, purpose:$purp, needs_review:false, change_detected_at:null, change:null, gh_issue_url:null}')

jq --arg slug "$SLUG" --argjson e "$entry" \
  '.entries[$slug] = $e' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

# ---- assertions ----
[ -f ".startup/laws/${SLUG}.txt" ] || { echo "FAIL: snapshot missing"; exit 1; }

stored_act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
[ "$stored_act_id" = "30087" ] || { echo "FAIL: act_id expected 30087, got $stored_act_id"; exit 1; }
# act_id must be stored as integer (number), not string
[ "$(jq -r --arg s "$SLUG" '.entries[$s].act_id | type' .startup/law-registry.json)" = "number" ] \
  || { echo "FAIL: act_id stored as non-number"; exit 1; }

stored_rt_id=$(jq -r --arg s "$SLUG" '.entries[$s].rt_id' .startup/law-registry.json)
[ "$stored_rt_id" = "1045568" ] || { echo "FAIL: rt_id expected 1045568, got $stored_rt_id"; exit 1; }

stored_red=$(jq -r --arg s "$SLUG" '.entries[$s].redaktsioon_id' .startup/law-registry.json)
[ "$stored_red" = "106032026010" ] || { echo "FAIL: redaktsioon_id expected 106032026010, got $stored_red"; exit 1; }

parts_p=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.paragraph' .startup/law-registry.json)
parts_s=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.section' .startup/law-registry.json)
[ "$parts_p" = "10" ] && [ "$parts_s" = "1" ] || { echo "FAIL: citation_parts not stored (got paragraph=$parts_p section=$parts_s)"; exit 1; }

purpose_back=$(jq -r --arg s "$SLUG" '.entries[$s].purpose' .startup/law-registry.json)
[ "$purpose_back" = "$PURPOSE" ] || { echo "FAIL: purpose roundtrip"; exit 1; }

echo "PASS: test-register"
