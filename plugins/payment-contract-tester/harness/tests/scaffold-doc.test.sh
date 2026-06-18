#!/usr/bin/env bash
# Structural validation of commands/scaffold.md: it must encode the spec §4.2 generator flow and the
# critical non-regression framing. Content is instructions-for-Claude, so we assert the load-bearing
# anchors are present (not prose quality).
set -uo pipefail
DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/commands/scaffold.md"
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

[ -f "$DOC" ] || { echo "FAIL: commands/scaffold.md missing"; exit 1; }

# YAML frontmatter with a description
head -1 "$DOC" | grep -qx -- '---' && pass "has frontmatter opener" || bad "missing frontmatter opener"
grep -qiE '^description:' "$DOC" && pass "frontmatter has a description" || bad "frontmatter missing description"

# the 7 flow steps (anchored by their spec verbs)
for kw in "Detect stack" "Detect gateway" "Locate seam" "Draft contract test" "Self-verify" "Wire enforcement" "Report"; do
  grep -qiF "$kw" "$DOC" && pass "covers step: $kw" || bad "missing step: $kw"
done

# critical non-regression framing (Global Constraints)
grep -qi 'never edits\|does not edit\|not edit.*source\|never.*payment source' "$DOC" && pass "states never-edits-source" || bad "missing never-edits-source rule"
grep -qi 'authoritative' "$DOC" && pass "states CI-authoritative framing" || bad "missing CI-authoritative framing"
grep -qiF 'no first-class support' "$DOC" && pass "handles unsupported stacks honestly" || bad "missing unsupported-stack honesty"
grep -qiF 'TODO-verify-against-sandbox' "$DOC" && pass "flags unverified assertions" || bad "missing TODO-verify-against-sandbox"
grep -qi 're-fetch\|/v2/payments' "$DOC" && pass "encodes Mollie re-fetch model" || bad "missing Mollie re-fetch model"
grep -qi 'reconciliation' "$DOC" && pass "addresses reconciliation (not auto-generated)" || bad "missing reconciliation note"
grep -qiF 'reference/' "$DOC" && pass "points at the few-shot exemplar fixtures" || bad "missing reference/<stack> exemplar pointer"
grep -qi 'install-pre-push\|harness/ci' "$DOC" && pass "wires the harness" || bad "missing harness wiring"

[ "$fail" -eq 0 ] && echo "scaffold-doc tests: ALL PASS" || echo "scaffold-doc tests: FAILURES"
exit $fail
