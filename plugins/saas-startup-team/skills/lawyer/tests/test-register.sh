#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

# Isolated project workspace
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup

# Mock datalake: intercept curl calls by shadowing via PATH
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
# Echo the fixture matching the requested act/paragraph
for arg in "\$@"; do
  case "\$arg" in
    *citation*paragraph*) cat "$FIXTURES/datalake/citation-consent.json"; exit 0 ;;
  esac
done
echo '{}'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key

# Inline the register flow here for testability
SLUG=consent-lawful-basis
ACT_ID=104052024010
CITATION="§ 10 lõige 2"
PURPOSE="Lawful basis for signup-confirmation email"

# Create empty registry if missing
[ -f .startup/law-registry.json ] || echo '{"version":1,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json
mkdir -p .startup/laws

# Idempotency check: does an entry with this (act_id, citation) already exist?
existing=$(jq -r --arg act "$ACT_ID" --arg cit "$CITATION" \
  '.entries | to_entries[] | select(.value.act_id == $act and .value.citation == $cit) | .key' \
  .startup/law-registry.json)
if [ -n "$existing" ] && [ "$existing" != "$SLUG" ]; then
  echo "FAIL: expected no duplicate; got existing=$existing"
  exit 1
fi

# Fetch paragraph text
response=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${ACT_ID}/citation?paragraph=${CITATION}")
text=$(echo "$response" | jq -r '.text // empty')
# Mirror the production extraction: bare jq keeps redaktsioon as JSON scalar
# (quoted string or null literal) so --argjson below doesn't crash when the
# datalake returns a non-null id.
redaktsioon=$(echo "$response" | jq '.redaktsioon_id // null')
[ -n "$text" ] || { echo "FAIL: empty text"; exit 1; }

# Normalise
normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')

# Write snapshot
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

# Upsert entry
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -n \
  --arg act "$ACT_ID" \
  --arg title "Isikuandmete kaitse seadus" \
  --arg cit "$CITATION" \
  --arg dom "Data Protection" \
  --arg rt "https://www.riigiteataja.ee/akt/${ACT_ID}" \
  --argjson redaktsioon "$redaktsioon" \
  --arg now "$NOW" \
  --arg by "lawyer" \
  --arg purp "$PURPOSE" \
  '{act_id:$act, act_title:$title, citation:$cit, domain:$dom, rt_url:$rt, redaktsioon_id:$redaktsioon, registered_at:$now, verified_at:$now, registered_by:$by, purpose:$purp, needs_review:false, change_detected_at:null, change:null, gh_issue_url:null}')

jq --arg slug "$SLUG" --argjson e "$entry" \
  '.entries[$slug] = $e' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

# Assertions
[ -f ".startup/laws/${SLUG}.txt" ] || { echo "FAIL: snapshot missing"; exit 1; }
stored=$(jq -r --arg slug "$SLUG" '.entries[$slug].act_id' .startup/law-registry.json)
[ "$stored" = "$ACT_ID" ] || { echo "FAIL: expected act_id=$ACT_ID, got $stored"; exit 1; }
purpose_back=$(jq -r --arg slug "$SLUG" '.entries[$slug].purpose' .startup/law-registry.json)
[ "$purpose_back" = "$PURPOSE" ] || { echo "FAIL: purpose roundtrip"; exit 1; }
# Verify the redaktsioon_id round-tripped through --argjson correctly — this
# guards against the --argjson crash that happens when redaktsioon is captured
# with `jq -r` (bare string) instead of bare jq (JSON scalar).
redaktsioon_back=$(jq -r --arg slug "$SLUG" '.entries[$slug].redaktsioon_id // "null"' .startup/law-registry.json)
[ "$redaktsioon_back" = "104052024010/1" ] || { echo "FAIL: expected redaktsioon_id=104052024010/1, got $redaktsioon_back"; exit 1; }

echo "PASS: test-register"
