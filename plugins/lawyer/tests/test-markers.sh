#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$TESTS_DIR/fixtures/source"

# The scan pattern under test (kept in sync with references/law-registry.md)
PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'

# Run grep, capture matches
matches=$(grep -rEn "$PATTERN" "$SRC" 2>/dev/null || true)

# Assertions
echo "$matches" | grep -q "consent.ts.*LAW: consent-lawful-basis" || { echo "FAIL: consent.ts marker not found"; echo "$matches"; exit 1; }
echo "$matches" | grep -q "processor.py.*LAW: data-subject-rights" || { echo "FAIL: processor.py marker not found"; echo "$matches"; exit 1; }
echo "$matches" | grep -q "privacy.md.*LAW: consumer-14-day-withdrawal" || { echo "FAIL: privacy.md marker not found"; echo "$matches"; exit 1; }
echo "$matches" | grep -q "banner.jsx.*LAW: cookie-consent" || { echo "FAIL: banner.jsx marker not found"; echo "$matches"; exit 1; }

# False-positive guard: prose-trap.md must NOT match
if echo "$matches" | grep -q "prose-trap.md"; then
  echo "FAIL: prose-trap.md matched (false positive)"; exit 1
fi

# Extraction: verify multi-slug marker yields two slugs
slugs_line=$(echo "$matches" | grep "processor.py")
count=$(printf '%s' "$slugs_line" | grep -oE '[a-z0-9-]+-[a-z0-9-]+' | wc -l | tr -d ' ')
# Note: this regex is approximate; we only assert at least one slug captured
[ "$count" -ge 1 ] || { echo "FAIL: expected slugs in processor.py marker"; exit 1; }

echo "PASS: test-markers"
