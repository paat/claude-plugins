#!/usr/bin/env bash
# silent-failure-scanner: scan a git diff for swallowed-error / ghost-transaction signatures.
# Dependencies: bash 4+, awk (gawk/mawk/busybox), git.
#
# Usage:
#   scan.sh [--format text|json] [--staged] [--base <ref>] [-f <diff-file>] [<rev-range>]
#
#   (no source flag)   scan uncommitted changes: `git diff HEAD`
#   --staged           scan staged changes only:  `git diff --cached`
#   --base <ref>       scan against a base ref:    `git diff <ref>...HEAD`
#   -f <diff-file>     read a unified diff from a file ("-" = stdin)
#   <rev-range>        any extra arg is passed to `git diff` verbatim
#   --format text      human-readable findings (default); exit 1 if any found
#   --format json      machine-readable report ({findings, summary})
#
# A diff piped on stdin is auto-detected when no source flag is given.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK_PROG="$SCRIPT_DIR/scan.awk"
VERSION="0.1.0"

FORMAT="text"
DIFF_FILE=""
SOURCE=""        # "", "staged", "base", "range"
BASE_REF=""
RANGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="${2:-text}"; shift 2 ;;
    --staged) SOURCE="staged"; shift ;;
    --base)   SOURCE="base"; BASE_REF="${2:-}"; shift 2 ;;
    -f|--file) DIFF_FILE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "[silent-failure-scanner] unknown option: $1" >&2; exit 2 ;;
    *)  SOURCE="range"; RANGE="$1"; shift ;;
  esac
done

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "[silent-failure-scanner] --format must be text or json" >&2; exit 2
fi

get_diff() {
  if [[ -n "$DIFF_FILE" ]]; then
    if [[ "$DIFF_FILE" == "-" ]]; then cat; else cat "$DIFF_FILE"; fi
    return
  fi
  # auto-detect a diff on stdin ONLY when it is a real pipe or redirected file.
  # A bare non-tty stdin (e.g. /dev/null in CI, git hooks, or non-interactive
  # shells) is NOT treated as input — otherwise an empty stdin would be reported
  # as a clean diff, the exact silent false-negative this scanner guards against.
  if [[ -z "$SOURCE" ]] && { [[ -p /dev/stdin ]] || [[ -f /dev/stdin ]]; }; then
    cat; return
  fi
  case "$SOURCE" in
    staged) git diff --cached ;;
    base)   git diff "${BASE_REF}...HEAD" ;;
    range)  git diff "$RANGE" ;;
    *)      git diff HEAD ;;
  esac
}

get_diff | awk -v FORMAT="$FORMAT" -v VERSION="$VERSION" -f "$AWK_PROG"
