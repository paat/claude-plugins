#!/usr/bin/env bash
set -euo pipefail

# Test: verdict frontmatter schema is well-formed and matches Global Constraints
# key names verbatim (schema documented in skills/lawyer/SKILL.md's
# Evidence-Tier Policy / Analysis Workflow sections).

FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures/verdict" && pwd)"

extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

# --- CONFIRMED / Tier A / empty blocking_human_tasks ---
CONFIRMED_DOC="$FIXTURE_DIR/sample-analysis.md"
[[ -f "$CONFIRMED_DOC" ]] || { echo "FAIL: fixture missing: $CONFIRMED_DOC"; exit 1; }
confirmed_fm=$(extract_frontmatter "$CONFIRMED_DOC")

# --- UNVERIFIABLE-IN-CORPUS / Tier B / non-empty blocking_human_tasks (list form) ---
HEDGED_DOC="$FIXTURE_DIR/sample-hedged.md"
[[ -f "$HEDGED_DOC" ]] || { echo "FAIL: fixture missing: $HEDGED_DOC"; exit 1; }
hedged_fm=$(extract_frontmatter "$HEDGED_DOC")

REQUIRED_KEYS=(verdict evidence_tier blocking_human_tasks claims)

for key in "${REQUIRED_KEYS[@]}"; do
  echo "$confirmed_fm" | grep -q "^${key}:" || { echo "FAIL: confirmed fixture missing key '$key'"; exit 1; }
  echo "$hedged_fm" | grep -q "^${key}:" || { echo "FAIL: hedged fixture missing key '$key'"; exit 1; }
done

for claim_key in id verdict evidence_tier value source_url quote verified_at review_by; do
  echo "$confirmed_fm" | grep -qE "^[[:space:]]*-?[[:space:]]*${claim_key}:" || { echo "FAIL: confirmed fixture claims[] missing '$claim_key'"; exit 1; }
  echo "$hedged_fm" | grep -qE "^[[:space:]]*-?[[:space:]]*${claim_key}:" || { echo "FAIL: hedged fixture claims[] missing '$claim_key'"; exit 1; }
done

confirmed_verdict=$(echo "$confirmed_fm" | grep '^verdict:' | sed 's/^verdict: *//')
[[ "$confirmed_verdict" == "CONFIRMED" ]] || { echo "FAIL: expected verdict=CONFIRMED, got $confirmed_verdict"; exit 1; }
confirmed_tier=$(echo "$confirmed_fm" | grep '^evidence_tier:' | sed 's/^evidence_tier: *//')
[[ "$confirmed_tier" == "A" ]] || { echo "FAIL: expected evidence_tier=A, got $confirmed_tier"; exit 1; }
echo "$confirmed_fm" | grep -q '^blocking_human_tasks: \[\]' || { echo "FAIL: expected inline-empty blocking_human_tasks: []"; exit 1; }

hedged_verdict=$(echo "$hedged_fm" | grep '^verdict:' | sed 's/^verdict: *//')
[[ "$hedged_verdict" == "UNVERIFIABLE-IN-CORPUS" ]] || { echo "FAIL: expected verdict=UNVERIFIABLE-IN-CORPUS, got $hedged_verdict"; exit 1; }
hedged_tier=$(echo "$hedged_fm" | grep '^evidence_tier:' | sed 's/^evidence_tier: *//')
[[ "$hedged_tier" == "B" ]] || { echo "FAIL: expected evidence_tier=B, got $hedged_tier"; exit 1; }
echo "$hedged_fm" | grep -qE '^blocking_human_tasks:\s*$' || { echo "FAIL: expected block-list blocking_human_tasks:"; exit 1; }
echo "$hedged_fm" | grep -q '^  - ' || { echo "FAIL: expected at least one blocking_human_tasks list item"; exit 1; }

# The literal string "verdict:" in the document body (outside the frontmatter
# block) must not be mistaken for the frontmatter's own key by a naive
# whole-file grep.
grep -c '^verdict:' "$HEDGED_DOC" | grep -q '^1$' || {
  echo "FAIL: expected exactly one top-level 'verdict:' line in $HEDGED_DOC (frontmatter only)"
  exit 1
}

# Well-formed YAML: prefer python3+PyYAML, fall back to structural checks above.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  for doc in "$CONFIRMED_DOC" "$HEDGED_DOC"; do
    fm=$(extract_frontmatter "$doc")
    echo "$fm" | python3 -c '
import sys, yaml
data = yaml.safe_load(sys.stdin)
required = ["verdict", "evidence_tier", "blocking_human_tasks", "claims"]
missing = [k for k in required if k not in data]
if missing:
    raise SystemExit(f"missing top-level keys: {missing}")
verdict = data["verdict"]
if verdict not in ("CONFIRMED", "UNCONFIRMED", "UNVERIFIABLE-IN-CORPUS"):
    raise SystemExit(f"bad verdict value: {verdict!r}")
evidence_tier = data["evidence_tier"]
if evidence_tier not in ("A", "B", "C"):
    raise SystemExit(f"bad evidence_tier value: {evidence_tier!r}")
if not isinstance(data["blocking_human_tasks"], list):
    raise SystemExit("blocking_human_tasks must be a list")
if not isinstance(data["claims"], list) or not data["claims"]:
    raise SystemExit("claims must be a non-empty list")
claim_keys = {"id", "verdict", "evidence_tier", "value", "source_url", "quote", "verified_at", "review_by"}
for claim in data["claims"]:
    missing_claim_keys = claim_keys - set(claim)
    if missing_claim_keys:
        raise SystemExit(f"claim missing keys: {missing_claim_keys}")
    if claim["verdict"] not in ("CONFIRMED", "UNCONFIRMED", "UNVERIFIABLE-IN-CORPUS"):
        raise SystemExit(f"bad claim verdict: {claim['verdict']!r}")
    if claim["evidence_tier"] not in ("A", "B", "C"):
        raise SystemExit(f"bad claim evidence_tier: {claim['evidence_tier']!r}")
' || { echo "FAIL: $doc frontmatter is not well-formed per schema"; exit 1; }
  done
fi

echo "PASS: test-verdict-frontmatter"
