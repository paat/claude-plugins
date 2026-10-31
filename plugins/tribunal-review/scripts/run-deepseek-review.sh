#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_DEEPSEEK:-off}" != on ]; then
  tribunal_disabled deepseek "DeepSeek leg disabled (default off); set TRIBUNAL_DEEPSEEK=on to enable"
  exit 0
fi
MODE=review
case "${1:-}" in
  '') ;;
  --smoke) MODE=smoke ;;
  *) tribunal_error deepseek 'Usage: run-deepseek-review.sh [--smoke]'; exit 0 ;;
esac
command -v dsh >/dev/null 2>&1 || { tribunal_error deepseek 'dsh CLI not on PATH'; exit 0; }

TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
REPO_ROOT="$(tribunal_repo_root)"
WALK_ROOT="$(tribunal_walk_root "$TMPDIR/walk")" \
  || { tribunal_error deepseek "cannot prepare a checkout without the repository's untracked .env files"; exit 0; }
MODEL="$(tribunal_deepseek_model)"
RISK_EFFORT="$(tribunal_risk_effort deepseek)" || { tribunal_error deepseek 'invalid TRIBUNAL_RISK'; exit 0; }
EFFORT="${TRIBUNAL_DEEPSEEK_EFFORT:-$RISK_EFFORT}"
case "$EFFORT" in
  low) ;;
  ''|medium|high) EFFORT=high ;;
esac
MODEL_CONFIG="$(jq -nc --arg model "$MODEL" --arg effort "$EFFORT" \
  '{provider:"deepseek-official",model:$model,reasoningEffort:$effort}')"
{
  cat "$SCRIPT_DIR/dsh-review.patch.yml"
  printf '%s\n  config: %s\n' '- id: agent-default-model' "$MODEL_CONFIG"
} > "$TMPDIR/review.patch.yml"

PROMPT_FILE="$TMPDIR/prompt.md"
RUN_TIMEOUT=600
if [ "$MODE" = smoke ]; then
  RUN_TIMEOUT="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
  tribunal_smoke_prompt deepseek > "$PROMPT_FILE"
else
  BASE_REF="$(tribunal_base_ref)"
  DIFF_FILE="$TMPDIR/review.diff"
  CONTEXT_FILE="$TMPDIR/context.md"
  tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error deepseek "cannot diff against $BASE_REF"; exit 0; }
  DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
  [ -s "$DIFF_FILE" ] || { tribunal_empty deepseek "$MODEL" "$BASE_REF" "$DIFF_STAT"; exit 0; }
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
  tribunal_review_prompt deepseek "$DIFF_FILE" "$CONTEXT_FILE" repo-walking > "$PROMPT_FILE"
fi

OUT="$TMPDIR/out.jsonl"
ERR="$TMPDIR/err.txt"
rc=0
(cd "$WALK_ROOT" && tribunal_leg_env DEEPSEEK_API_KEY DSH_HOME -- \
  timeout -k 10 "$RUN_TIMEOUT" dsh --profile headless --patch "$TMPDIR/review.patch.yml" --json - \
  < "$PROMPT_FILE" > "$OUT" 2> "$ERR") || rc=$?
# Provider errors can contain credentials; only fixed causes and byte counts leave this runner.
export TRIBUNAL_DIAGNOSTIC_TAILS=off
if [ "$rc" -ne 0 ]; then
  case "$rc" in
    124|137) message="dsh execution timed out or was killed after ${RUN_TIMEOUT}s" ;;
    *)
      message="dsh execution failed (exit=$rc)"
      for cause in MISSING_CREDENTIAL INVALID_REQUEST RATE_LIMIT QUOTA; do
        if grep -q "^dsh: $cause:" "$ERR"; then
          message="dsh $cause"
          case "$cause" in RATE_LIMIT|QUOTA) message="plan limit: $message" ;; esac
          break
        fi
      done
      ;;
  esac
  tribunal_error_with_diagnostics deepseek "$message" execution "$rc" "$OUT" "$ERR"
elif ! jq -se '[.[] | select(.type=="status" and .phase=="turn_end")] | last | .reason.kind=="completed"' "$OUT" >/dev/null 2>&1; then
  tribunal_error_with_diagnostics deepseek 'dsh non-completed turn (missing or unsuccessful turn_end)' execution "$rc" "$OUT" "$ERR"
else
  response="$(jq -sr '[.[] | select(.type=="final")] | last | .text // empty' "$OUT")"
  json="$(printf '%s' "$response" | tribunal_extract_json_object)"
  if [ "$MODE" = smoke ]; then
    printf '%s' "$json" | tribunal_emit_review deepseek '' "$OUT" "$ERR" "$rc" \
      | tribunal_stamp_executed_model deepseek "$MODEL" "$OUT" "$ERR" "$rc"
  else
    printf '%s' "$json" | tribunal_emit_review deepseek '' "$OUT" "$ERR" "$rc" \
      | tribunal_stamp_executed_model deepseek "$MODEL" "$OUT" "$ERR" "$rc" \
      | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" | tribunal_stamp_diff_stat "$DIFF_STAT"
  fi
fi
