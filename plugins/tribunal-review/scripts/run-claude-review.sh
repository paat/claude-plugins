#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_CLAUDE:-on}" = "off" ]; then tribunal_disabled claude "Claude Code leg disabled via TRIBUNAL_CLAUDE=off"; exit 0; fi
command -v claude >/dev/null 2>&1 || { tribunal_error claude "Claude CLI not on PATH"; exit 0; }

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error claude "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty claude "${TRIBUNAL_CLAUDE_MODEL:-sonnet}" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
PROMPT_FILE="$TMPDIR/prompt.md"
tribunal_review_prompt claude "$DIFF_FILE" "$CONTEXT_FILE" "diff-only" > "$PROMPT_FILE"

# Run from scratch with all tools disabled: this is the physical guarantee behind diff-only.
SCRATCH="$(mktemp -d "$TMPDIR/claude.XXXXXX")"
if (cd "$SCRATCH" && printf '%s\n' "$(cat "$DIFF_FILE")" | timeout -k 10 600 claude -p "$(cat "$PROMPT_FILE")" --model "${TRIBUNAL_CLAUDE_MODEL:-sonnet}" --output-format json --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" > "$TMPDIR/out.json" 2> "$TMPDIR/err.txt"); then
  response="$(jq -r '.result // empty' "$TMPDIR/out.json" 2>/dev/null || true)"
  json="$(printf '%s\n' "$response" | tribunal_extract_json_object)"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 && printf '%s\n' "$json" || tribunal_error claude "unparseable Claude output"
else
  tribunal_error claude "Claude execution failed or timed out"
fi
