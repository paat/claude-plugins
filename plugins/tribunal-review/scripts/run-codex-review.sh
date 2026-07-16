#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

MODE=review
case "${1:-}" in
  '') ;;
  --smoke) MODE=smoke ;;
  *) tribunal_error codex "Usage: run-codex-review.sh [--smoke]"; exit 0 ;;
esac

if [ "${TRIBUNAL_CODEX:-on}" = "off" ]; then tribunal_disabled codex "Codex leg disabled via TRIBUNAL_CODEX=off"; exit 0; fi
command -v codex >/dev/null 2>&1 || { tribunal_error codex "Codex CLI not on PATH"; exit 0; }

CODEX_MODEL="${TRIBUNAL_CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${TRIBUNAL_CODEX_EFFORT:-medium}"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
REPO_ROOT="$(tribunal_repo_root)"
PROMPT_FILE="$TMPDIR/prompt.md"
DIFF_FILE="$TMPDIR/review.diff"
if [ "$MODE" = smoke ]; then
  tribunal_smoke_prompt codex > "$PROMPT_FILE"
else
  BASE_REF="$(tribunal_base_ref)"
  CONTEXT_FILE="$TMPDIR/context.md"
  tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error codex "cannot diff against $BASE_REF"; exit 0; }
  [ -s "$DIFF_FILE" ] || { tribunal_empty codex "$CODEX_MODEL" "$BASE_REF"; exit 0; }
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
  tribunal_review_prompt codex "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
fi

model_args=(
  --ignore-user-config --ignore-rules --strict-config
  --disable apps --disable plugins --disable hooks --disable multi_agent
  --disable browser_use --disable browser_use_external --disable browser_use_full_cdp_access
  --disable computer_use --disable in_app_browser --disable standalone_web_search
  --disable enable_mcp_apps --disable image_generation
  --dangerously-bypass-approvals-and-sandbox
  --ephemeral --color never
  -c 'mcp_servers={}' -c 'shell_environment_policy.inherit="core"'
)
rc=0
RUN_TIMEOUT=600
[ "$MODE" = smoke ] && RUN_TIMEOUT="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
LAST_FILE="$TMPDIR/last-message.json"
SCHEMA_FILE="$(tribunal_review_schema)"
timeout -k 10 "$RUN_TIMEOUT" codex exec "${model_args[@]}" -m "$CODEX_MODEL" \
  -c "model_reasoning_effort=\"$CODEX_EFFORT\"" --output-schema "$SCHEMA_FILE" \
  --output-last-message "$LAST_FILE" -C "$REPO_ROOT" - \
  < "$PROMPT_FILE" > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt" || rc=$?
if [ "$rc" -eq 0 ]; then
  RESPONSE_FILE="$TMPDIR/out.txt"
  [ -s "$LAST_FILE" ] && RESPONSE_FILE="$LAST_FILE"
  if [ "$MODE" = smoke ]; then
    tribunal_extract_json_object < "$RESPONSE_FILE" \
      | tribunal_emit_review codex "Codex returned an unusable smoke response" \
        "$RESPONSE_FILE" "$TMPDIR/err.txt" "$rc"
  else
    tribunal_extract_json_object < "$RESPONSE_FILE" \
      | tribunal_emit_review codex \
        "Codex returned an unusable repository review" \
        "$RESPONSE_FILE" "$TMPDIR/err.txt" "$rc" \
      | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
  fi
else
  tribunal_error_with_diagnostics codex "Codex execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
fi
