#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry with a flagged entry that has an open issue
cat > .startup/law-registry.json <<'EOF'
{
  "version": 1,
  "last_feed_check_at": "2026-04-23T10:00:00Z",
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
      "needs_review": true,
      "change_detected_at": "2026-04-22T08:00:00Z",
      "change": {"feed_event_id": "evt-42", "type": "amended", "summary": "§ 10 lõige 2 muudetud"},
      "gh_issue_url": "https://github.com/org/repo/issues/42"
    }
  }
}
EOF
echo "Old text before amendment." > .startup/laws/consent-lawful-basis.txt

# Mock datalake citation endpoint — returns new redaktsioon text
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *citation*) cat "$FIXTURES/datalake/citation-consent.json"; exit 0 ;;
  esac
done
echo '{}'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key

# Inline ack logic (copied from commands/lawyer.md § Ack subcommand)
SLUG=consent-lawful-basis
act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
citation=$(jq -r --arg s "$SLUG" '.entries[$s].citation' .startup/law-registry.json)
encoded=$(printf '%s' "$citation" | jq -sRr @uri)
resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${act_id}/citation?paragraph=${encoded}")
text=$(echo "$resp" | jq -r '.text // empty')
redaktsioon=$(echo "$resp" | jq '.redaktsioon_id // null')
[ -n "$text" ] || { echo "FAIL: ack got empty text"; exit 1; }

normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg slug "$SLUG" --arg now "$NOW" --argjson r "$redaktsioon" '
  .entries[$slug].needs_review = false
  | .entries[$slug].change = null
  | .entries[$slug].change_detected_at = null
  | .entries[$slug].verified_at = $now
  | .entries[$slug].redaktsioon_id = $r
' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

# Assertions
[ "$(jq -r '.entries["consent-lawful-basis"].needs_review' .startup/law-registry.json)" = "false" ] || { echo "FAIL: needs_review not cleared"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].change' .startup/law-registry.json)" = "null" ] || { echo "FAIL: change not cleared"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].gh_issue_url' .startup/law-registry.json)" = "https://github.com/org/repo/issues/42" ] || { echo "FAIL: gh_issue_url should be preserved"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].redaktsioon_id' .startup/law-registry.json)" = "104052024010/1" ] || { echo "FAIL: redaktsioon_id not updated"; exit 1; }
snapshot=$(cat .startup/laws/consent-lawful-basis.txt)
[[ "$snapshot" == *"nõusoleku"* ]] || { echo "FAIL: snapshot not refreshed"; exit 1; }

echo "PASS: test-ack"
