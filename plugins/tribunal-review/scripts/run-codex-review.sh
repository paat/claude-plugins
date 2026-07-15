#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_CODEX:-on}" = "off" ]; then tribunal_disabled codex "Codex leg disabled via TRIBUNAL_CODEX=off"; exit 0; fi
command -v codex >/dev/null 2>&1 || { tribunal_error codex "Codex CLI not on PATH"; exit 0; }

BASE_REF="$(tribunal_base_ref)"
CODEX_MODEL="${TRIBUNAL_CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${TRIBUNAL_CODEX_EFFORT:-medium}"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error codex "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty codex "$CODEX_MODEL" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
PROMPT_FILE="$TMPDIR/prompt.md"
tribunal_review_prompt codex "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"

model_args=(
  --ignore-user-config --ignore-rules --strict-config
  --disable apps --disable plugins --disable hooks --disable multi_agent
  --disable browser_use --disable browser_use_external --disable browser_use_full_cdp_access
  --disable computer_use --disable in_app_browser --disable standalone_web_search
  --disable enable_mcp_apps --disable image_generation
  --dangerously-bypass-approvals-and-sandbox
  -c 'mcp_servers={}' -c 'shell_environment_policy.inherit="core"'
)
rc=0
timeout -k 10 600 codex exec "${model_args[@]}" -m "$CODEX_MODEL" \
  -c "model_reasoning_effort=\"$CODEX_EFFORT\"" -C "$REPO_ROOT" - \
  < "$PROMPT_FILE" > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt" || rc=$?
if [ "$rc" -eq 0 ]; then
  tribunal_extract_json_object < "$TMPDIR/out.txt" \
    | tribunal_emit_review codex \
      "Codex returned an unusable repository review" \
      "$TMPDIR/out.txt" "$TMPDIR/err.txt" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
else
  tribunal_error_with_diagnostics codex "Codex execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
fi
