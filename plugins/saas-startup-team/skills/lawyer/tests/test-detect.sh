#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry: one entry in Data Protection domain referencing the fixture act_id
cat > .startup/law-registry.json <<'EOF'
{
  "version": 1,
  "last_feed_check_at": "2026-04-20T00:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "citation": "§ 10 lõige 2",
      "domain": "Data Protection",
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "redaktsioon_id": null,
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
    *changes/feed*domain=Data*Protection*) cat "$FIXTURES/datalake/feed-data-protection.json"; exit 0 ;;
  esac
done
echo '{"events":[]}'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key

# Inline the change-detection logic (copied from commands/lawyer.md § Change Detection)
SINCE=$(jq -r '.last_feed_check_at // ""' .startup/law-registry.json)
DOMAINS=$(jq -r '.entries | to_entries[] | .value.domain' .startup/law-registry.json | sort -u)
ACT_IDS=$(jq -r '.entries | to_entries[] | .value.act_id' .startup/law-registry.json | sort -u)

# Poll feed per domain
all_events='[]'
while IFS= read -r d; do
  [ -z "$d" ] && continue
  encoded=$(printf '%s' "$d" | jq -sRr @uri)
  resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
    "https://datalake.r-53.com/api/v1/changes/feed?domain=${encoded}&since=${SINCE}")
  events=$(echo "$resp" | jq '.events // []')
  all_events=$(echo "$all_events $events" | jq -s 'add')
done <<< "$DOMAINS"

# Filter events: keep only those whose act_id is in ACT_IDS
act_ids_json=$(printf '%s\n' "$ACT_IDS" | jq -R . | jq -s .)
matched=$(echo "$all_events" | jq --argjson acts "$act_ids_json" '[.[] | select(.act_id as $a | $acts | index($a))]')

# Update registry: for each matched event, flag all entries with that act_id
updated=$(jq --argjson matched "$matched" '
  reduce ($matched[]) as $e (.;
    .entries |= with_entries(
      if .value.act_id == $e.act_id then
        .value.needs_review = true
        | .value.change_detected_at = $e.timestamp
        | .value.change = { feed_event_id: $e.id, type: $e.type, summary: $e.summary }
      else . end
    )
  )
' .startup/law-registry.json)

# Advance last_feed_check_at
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > .startup/law-registry.json

# Assertions
flagged=$(jq -r '.entries["consent-lawful-basis"].needs_review' .startup/law-registry.json)
[ "$flagged" = "true" ] || { echo "FAIL: expected needs_review=true, got $flagged"; exit 1; }

change_type=$(jq -r '.entries["consent-lawful-basis"].change.type' .startup/law-registry.json)
[ "$change_type" = "amended" ] || { echo "FAIL: expected change.type=amended, got $change_type"; exit 1; }

last=$(jq -r '.last_feed_check_at' .startup/law-registry.json)
[ "$last" = "$NOW" ] || { echo "FAIL: expected last_feed_check_at=$NOW, got $last"; exit 1; }

echo "PASS: test-detect"
