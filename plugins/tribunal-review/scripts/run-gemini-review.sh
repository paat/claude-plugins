#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_GEMINI:-off}" != "on" ]; then tribunal_disabled gemini "Gemini leg disabled (default off); set TRIBUNAL_GEMINI=on to enable"; exit 0; fi
command -v gemini >/dev/null 2>&1 || { tribunal_error gemini "Gemini CLI not on PATH"; exit 0; }

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error gemini "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty gemini "${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
PROMPT_FILE="$TMPDIR/prompt.md"
tribunal_review_prompt gemini "$DIFF_FILE" "$CONTEXT_FILE" "diff-with-web-cve-search" > "$PROMPT_FILE"

rc=0
printf '%s\n' "$(cat "$DIFF_FILE")" | timeout -k 10 600 gemini --model "${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}" -p "$(cat "$PROMPT_FILE")" > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt" || rc=$?
if [ "$rc" -eq 0 ]; then
  tribunal_extract_json_object < "$TMPDIR/out.txt" \
    | tribunal_emit_review gemini "" "$TMPDIR/out.txt" "$TMPDIR/err.txt" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
else
  tribunal_error_with_diagnostics gemini "Gemini execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
fi
