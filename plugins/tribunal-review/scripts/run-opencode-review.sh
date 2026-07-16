#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

MODE=review
ARG_ERROR=0
case "${1:-}" in
  '') ;;
  --smoke) MODE=smoke ;;
  *) ARG_ERROR=1 ;;
esac

TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
REPO_ROOT="$(tribunal_repo_root)"

glm_on=0
deepseek_on=1
[ "${TRIBUNAL_GLM:-off}" = "on" ] && glm_on=1
[ "${TRIBUNAL_DEEPSEEK:-on}" = "off" ] && deepseek_on=0

if [ "$ARG_ERROR" -eq 1 ]; then
  [ "$glm_on" -eq 1 ] \
    && tribunal_error glm "Usage: run-opencode-review.sh [--smoke]" \
    || tribunal_disabled glm "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"
  [ "$deepseek_on" -eq 1 ] \
    && tribunal_error deepseek "Usage: run-opencode-review.sh [--smoke]" \
    || tribunal_disabled deepseek "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"
  exit 0
fi

if [ "$glm_on" -eq 0 ] && [ "$deepseek_on" -eq 0 ]; then
  tribunal_disabled glm "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"
  tribunal_disabled deepseek "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"
  exit 0
fi

if [ "$MODE" = review ]; then
  BASE_REF="$(tribunal_base_ref)"
  CONTEXT_FILE="$TMPDIR/context.md"
  if ! tribunal_prepare_diff "$DIFF_FILE"; then
    [ "$glm_on" -eq 1 ] && tribunal_error glm "cannot diff against $BASE_REF" || tribunal_disabled glm "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"
    [ "$deepseek_on" -eq 1 ] && tribunal_error deepseek "cannot diff against $BASE_REF" || tribunal_disabled deepseek "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"
    exit 0
  fi
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
fi

run_oc_leg() {
  local provider="$1" model="$2" mode="$3" cwd="$4"
  if [ "$MODE" = review ] && [ ! -s "$DIFF_FILE" ]; then tribunal_empty "$provider" "$model" "$BASE_REF"; return; fi
  command -v opencode >/dev/null 2>&1 || { tribunal_error "$provider" "OpenCode CLI not on PATH"; return; }
  local prompt="$TMPDIR/$provider.prompt.md" out="$TMPDIR/$provider.out" err="$TMPDIR/$provider.err" diff_attach
  if [ "$MODE" = smoke ]; then
    tribunal_smoke_prompt "$provider" > "$prompt"
  else
    tribunal_review_prompt "$provider" "$DIFF_FILE" "$CONTEXT_FILE" "$mode" > "$prompt"
  fi
  local rc=0 run_timeout=720
  [ "$MODE" = smoke ] && run_timeout="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
  if [ "$MODE" = smoke ]; then
    (cd "$cwd" && timeout -k 10 "$run_timeout" opencode run --pure \
      --dangerously-skip-permissions --agent plan -m "$model" --variant high \
      --format default "$(cat "$prompt")" > "$out" 2> "$err") || rc=$?
    if [ "$rc" -eq 0 ]; then
      tribunal_extract_json_object < "$out" \
        | tribunal_emit_review "$provider" "" "$out" "$err" "$rc"
    else
      tribunal_error_with_diagnostics "$provider" "OpenCode smoke failed or timed out" \
        execution "$rc" "$out" "$err"
    fi
    return
  fi
  diff_attach="$(mktemp "$cwd/.tribunal-review-$provider.XXXXXX.diff" 2>/dev/null)" || {
    tribunal_error "$provider" "failed to stage diff into $cwd"
    return
  }
  cp "$DIFF_FILE" "$diff_attach" || {
    rm -f "$diff_attach"
    tribunal_error "$provider" "failed to copy staged diff into $cwd"
    return
  }
  (cd "$cwd" && timeout -k 10 "$run_timeout" opencode run --pure \
    --dangerously-skip-permissions --agent plan -m "$model" --variant high \
    --format default "$(cat "$prompt")" -f "$diff_attach" > "$out" 2> "$err") || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$diff_attach"
    tribunal_extract_json_object < "$out" \
      | tribunal_emit_review "$provider" "" "$out" "$err" "$rc" \
      | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
  else
    rm -f "$diff_attach"
    tribunal_error_with_diagnostics "$provider" "OpenCode execution failed or timed out" \
      execution "$rc" "$out" "$err"
  fi
}

if [ "$glm_on" -eq 1 ]; then
  GLM_TMP="$(mktemp -d "$TMPDIR/glm.XXXXXX")"
  run_oc_leg glm "${TRIBUNAL_GLM_MODEL:-opencode-go/glm-5.1}" "diff-only" "$GLM_TMP"
else
  tribunal_disabled glm "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"
fi

if [ "$deepseek_on" -eq 0 ]; then
  tribunal_disabled deepseek "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"
else
  run_oc_leg deepseek "${TRIBUNAL_DEEPSEEK_MODEL:-opencode-go/deepseek-v4-pro}" "repo-walking" "$REPO_ROOT"
fi
