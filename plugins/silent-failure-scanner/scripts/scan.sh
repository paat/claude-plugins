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
VERSION="0.1.2"

FORMAT="text"
DIFF_FILE=""
SOURCE=""        # "", "staged", "base", "range"
BASE_REF=""
RANGE=""

need_val() {
  if [[ $# -lt 2 || -z "${2:-}" ]] || { [[ "${2}" == -* && "${2}" != "-" ]]; }; then
    echo "[silent-failure-scanner] $1 requires a value" >&2; exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)  need_val "$@"; FORMAT="$2"; shift 2 ;;
    --staged)  SOURCE="staged"; shift ;;
    --base)    need_val "$@"; SOURCE="base"; BASE_REF="$2"; shift 2 ;;
    -f|--file) need_val "$@"; DIFF_FILE="$2"; shift 2 ;;
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
  # auto-detect a diff on stdin ONLY when it is a real pipe or redirected file
  # AND the content actually looks like a unified diff. A bare non-tty stdin
  # (/dev/null in CI/non-interactive shells) or a git hook's stdin (which carries
  # ref metadata, not a diff) must NOT be mistaken for an empty/clean diff —
  # that would be the exact silent false-negative this scanner guards against.
  if [[ -z "$SOURCE" ]] && { [[ -p /dev/stdin ]] || [[ -f /dev/stdin ]]; }; then
    local piped; piped="$(cat)"
    if printf '%s' "$piped" | head -n 40 | grep -qE '^(diff --git |--- |\+\+\+ |@@ )'; then
      printf '%s\n' "$piped"; return
    fi
    # stdin was not a diff — fall through to the git-based source below
  fi
  case "$SOURCE" in
    staged) git diff --cached ;;
    base)   git diff "${BASE_REF}...HEAD" ;;
    range)  git diff "$RANGE" ;;
    *)      git diff HEAD ;;
  esac
}

get_diff | awk -v FORMAT="$FORMAT" -v VERSION="$VERSION" -f "$AWK_PROG"
