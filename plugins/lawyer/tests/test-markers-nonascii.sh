#!/usr/bin/env bash
# Regression for #595/tribunal T-001: git's default core.quotePath C-quotes
# non-ASCII paths (git ls-files --cached --others --exclude-standard), so
# `[ -f "$f" ]` fails on the quoted string and the file (and its LAW: marker)
# is silently dropped. The scanner must list with `git ls-files -z` so
# non-ASCII paths come through unquoted, whether tracked or untracked.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="$TESTS_DIR/../scripts/lawyer-marker-scan.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q .

mkdir -p "src/müük" src
cat > "src/müük/leping.ts" <<'EOF'
// LAW: estonian-path
export const ok = true;
EOF
cat > src/a.ts <<'EOF'
// LAW: ascii
export const ok = true;
EOF

git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m init

# untracked non-ASCII file must also be found
cat > "src/müük/arve.ts" <<'EOF'
// LAW: estonian-untracked
export const ok = true;
EOF

output=$(bash "$SCAN_SCRIPT")

echo "$output" | grep -qF $'ascii\tsrc/a.ts:1' \
  || { echo "FAIL: ascii marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qF $'estonian-path\tsrc/müük/leping.ts:1' \
  || { echo "FAIL: tracked non-ASCII path marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qF $'estonian-untracked\tsrc/müük/arve.ts:1' \
  || { echo "FAIL: untracked non-ASCII path marker not found"; echo "$output"; exit 1; }

echo "PASS: test-markers-nonascii"
