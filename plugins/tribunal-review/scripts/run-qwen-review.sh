#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_QWEN:-off}" != "on" ]; then tribunal_disabled qwen "Qwen leg disabled (default off, issue #46); set TRIBUNAL_QWEN=on to enable"; exit 0; fi
command -v qwen >/dev/null 2>&1 || { tribunal_error qwen "Qwen CLI not on PATH"; exit 0; }

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error qwen "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty qwen "${TRIBUNAL_QWEN_MODEL:-qwen3.7-plus}" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
PROMPT_FILE="$TMPDIR/prompt.md"
tribunal_review_prompt qwen "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"

if printf '%s\n' "$(cat "$DIFF_FILE")" | timeout -k 10 600 qwen --model "${TRIBUNAL_QWEN_MODEL:-qwen3.7-plus}" -p "$(cat "$PROMPT_FILE")" --yolo -o json > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt"; then
  response="$(jq -r '
    if type == "array" then
      (([ .[] | select(.type == "result") | .result // empty ] | last) as $r
        | if ($r != null and $r != "") then $r
          else ([ .[] | select(.type == "assistant") | (.message.content // [])[]? | select(.type == "text") | .text ] | join("")) end)
    elif type == "object" and has("response") then .response
    else empty end
  ' "$TMPDIR/out.txt" 2>/dev/null || true)"
  if [ -n "$response" ]; then
    printf '%s\n' "$response" > "$TMPDIR/response.txt"
  else
    cp "$TMPDIR/out.txt" "$TMPDIR/response.txt"
  fi
  json="$(tribunal_extract_json_object < "$TMPDIR/response.txt")"
  if printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    actual_model="$(jq -r '
      if type == "array" then
        [ .[]? | (.model // .message.model // empty) ] | map(select(. != null and . != "")) | last // empty
      elif type == "object" then
        .model // .message.model // empty
      else empty end
    ' "$TMPDIR/out.txt" 2>/dev/null || true)"
    [ -n "$actual_model" ] && json="$(printf '%s' "$json" | jq --arg m "$actual_model" '.model = $m')"
    printf '%s' "$json" | tribunal_emit_review qwen
  else
    tribunal_error qwen "unparseable Qwen output"
  fi
else
  tribunal_error qwen "Qwen execution failed or timed out"
fi
