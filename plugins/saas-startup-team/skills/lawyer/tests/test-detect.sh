#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry (v2): one entry with rt_id=1045568 (matches fixture feed event 45037).
# A second rt_id (163383) is in the feed fixture too; we should NOT flag anything for it because it's not registered.
cat > .startup/law-registry.json <<'EOF'
{
  "version": 2,
  "last_feed_check_at": "2026-04-20T00:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": 30087,
      "rt_id": "1045568",
      "redaktsioon_id": "106032026010",
      "act_title": "Isikuandmete kaitse seadus",
      "act_type": "seadus",
      "citation": "§ 10 lõige 1",
      "citation_parts": {"paragraph": "10", "section": "1", "point": ""},
      "rt_url": "https://www.riigiteataja.ee/akt/106032026010",
      "registered_at": "2026-04-01T00:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "test",
      "needs_review": false,
      "change_detected_at": null,
      "change": null,
      "gh_issue_url": null
    }
  }
}
EOF
echo "Isikuandmete töötlemine on lubatud ..." > .startup/laws/consent-lawful-basis.txt

# Mock datalake
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *changes/feed*) cat "$FIXTURES/datalake/feed-data-protection.json"; printf '\n200'; exit 0 ;;
  esac
done
echo '{}'; printf '\n200'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key
export DATALAKE_URL=https://datalake.r-53.com

# ---- inlined Change Detection (mirrors commands/lawyer.md § Change Detection) ----
RT_IDS=$(jq -r '.entries | to_entries[] | .value.rt_id // empty' .startup/law-registry.json | sort -u)

SINCE=$(jq -r '.last_feed_check_at // ""' .startup/law-registry.json)
feed_url="$DATALAKE_URL/api/v1/changes/feed?since=${SINCE}&limit=500"
resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$feed_url")
body=$(printf '%s' "$resp" | sed '$d')
code=$(printf '%s' "$resp" | tail -n1)
[ "$code" = "200" ] || { echo "FAIL: feed HTTP $code"; exit 1; }

events=$(echo "$body" | jq '.items // []')
[ "$(echo "$events" | jq 'length')" = "2" ] || { echo "FAIL: expected 2 feed items"; exit 1; }

rt_ids_json=$(printf '%s\n' "$RT_IDS" | jq -R . | jq -s .)
matched=$(echo "$events" | jq --argjson rts "$rt_ids_json" '[.[] | select(.rt_id as $r | $rts | index($r))]')
# Only event 45037 (rt_id=1045568) should match; 45038 (rt_id=163383) is for an unregistered act
[ "$(echo "$matched" | jq 'length')" = "1" ] || { echo "FAIL: expected 1 matched event, got $(echo "$matched" | jq 'length')"; exit 1; }

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
' .startup/law-registry.json)

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > .startup/law-registry.json

# ---- assertions ----
flagged=$(jq -r '.entries["consent-lawful-basis"].needs_review' .startup/law-registry.json)
[ "$flagged" = "true" ] || { echo "FAIL: expected needs_review=true, got $flagged"; exit 1; }

change_type=$(jq -r '.entries["consent-lawful-basis"].change.type' .startup/law-registry.json)
[ "$change_type" = "amendment" ] || { echo "FAIL: expected change.type=amendment, got $change_type"; exit 1; }

feed_event_id=$(jq -r '.entries["consent-lawful-basis"].change.feed_event_id' .startup/law-registry.json)
[ "$feed_event_id" = "45037" ] || { echo "FAIL: expected feed_event_id=45037, got $feed_event_id"; exit 1; }

effective=$(jq -r '.entries["consent-lawful-basis"].change.effective_date' .startup/law-registry.json)
[ "$effective" = "2026-05-01" ] || { echo "FAIL: expected effective_date=2026-05-01, got $effective"; exit 1; }

detected=$(jq -r '.entries["consent-lawful-basis"].change_detected_at' .startup/law-registry.json)
[ "$detected" = "2026-04-22T08:00:00Z" ] || { echo "FAIL: expected change_detected_at=2026-04-22T08:00:00Z, got $detected"; exit 1; }

last=$(jq -r '.last_feed_check_at' .startup/law-registry.json)
[ "$last" = "$NOW" ] || { echo "FAIL: expected last_feed_check_at=$NOW, got $last"; exit 1; }

echo "PASS: test-detect"
