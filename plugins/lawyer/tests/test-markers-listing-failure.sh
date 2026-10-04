#!/usr/bin/env bash
# Regression for #595/tribunal T-002: `git ls-files ... 2>/dev/null` (and the
# `find` fallback) silenced listing failures, so a broken `git` left the file
# list empty and the scan exited 0 with no markers instead of reporting a
# failure. A listing failure must print a stderr diagnostic and exit non-zero;
# a genuinely empty project must still exit 0 with empty output.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="$TESTS_DIR/../scripts/lawyer-marker-scan.sh"

WORK=$(mktemp -d)
SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$WORK" "$SHIM_DIR"' EXIT

cd "$WORK"
git init -q .
mkdir -p src
echo "// LAW: ok-marker" > src/a.ts
git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m init

REAL_GIT=$(command -v git)
cat > "$SHIM_DIR/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "ls-files" ]; then
  echo "git: fatal simulated failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM_DIR/git"

set +e
output=$(PATH="$SHIM_DIR:$PATH" bash "$SCAN_SCRIPT" 2>"$WORK/err.log")
rc=$?
set -e

[ "$rc" -ne 0 ] || { echo "FAIL: scanner exited 0 on failing git listing"; exit 1; }
[ -s "$WORK/err.log" ] || { echo "FAIL: no stderr diagnostic on failing git listing"; exit 1; }
[ -z "$output" ] || { echo "FAIL: unexpected stdout on failing git listing: $output"; exit 1; }

# A genuinely empty git repo still exits 0 with empty output.
EMPTY=$(mktemp -d)
trap 'rm -rf "$WORK" "$SHIM_DIR" "$EMPTY"' EXIT
(cd "$EMPTY" && git init -q .)
cd "$EMPTY"
set +e
output2=$(bash "$SCAN_SCRIPT" 2>"$EMPTY/err.log")
rc2=$?
set -e
[ "$rc2" -eq 0 ] || { echo "FAIL: empty git repo exited $rc2, expected 0"; cat "$EMPTY/err.log"; exit 1; }
[ -z "$output2" ] || { echo "FAIL: empty git repo produced output: $output2"; exit 1; }

echo "PASS: test-markers-listing-failure"
