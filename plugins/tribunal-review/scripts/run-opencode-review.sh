#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
REPO_ROOT="$(tribunal_repo_root)"

glm_on=0
deepseek_on=1
[ "${TRIBUNAL_GLM:-off}" = "on" ] && glm_on=1
[ "${TRIBUNAL_DEEPSEEK:-on}" = "off" ] && deepseek_on=0

if [ "$glm_on" -eq 0 ] && [ "$deepseek_on" -eq 0 ]; then
  tribunal_disabled glm "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"
  tribunal_disabled deepseek "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"
  exit 0
fi

if ! tribunal_prepare_diff "$DIFF_FILE"; then
  [ "$glm_on" -eq 1 ] && tribunal_error glm "cannot diff against $BASE_REF" || tribunal_disabled glm "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"
  [ "$deepseek_on" -eq 1 ] && tribunal_error deepseek "cannot diff against $BASE_REF" || tribunal_disabled deepseek "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"
  exit 0
fi
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"

run_oc_leg() {
  local provider="$1" model="$2" mode="$3" cwd="$4"
  if [ ! -s "$DIFF_FILE" ]; then tribunal_empty "$provider" "$model" "$BASE_REF"; return; fi
  command -v opencode >/dev/null 2>&1 || { tribunal_error "$provider" "OpenCode CLI not on PATH"; return; }
  local prompt="$TMPDIR/$provider.prompt.md" out="$TMPDIR/$provider.out" err="$TMPDIR/$provider.err" diff_attach
  tribunal_review_prompt "$provider" "$DIFF_FILE" "$CONTEXT_FILE" "$mode" > "$prompt"
  diff_attach="$(mktemp "$cwd/.tribunal-review-$provider.XXXXXX.diff" 2>/dev/null)" || {
    tribunal_error "$provider" "failed to stage diff into $cwd"
    return
  }
  cp "$DIFF_FILE" "$diff_attach" || {
    rm -f "$diff_attach"
    tribunal_error "$provider" "failed to copy staged diff into $cwd"
    return
  }
  # Prompt positional must precede -f: since opencode 1.15 -f is an array flag
  # that swallows a trailing positional as a file path (issue #170).
  if (cd "$cwd" && timeout -k 10 720 opencode run --agent plan -m "$model" --variant high --format default "$(cat "$prompt")" -f "$diff_attach" > "$out" 2> "$err"); then
    rm -f "$diff_attach"
    json="$(tribunal_extract_json_object < "$out")"
    printf '%s' "$json" | jq -e . >/dev/null 2>&1 && printf '%s\n' "$json" || tribunal_error "$provider" "unparseable OpenCode output"
  else
    rm -f "$diff_attach"
    tribunal_error "$provider" "OpenCode execution failed or timed out"
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
