#!/usr/bin/env bash
# Regression for #595: the real lawyer-marker-scan.sh must find markers under
# nested source roots in monorepos (e.g. frontend/src, backend/app), not just
# root-level directories, while still excluding dependency/generated trees
# and the lawyer's own output (docs/legal) at any depth.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="$TESTS_DIR/../scripts/lawyer-marker-scan.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p src frontend/src backend/app node_modules/some-dep docs/legal .startup

cat > src/control.ts <<'EOF'
// LAW: root-control
export const ok = true;
EOF

cat > frontend/src/page.tsx <<'EOF'
// LAW: sample-law
export default function Page() { return null; }
EOF

cat > backend/app/main.py <<'EOF'
# LAW: sample-law
def main(): pass
EOF

cat > node_modules/some-dep/index.js <<'EOF'
// LAW: dep-noise
module.exports = {};
EOF

cat > docs/legal/privacy.md <<'EOF'
<!-- LAW: own-output-noise -->
EOF

cat > .startup/state.json <<'EOF'
// LAW: hidden-dir-noise
EOF

output=$(bash "$SCAN_SCRIPT")

echo "$output" | grep -qE $'^root-control\tsrc/control\\.ts:' \
  || { echo "FAIL: root-level control marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qE $'^sample-law\tfrontend/src/page\\.tsx:' \
  || { echo "FAIL: nested frontend marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qE $'^sample-law\tbackend/app/main\\.py:' \
  || { echo "FAIL: nested backend marker not found"; echo "$output"; exit 1; }

if echo "$output" | grep -q 'node_modules'; then
  echo "FAIL: node_modules marker leaked into output"; echo "$output"; exit 1
fi

if echo "$output" | grep -q 'docs/legal'; then
  echo "FAIL: docs/legal (own output) marker leaked into output"; echo "$output"; exit 1
fi

if echo "$output" | grep -q 'hidden-dir-noise\|\.startup'; then
  echo "FAIL: hidden directory (.startup) marker leaked into output"; echo "$output"; exit 1
fi

echo "PASS: test-markers-nested"
