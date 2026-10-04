#!/usr/bin/env bash
# Regression for #595 fix-cycle-1: a large file count must not overflow a
# single rg/grep argv. Lowering the stack ulimit lowers ARG_MAX on Linux
# (floors at 128KB), so a few thousand files is enough to reproduce the
# E2BIG that silently dropped every marker on 37d86d3, without needing a
# real 60k-file repo.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="$TESTS_DIR/../scripts/lawyer-marker-scan.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p src
for i in $(seq 1 8000); do
  : > "src/file_$(printf '%05d' "$i").txt"
done
echo "// LAW: argmax-first" > src/file_00001.txt
echo "// LAW: argmax-last" > src/file_08000.txt

(
  ulimit -s 128 2>/dev/null
) || { echo "SKIP: cannot lower ulimit -s on this system; test-markers-argmax skipped"; exit 0; }

output=$(
  ulimit -s 128
  bash "$SCAN_SCRIPT"
)
rc=$?

[ "$rc" -eq 0 ] || { echo "FAIL: scanner exited $rc under lowered ARG_MAX"; echo "$output"; exit 1; }

echo "$output" | grep -qF $'argmax-first\tsrc/file_00001.txt:1' \
  || { echo "FAIL: first marker lost under lowered ARG_MAX"; echo "$output"; exit 1; }

echo "$output" | grep -qF $'argmax-last\tsrc/file_08000.txt:1' \
  || { echo "FAIL: last marker lost under lowered ARG_MAX"; echo "$output"; exit 1; }

echo "PASS: test-markers-argmax"
