#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_CODEX:-on}" = "off" ]; then tribunal_disabled codex "Codex leg disabled via TRIBUNAL_CODEX=off"; exit 0; fi
command -v codex >/dev/null 2>&1 || { tribunal_error codex "Codex CLI not on PATH"; exit 0; }

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error codex "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty codex "${TRIBUNAL_CODEX_MODEL:-default}" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
PROMPT_FILE="$TMPDIR/prompt.md"
tribunal_review_prompt codex "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"

model_args=()
[ -n "${TRIBUNAL_CODEX_MODEL:-}" ] && model_args=(-m "$TRIBUNAL_CODEX_MODEL")
if timeout -k 10 600 codex exec "${model_args[@]}" -C "$REPO_ROOT" - < "$PROMPT_FILE" > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt"; then
  json="$(tribunal_extract_json_object < "$TMPDIR/out.txt")"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 && printf '%s\n' "$json" || tribunal_error codex "unparseable Codex output"
else
  tribunal_error codex "Codex execution failed or timed out"
fi
