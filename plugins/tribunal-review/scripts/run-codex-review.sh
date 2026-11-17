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

CODEX_MODEL="${TRIBUNAL_CODEX_MODEL:-gpt-6-astra}"
RISK_EFFORT="$(tribunal_risk_effort codex 2>&1)" || { tribunal_error codex "$RISK_EFFORT"; exit 0; }
if [ "${TRIBUNAL_PANEL_SELECTED:-0}" = 1 ]; then
  CODEX_EFFORT="${TRIBUNAL_CODEX_EFFORT:-}"
else
  CODEX_EFFORT="${TRIBUNAL_CODEX_EFFORT:-${RISK_EFFORT:-medium}}"
fi
[ "$CODEX_EFFORT" != "-" ] || CODEX_EFFORT=""
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
# The sealed collector limits every wrapper to 4 GiB (ulimit -f 4194304). Keep Codex's mutable
# runtime databases out of the caller home while retaining its credentials.
HOST_CODEX_HOME="${CODEX_HOME:-${HOME:-}/.codex}"
ISOLATED_CODEX_HOME="$TMPDIR/codex-home"
mkdir -p "$ISOLATED_CODEX_HOME" || { tribunal_error codex "cannot create isolated Codex home"; exit 0; }
if [ -f "$HOST_CODEX_HOME/auth.json" ] && ! cp -p "$HOST_CODEX_HOME/auth.json" "$ISOLATED_CODEX_HOME/auth.json"; then
  tribunal_error codex "cannot copy Codex authentication into isolated home"
  exit 0
fi
REPO_ROOT="$(tribunal_repo_root)"
WALK_ROOT="$(tribunal_walk_root "$TMPDIR/walk")" \
  || { tribunal_error codex "cannot prepare a checkout without the repository's untracked .env files"; exit 0; }
PROMPT_FILE="$TMPDIR/prompt.md"
DIFF_FILE="$TMPDIR/review.diff"
model_args=(
  --ignore-user-config --ignore-rules --strict-config
  --disable apps --disable plugins --disable hooks --disable multi_agent
  --disable browser_use --disable browser_use_external --disable browser_use_full_cdp_access
  --disable computer_use --disable in_app_browser --disable standalone_web_search
  --disable enable_mcp_apps --disable image_generation
  --dangerously-bypass-approvals-and-sandbox
  --ephemeral
  -c 'mcp_servers={}' -c 'shell_environment_policy.inherit="core"'
)
effort_args=()
[ -z "$CODEX_EFFORT" ] || effort_args=(-c "model_reasoning_effort=\"$CODEX_EFFORT\"")
NATIVE_NOTE=""
if [ "$MODE" = smoke ]; then
  tribunal_smoke_prompt codex > "$PROMPT_FILE"
else
  BASE_REF="$(tribunal_base_ref)"
  CONTEXT_FILE="$TMPDIR/context.md"
  tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error codex "cannot diff against $BASE_REF"; exit 0; }
  DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
  [ -s "$DIFF_FILE" ] || { tribunal_empty codex "$CODEX_MODEL" "$BASE_REF" "$DIFF_STAT"; exit 0; }
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
  if [ "${TRIBUNAL_NATIVE_REVIEW:-on}" != off ]; then
    # A clone pinned to the reviewed head keeps uncommitted changes out of the native diff.
    NATIVE_ROOT="$WALK_ROOT"
    [ "$WALK_ROOT" != "$REPO_ROOT" ] \
      || NATIVE_ROOT="$(tribunal_walk_root "$TMPDIR/native-walk" "$(printf '%s' "$DIFF_STAT" | jq -r '.head_oid')")" \
      || NATIVE_ROOT="$WALK_ROOT"
    # The reviewer runs on review_model, not -m. Efforts above high would spend the native budget.
    native_effort_args=(${effort_args[@]+"${effort_args[@]}"})
    case "$CODEX_EFFORT" in xhigh|max|ultra) native_effort_args=(-c 'model_reasoning_effort="high"') ;; esac
    native_rc=0
    (cd "$NATIVE_ROOT" && env CODEX_HOME="$ISOLATED_CODEX_HOME" timeout -k 10 "$tribunal_native_seconds" codex exec review \
      "${model_args[@]}" ${native_effort_args[@]+"${native_effort_args[@]}"} -m "$CODEX_MODEL" -c "review_model=\"$CODEX_MODEL\"" \
      --base "$(printf '%s' "$DIFF_STAT" | jq -r '.base_oid')" \
      --output-last-message "$TMPDIR/native.txt" < /dev/null > /dev/null 2> "$TMPDIR/native.err") || native_rc=$?
    NATIVE_NOTE="$(tribunal_native_leads 'codex exec review' "$TMPDIR/native.txt" "$native_rc" "$CONTEXT_FILE" "$TMPDIR/native.err")"
  fi
  tribunal_review_prompt codex "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
fi

rc=0
RUN_TIMEOUT="$(tribunal_verdict_timeout)"
[ "$MODE" = smoke ] && RUN_TIMEOUT="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
LAST_FILE="$TMPDIR/last-message.json"
SCHEMA_FILE="$(tribunal_review_schema)"
env CODEX_HOME="$ISOLATED_CODEX_HOME" timeout -k 10 "$RUN_TIMEOUT" codex exec "${model_args[@]}" ${effort_args[@]+"${effort_args[@]}"} --color never -m "$CODEX_MODEL" \
  --output-schema "$SCHEMA_FILE" \
  --output-last-message "$LAST_FILE" -C "$WALK_ROOT" - \
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
      | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" \
      | tribunal_stamp_diff_stat "$DIFF_STAT" \
      | tribunal_stamp_note "$NATIVE_NOTE"
  fi
else
  tribunal_error_with_diagnostics codex "Codex execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
fi
