#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

MODE=review
case "${1:-}" in
  '') ;;
  --smoke) MODE=smoke ;;
  *) tribunal_error claude "Usage: run-claude-review.sh [--smoke]"; exit 0 ;;
esac

if [ "${TRIBUNAL_CLAUDE:-on}" = "off" ]; then tribunal_disabled claude "Claude Code leg disabled via TRIBUNAL_CLAUDE=off"; exit 0; fi
command -v claude >/dev/null 2>&1 || { tribunal_error claude "Claude CLI not on PATH"; exit 0; }
TMPDIR="$(mktemp -d)" || exit 1
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT
tribunal_claude_authenticated || { tribunal_error claude "Claude CLI is not authenticated"; exit 0; }

DIFF_FILE="$TMPDIR/review.diff"
REPO_ROOT="$(tribunal_repo_root)"
PROMPT_FILE="$TMPDIR/prompt.md"
if [ "$MODE" = smoke ]; then
  tribunal_smoke_prompt claude > "$PROMPT_FILE"
else
  BASE_REF="$(tribunal_base_ref)"
  CONTEXT_FILE="$TMPDIR/context.md"
  tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error claude "cannot diff against $BASE_REF"; exit 0; }
  [ -s "$DIFF_FILE" ] || { tribunal_empty claude "${TRIBUNAL_CLAUDE_MODEL:-sonnet}" "$BASE_REF"; exit 0; }
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
  tribunal_review_prompt claude "$DIFF_FILE" "$CONTEXT_FILE" "diff-only" > "$PROMPT_FILE"
fi

SCRATCH="$(mktemp -d "$TMPDIR/claude.XXXXXX")"
rc=0
RUN_TIMEOUT=600
[ "$MODE" = smoke ] && RUN_TIMEOUT="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
SCHEMA_JSON="$(jq -c . "$(tribunal_review_schema)")"
if [ "$MODE" = smoke ]; then
  (cd "$SCRATCH" && timeout -k 10 "$RUN_TIMEOUT" claude -p \
    --model "${TRIBUNAL_CLAUDE_MODEL:-sonnet}" --output-format json \
    --json-schema "$SCHEMA_JSON" --safe-mode --disable-slash-commands \
    --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --no-session-persistence < "$PROMPT_FILE" > "$TMPDIR/out.json" 2> "$TMPDIR/err.txt") || rc=$?
else
  (cd "$SCRATCH" && {
    cat "$PROMPT_FILE"
    printf '\n## Unified Diff\n'
    cat "$DIFF_FILE"
  } | timeout -k 10 "$RUN_TIMEOUT" claude -p \
    --model "${TRIBUNAL_CLAUDE_MODEL:-sonnet}" --output-format json \
    --json-schema "$SCHEMA_JSON" --safe-mode --disable-slash-commands \
    --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --no-session-persistence > "$TMPDIR/out.json" 2> "$TMPDIR/err.txt") || rc=$?
fi
if [ "$rc" -eq 0 ]; then
  tribunal_extract_claude_result < "$TMPDIR/out.json" > "$TMPDIR/response.txt"
  if [ "$MODE" = smoke ]; then
    tribunal_extract_json_object < "$TMPDIR/response.txt" \
      | tribunal_emit_review claude "" "$TMPDIR/out.json" "$TMPDIR/err.txt" "$rc"
  else
    tribunal_extract_json_object < "$TMPDIR/response.txt" \
      | tribunal_emit_review claude "" "$TMPDIR/out.json" "$TMPDIR/err.txt" "$rc" \
      | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
  fi
else
  tribunal_error_with_diagnostics claude "Claude execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.json" "$TMPDIR/err.txt"
fi
