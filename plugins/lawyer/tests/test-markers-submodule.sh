#!/usr/bin/env bash
# Regression for #603: lawyer-marker-scan.sh must find LAW: markers inside
# initialized git submodules (including nested submodules) with paths relative
# to the superproject root, while ignoring uninitialized submodules and
# producing empty stderr and exit 0.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="$TESTS_DIR/../scripts/lawyer-marker-scan.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init -q nested-dep
cd nested-dep
git -c user.email=t@t.t -c user.name=t commit --allow-empty -q -m init
mkdir -p pkg
cat > pkg/nested.ts <<'EOF'
// LAW: nested-marker
export const nested = true;
EOF
git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m "add nested marker"
cd ..

git init -q sub-dep
cd sub-dep
git -c user.email=t@t.t -c user.name=t commit --allow-empty -q -m init
mkdir -p lib node_modules/dep docs/legal .hidden
cat > lib/a.ts <<'EOF'
// LAW: sub-marker
export const sub = true;
EOF
cat > node_modules/dep/index.js <<'EOF'
// LAW: sub-dep-noise
EOF
cat > docs/legal/terms.md <<'EOF'
<!-- LAW: sub-legal-noise -->
EOF
cat > .hidden/config.json <<'EOF'
// LAW: sub-hidden-noise
EOF
git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m "add sub marker and noises"
git -c protocol.file.allow=always submodule add -q "$WORK/nested-dep" nested-lib
git -c user.email=t@t.t -c user.name=t commit -q -m "add nested submodule"
cd ..

git init -q uninit-dep
cd uninit-dep
git -c user.email=t@t.t -c user.name=t commit --allow-empty -q -m init
cat > uninit.ts <<'EOF'
// LAW: uninit-marker
export const uninit = true;
EOF
git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m "add uninit marker"
cd ..

git init -q superproject
cd superproject
git -c user.email=t@t.t -c user.name=t commit --allow-empty -q -m init
mkdir -p src
cat > src/control.ts <<'EOF'
// LAW: root-marker
export const root = true;
EOF
git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m "add root marker"
git -c protocol.file.allow=always submodule add -q "$WORK/sub-dep" src/vendor-lib
git -c protocol.file.allow=always submodule add -q "$WORK/uninit-dep" uninit-sub
git -c user.email=t@t.t -c user.name=t commit -q -m "add submodules"

cd ..
git clone -q superproject app
cd app
git -c protocol.file.allow=always submodule update --init --recursive -q src/vendor-lib

cat > src/untracked.ts <<'EOF'
// LAW: untracked-marker
export const untracked = true;
EOF

ERR_LOG="$WORK/err.log"
set +e
output=$(bash "$SCAN_SCRIPT" 2>"$ERR_LOG")
rc=$?
set -e

[ "$rc" -eq 0 ] || { echo "FAIL: scanner exited $rc, expected 0"; cat "$ERR_LOG"; exit 1; }
[ ! -s "$ERR_LOG" ] || { echo "FAIL: scanner printed to stderr:"; cat "$ERR_LOG"; exit 1; }

echo "$output" | grep -qE $'^root-marker\tsrc/control\\.ts:' \
  || { echo "FAIL: root-level control marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qE $'^untracked-marker\tsrc/untracked\\.ts:' \
  || { echo "FAIL: untracked marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qE $'^sub-marker\tsrc/vendor-lib/lib/a\\.ts:' \
  || { echo "FAIL: submodule marker not found"; echo "$output"; exit 1; }

echo "$output" | grep -qE $'^nested-marker\tsrc/vendor-lib/nested-lib/pkg/nested\\.ts:' \
  || { echo "FAIL: nested submodule marker not found"; echo "$output"; exit 1; }

if echo "$output" | grep -q 'uninit-marker'; then
  echo "FAIL: uninitialized submodule marker leaked into output"; echo "$output"; exit 1
fi

if echo "$output" | grep -q 'sub-dep-noise'; then
  echo "FAIL: node_modules in submodule leaked into output"; echo "$output"; exit 1
fi

if echo "$output" | grep -q 'sub-legal-noise'; then
  echo "FAIL: docs/legal in submodule leaked into output"; echo "$output"; exit 1
fi

if echo "$output" | grep -q 'sub-hidden-noise'; then
  echo "FAIL: hidden directory in submodule leaked into output"; echo "$output"; exit 1
fi

echo "PASS: test-markers-submodule"
