#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry (v2) with a flagged entry that has an open issue
cat > .startup/law-registry.json <<'EOF'
{
  "version": 2,
  "last_feed_check_at": "2026-04-23T10:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": 30087,
      "rt_id": "1045568",
      "redaktsioon_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "act_type": "seadus",
      "citation": "§ 10 lõige 1",
      "citation_parts": {"paragraph": "10", "section": "1", "point": ""},
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "registered_at": "2026-04-01T00:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "test",
      "needs_review": true,
      "change_detected_at": "2026-04-22T08:00:00Z",
      "change": {"feed_event_id": 45037, "type": "amendment", "summary": "§ 10 täiendatud", "effective_date": "2026-05-01"},
      "gh_issue_url": "https://github.com/org/repo/issues/42"
    }
  }
}
EOF
echo "Old text before amendment." > .startup/laws/consent-lawful-basis.txt

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
export DATALAKE_URL=https://datalake.r-53.com

# ---- inlined ack (mirrors commands/lawyer.md § Ack subcommand) ----
SLUG="consent-lawful-basis"
act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
paragraph=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.paragraph // ""' .startup/law-registry.json)
section=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.section // ""' .startup/law-registry.json)
point=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.point // ""' .startup/law-registry.json)

cite_url="$DATALAKE_URL/api/v1/laws/${act_id}/citation?paragraph=${paragraph}"
[ -n "$section" ] && cite_url="${cite_url}&section=${section}"
[ -n "$point" ] && cite_url="${cite_url}&point=${point}"

resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
text=$(echo "$resp" | jq -r '.text // empty')
cite_url_resp=$(echo "$resp" | jq -r '.url // empty')
red=""
if [ -n "$cite_url_resp" ]; then
  tail_seg="${cite_url_resp##*/akt/}"
  red="${tail_seg%%[!0-9]*}"
fi
[ -n "$text" ] || { echo "FAIL: ack got empty text"; exit 1; }

normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg slug "$SLUG" --arg now "$NOW" --arg red "$red" --arg rturl "$cite_url_resp" '
  .entries[$slug].needs_review = false
  | .entries[$slug].change = null
  | .entries[$slug].change_detected_at = null
  | .entries[$slug].verified_at = $now
  | .entries[$slug].redaktsioon_id = (if $red == "" then null else $red end)
  | .entries[$slug].rt_url = (if $rturl == "" then .entries[$slug].rt_url else $rturl end)
' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

# ---- assertions ----
[ "$(jq -r '.entries["consent-lawful-basis"].needs_review' .startup/law-registry.json)" = "false" ] || { echo "FAIL: needs_review not cleared"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].change' .startup/law-registry.json)" = "null" ] || { echo "FAIL: change not cleared"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].gh_issue_url' .startup/law-registry.json)" = "https://github.com/org/repo/issues/42" ] || { echo "FAIL: gh_issue_url should be preserved"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].redaktsioon_id' .startup/law-registry.json)" = "106032026010" ] || { echo "FAIL: redaktsioon_id not refreshed from citation .url"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].rt_url' .startup/law-registry.json)" = "https://www.riigiteataja.ee/akt/106032026010" ] || { echo "FAIL: rt_url not refreshed"; exit 1; }
snapshot=$(cat .startup/laws/consent-lawful-basis.txt)
[[ "$snapshot" == *"krediidivõimelisuse"* ]] || { echo "FAIL: snapshot not refreshed (no 'krediidivõimelisuse' in text)"; exit 1; }

echo "PASS: test-ack"
