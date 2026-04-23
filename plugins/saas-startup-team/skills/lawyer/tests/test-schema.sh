#!/usr/bin/env bash
set -euo pipefail

# Test: registry JSON schema round-trip (v2)

FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"
REGISTRY="$FIXTURE_DIR/registry/example.json"

# Assert valid JSON
jq empty "$REGISTRY"

# Assert version is 2
version=$(jq -r '.version' "$REGISTRY")
[[ "$version" == "2" ]] || { echo "FAIL: expected version=2, got $version"; exit 1; }

# Assert entry has the v2 fields
entry=$(jq '.entries["consent-lawful-basis"]' "$REGISTRY")

# act_id is an integer
act_id=$(echo "$entry" | jq -r '.act_id')
[[ "$act_id" == "30087" ]] || { echo "FAIL: expected act_id=30087 (int), got $act_id"; exit 1; }
[[ "$(echo "$entry" | jq -r '.act_id | type')" == "number" ]] || { echo "FAIL: act_id should be number"; exit 1; }

# rt_id is a string (for feed matching)
rt_id=$(echo "$entry" | jq -r '.rt_id')
[[ "$rt_id" == "1045568" ]] || { echo "FAIL: expected rt_id=1045568, got $rt_id"; exit 1; }

# citation_parts has paragraph/section/point
paragraph=$(echo "$entry" | jq -r '.citation_parts.paragraph')
section=$(echo "$entry" | jq -r '.citation_parts.section')
point=$(echo "$entry" | jq -r '.citation_parts.point')
[[ "$paragraph" == "10" ]] || { echo "FAIL: paragraph=10 expected, got $paragraph"; exit 1; }
[[ "$section" == "1" ]] || { echo "FAIL: section=1 expected, got $section"; exit 1; }
[[ "$point" == "" ]] || { echo "FAIL: point should be empty, got '$point'"; exit 1; }

# Flags default off
needs_review=$(echo "$entry" | jq -r '.needs_review')
[[ "$needs_review" == "false" ]] || { echo "FAIL: expected needs_review=false, got $needs_review"; exit 1; }
gh_url=$(echo "$entry" | jq -r '.gh_issue_url')
[[ "$gh_url" == "null" ]] || { echo "FAIL: expected gh_issue_url=null, got $gh_url"; exit 1; }

# Snapshot exists
[[ -f "$FIXTURE_DIR/laws/consent-lawful-basis.txt" ]] || { echo "FAIL: snapshot file missing"; exit 1; }

echo "PASS: test-schema"
