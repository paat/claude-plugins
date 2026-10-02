#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_GEMINI:-off}" != "on" ]; then tribunal_disabled gemini "Gemini leg disabled (default off); set TRIBUNAL_GEMINI=on to enable"; exit 0; fi
command -v agy >/dev/null 2>&1 || { tribunal_error gemini "Antigravity CLI (agy) not on PATH"; exit 0; }
AGY_TOKEN="${HOME:-}/.gemini/antigravity-cli/antigravity-oauth-token"
if [ -f "$AGY_TOKEN" ] && [ ! -L "$AGY_TOKEN" ]; then
  PROVIDER_SETTING=""
elif [ -n "${GEMINI_API_KEY:-}" ]; then
  PROVIDER_SETTING=',"modelProvider":"gemini"'
else
  tribunal_error gemini "agy is not signed in and GEMINI_API_KEY is unset"; exit 0
fi
MODEL="${TRIBUNAL_GEMINI_MODEL:-default}"

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
INPUT_DIR="$TMPDIR/input"
AGY_DIR="$TMPDIR/home/.gemini/antigravity-cli"
mkdir -p "$INPUT_DIR" "$AGY_DIR" || { tribunal_error gemini "cannot create review workspace"; exit 0; }
DIFF_FILE="$INPUT_DIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error gemini "cannot diff against $BASE_REF"; exit 0; }
DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
[ -s "$DIFF_FILE" ] || { tribunal_empty gemini "$MODEL" "$BASE_REF" "$DIFF_STAT"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
PROMPT_FILE="$TMPDIR/prompt.md"
tribunal_review_prompt gemini "$DIFF_FILE" "$CONTEXT_FILE" "diff-with-web-cve-search" > "$PROMPT_FILE"

# Isolated agy home: read-only review (headless agy auto-allows workspace writes),
# web search stays available because search_web needs no permission.
if [ -z "$PROVIDER_SETTING" ]; then
  (umask 077 && cp "$AGY_TOKEN" "$AGY_DIR/antigravity-oauth-token") \
    || { tribunal_error gemini "cannot stage agy sign-in"; exit 0; }
fi
printf '{"permissions":{"deny":["write_file(*)","command(*)","execute_url(*)","mcp(*)"]}%s}\n' \
  "$PROVIDER_SETTING" > "$AGY_DIR/settings.json"
MODEL_ARGS=()
[ "$MODEL" = default ] || MODEL_ARGS=(--model "$MODEL")

rc=0
HOME="$TMPDIR/home" timeout -k 10 600 agy ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} --add-dir "$INPUT_DIR" \
  -p "$(cat "$PROMPT_FILE")" --print-timeout 590s </dev/null > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt" || rc=$?
if [ "$rc" -eq 0 ]; then
  tribunal_extract_json_object < "$TMPDIR/out.txt" \
    | tribunal_emit_review gemini "" "$TMPDIR/out.txt" "$TMPDIR/err.txt" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" \
    | tribunal_stamp_diff_stat "$DIFF_STAT"
else
  tribunal_error_with_diagnostics gemini "Gemini execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
fi
