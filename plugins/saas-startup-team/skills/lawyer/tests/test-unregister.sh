#!/usr/bin/env bash
set -euo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry (v2) + snapshot
cat > .startup/law-registry.json <<'EOF'
{
  "version": 2,
  "last_feed_check_at": null,
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
      "verified_at": "2026-04-01T00:00:00Z",
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
echo "old text" > .startup/laws/consent-lawful-basis.txt

# Inline unregister logic
SLUG=consent-lawful-basis
jq --arg slug "$SLUG" 'del(.entries[$slug])' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json
rm -f ".startup/laws/${SLUG}.txt"

# Assertions
remaining=$(jq -r '.entries | keys | length' .startup/law-registry.json)
[ "$remaining" = "0" ] || { echo "FAIL: entries should be empty, got $remaining"; exit 1; }
[ ! -f ".startup/laws/${SLUG}.txt" ] || { echo "FAIL: snapshot should be deleted"; exit 1; }

echo "PASS: test-unregister"
