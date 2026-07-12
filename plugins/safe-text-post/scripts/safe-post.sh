#!/usr/bin/env bash
# safe-post.sh — file-based posting with unicode lint and read-back verification.
#
# Usage:
#   safe-post.sh lint <file>
#   safe-post.sh post --via <adapter> --repo OWNER/REPO --number N --file F [--no-verify]
#   safe-post.sh verify --via <adapter> --repo OWNER/REPO --number N --file F [--comment-id ID]
#
# Adapters: issue-comment | issue-body | pr-body
#   (a PR comment IS an issue comment on GitHub — use issue-comment with the PR number)
#
# Exit codes: 0 posted+verified (or lint clean); 2 usage; 4 lint hazard;
#             5 post failed; 6 read-back verification FAILED (content differs).
set -uo pipefail

MODE="${1:-}"; [ "$#" -gt 0 ] && shift || { echo "safe-post: mode required" >&2; exit 2; }
VIA=""; REPO=""; NUMBER=""; FILE=""; VERIFY=1; COMMENT_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --via)        VIA="${2:?}"; shift 2 ;;
    --repo)       REPO="${2:?}"; shift 2 ;;
    --number)     NUMBER="${2:?}"; shift 2 ;;
    --file)       FILE="${2:?}"; shift 2 ;;
    --comment-id) COMMENT_ID="${2:?}"; shift 2 ;;
    --no-verify)  VERIFY=0; shift ;;
    *) [ "$MODE" = "lint" ] && [ -z "$FILE" ] && { FILE="$1"; shift; continue; }
       echo "safe-post: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$FILE" ] || { echo "safe-post: --file required" >&2; exit 2; }
[ -f "$FILE" ] || { echo "safe-post: no such file: $FILE" >&2; exit 2; }

lint_file() { # exit 0 clean, 4 hazards. Curly quotes are legitimate content —
  # the round-trip verification proves they survive; only invisible characters
  # and an empty payload are hard lint failures.
  local rc=0
  if ! [ -s "$1" ] || ! grep -q '[^[:space:]]' "$1"; then
    echo "safe-post: LINT payload is empty/whitespace-only — this is the empty-post failure class" >&2
    return 4
  fi
  local zw
  zw="$(grep -noP '\x{200B}|\x{200C}|\x{200D}|\x{2060}|\x{FEFF}' "$1" 2>/dev/null | cut -d: -f1 | sort -un | head -5 | tr '\n' ',' | sed 's/,$//')"
  if [ -n "$zw" ]; then
    echo "safe-post: LINT invisible zero-width character(s) on line(s) $zw — strip them (they corrupt payloads silently)" >&2
    rc=4
  fi
  return "$rc"
}

normalize() { tr -d '\r' < "$1"; }

fetch_body() { # -> stored body on stdout
  case "$VIA" in
    issue-comment)
      [ -n "$COMMENT_ID" ] || { echo "safe-post: --comment-id required to verify a comment" >&2; return 2; }
      gh api "repos/$REPO/issues/comments/$COMMENT_ID" --jq .body ;;
    issue-body) gh api "repos/$REPO/issues/$NUMBER" --jq .body ;;
    pr-body)    gh api "repos/$REPO/pulls/$NUMBER" --jq .body ;;
    *) echo "safe-post: unknown adapter: $VIA (issue-comment|issue-body|pr-body)" >&2; return 2 ;;
  esac
}

verify_body() { # read back and byte-compare (line endings normalized)
  local stored rc=0
  stored="$(fetch_body)" || return 6
  if ! diff -q <(normalize "$FILE") <(printf '%s\n' "$stored" | tr -d '\r') >/dev/null 2>&1 \
     && ! diff -q <(normalize "$FILE") <(printf '%s' "$stored" | tr -d '\r') >/dev/null 2>&1; then
    echo "safe-post: VERIFY FAILED — stored content differs from $FILE; treat the post as corrupted, delete and repost" >&2
    return 6
  fi
  echo "safe-post: verified — stored content matches $FILE ($(wc -c < "$FILE" | tr -d ' ') bytes)"
}

case "$MODE" in
  lint)
    lint_file "$FILE"; exit $? ;;
  post)
    [ -n "$VIA" ] && [ -n "$REPO" ] || { echo "safe-post: --via and --repo required" >&2; exit 2; }
    lint_file "$FILE" || exit 4
    case "$VIA" in
      issue-comment)
        [ -n "$NUMBER" ] || { echo "safe-post: --number required" >&2; exit 2; }
        resp="$(gh api "repos/$REPO/issues/$NUMBER/comments" -X POST -F "body=@$FILE" --jq .id)" \
          || { echo "safe-post: post failed" >&2; exit 5; }
        COMMENT_ID="$resp"
        echo "safe-post: posted comment id=$COMMENT_ID" ;;
      issue-body)
        [ -n "$NUMBER" ] || { echo "safe-post: --number required" >&2; exit 2; }
        gh api "repos/$REPO/issues/$NUMBER" -X PATCH -F "body=@$FILE" --jq .number >/dev/null \
          || { echo "safe-post: post failed" >&2; exit 5; }
        echo "safe-post: updated issue #$NUMBER body" ;;
      pr-body)
        [ -n "$NUMBER" ] || { echo "safe-post: --number required" >&2; exit 2; }
        gh api "repos/$REPO/pulls/$NUMBER" -X PATCH -F "body=@$FILE" --jq .number >/dev/null \
          || { echo "safe-post: post failed" >&2; exit 5; }
        echo "safe-post: updated PR #$NUMBER body" ;;
      *) echo "safe-post: unknown adapter: $VIA (issue-comment|issue-body|pr-body)" >&2; exit 2 ;;
    esac
    [ "$VERIFY" -eq 1 ] || exit 0
    verify_body; exit $? ;;
  verify)
    [ -n "$VIA" ] && [ -n "$REPO" ] || { echo "safe-post: --via and --repo required" >&2; exit 2; }
    verify_body; exit $? ;;
  *) echo "safe-post: unknown mode: $MODE (lint|post|verify)" >&2; exit 2 ;;
esac
