#!/usr/bin/env bash
# Regression for #595 fix-cycle-1: a large file count must not overflow a
# single rg/grep argv. Lowering the stack ulimit lowers ARG_MAX on Linux
# (floors at 128KB), so a few thousand files is enough to reproduce the
# E2BIG that silently dropped every marker on 37d86d3, without needing a
# real 60k-file repo.
#
# The argmax case runs with rg absent from PATH: rg (14.x) aborts on a
# 128KB stack ("fatal runtime error: stack overflow"), which is unrelated to
# the E2BIG regression. With rg gone the scanner falls back to grep, which
# copes with the shrunken stack, so the case still exercises xargs chunking.
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

# PATH with rg absent (see header): everything the scanner needs, minus rg.
NOPATH_DIR=$(mktemp -d)
trap 'rm -rf "$WORK" "$NOPATH_DIR"' EXIT
for tool in bash sh grep xargs git mktemp cat rm awk find sed mkdir; do
  path=$(command -v "$tool") && ln -sf "$path" "$NOPATH_DIR/$tool"
done

output=$(
  ulimit -s 128
  PATH="$NOPATH_DIR" bash "$SCAN_SCRIPT"
)
rc=$?

[ "$rc" -eq 0 ] || { echo "FAIL: scanner exited $rc under lowered ARG_MAX"; echo "$output"; exit 1; }

echo "$output" | grep -qF $'argmax-first\tsrc/file_00001.txt:1' \
  || { echo "FAIL: first marker lost under lowered ARG_MAX"; echo "$output"; exit 1; }

echo "$output" | grep -qF $'argmax-last\tsrc/file_08000.txt:1' \
  || { echo "FAIL: last marker lost under lowered ARG_MAX"; echo "$output"; exit 1; }

echo "PASS: test-markers-argmax"

# Regression for #595 fix-cycle-2: GNU grep (3.5+) reports a matching binary
# file on stderr ("binary file matches"), which the "any stderr is a failure"
# check above mistook for a real scan failure. A binary file containing a
# marker-like byte sequence must be skipped, not treated as an error.
BINWORK=$(mktemp -d)
trap 'rm -rf "$WORK" "$BINWORK" "$NOPATH_DIR"' EXIT

cd "$BINWORK"
git init -q .
mkdir -p src
echo "// LAW: ok-marker" > src/a.ts
printf 'abc\0def\n// LAW: bin-marker\n' > src/blob.bin
git add -A
git -c user.email=t@t.t -c user.name=t commit -q -m init

run_binary_case() {
  local label="$1"
  local output rc
  output=$(bash "$SCAN_SCRIPT")
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: scanner exited $rc on binary-file case ($label)"; echo "$output"; exit 1; }
  [ "$output" = $'ok-marker\tsrc/a.ts:1' ] \
    || { echo "FAIL: binary-file case ($label) output mismatch"; echo "$output"; exit 1; }
}

PATH="$NOPATH_DIR" run_binary_case "grep path, rg absent"

if command -v rg >/dev/null 2>&1; then
  run_binary_case "rg path"
fi

cd "$WORK"
echo "PASS: test-markers-argmax (binary-file case)"
