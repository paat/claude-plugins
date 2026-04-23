#!/usr/bin/env bash
set -euo pipefail

# Test: registry JSON schema round-trip
# - load fixture
# - extract fields via jq
# - assert values match

FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"
REGISTRY="$FIXTURE_DIR/registry/example.json"

# Assert valid JSON
jq empty "$REGISTRY"

# Assert version is 1
version=$(jq -r '.version' "$REGISTRY")
[[ "$version" == "1" ]] || { echo "FAIL: expected version=1, got $version"; exit 1; }

# Assert entry exists and has expected act_id
act_id=$(jq -r '.entries["consent-lawful-basis"].act_id' "$REGISTRY")
[[ "$act_id" == "104052024010" ]] || { echo "FAIL: expected act_id=104052024010, got $act_id"; exit 1; }

# Assert needs_review is boolean
needs_review=$(jq -r '.entries["consent-lawful-basis"].needs_review' "$REGISTRY")
[[ "$needs_review" == "false" ]] || { echo "FAIL: expected needs_review=false, got $needs_review"; exit 1; }

# Assert gh_issue_url is null
gh_url=$(jq -r '.entries["consent-lawful-basis"].gh_issue_url' "$REGISTRY")
[[ "$gh_url" == "null" ]] || { echo "FAIL: expected gh_issue_url=null, got $gh_url"; exit 1; }

# Assert snapshot file exists
[[ -f "$FIXTURE_DIR/laws/consent-lawful-basis.txt" ]] || { echo "FAIL: snapshot file missing"; exit 1; }

echo "PASS: test-schema"
