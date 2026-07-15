#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "PREFLIGHT FAIL: jq is required." >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "PREFLIGHT FAIL: timeout is required." >&2; exit 1; }

BASE_REF="$(tribunal_base_ref)"
DEFAULT_BRANCH="$(tribunal_default_branch)"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "PREFLIGHT FAIL: on default branch '$DEFAULT_BRANCH'. Check out a review branch first." >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || {
    echo "PREFLIGHT FAIL: cannot resolve base ref $BASE_REF. Set TRIBUNAL_BASE_REF or fetch origin/$DEFAULT_BRANCH." >&2
    exit 1
  }
fi

if ! DIFF_STAT="$(git diff --stat "$BASE_REF"...HEAD 2>/dev/null)"; then
  echo "PREFLIGHT FAIL: cannot diff against $BASE_REF." >&2
  exit 1
fi
if [ -z "$DIFF_STAT" ]; then
  echo "PREFLIGHT FAIL: no changes to review against $BASE_REF." >&2
  exit 1
fi

providers_json="[]"
warnings_json="[]"
add_provider() {
  providers_json="$(printf '%s' "$providers_json" | jq --arg n "$1" --arg s "$2" --arg note "$3" '. + [{name:$n,status:$s,note:$note}]')"
}
add_warning() {
  warnings_json="$(printf '%s' "$warnings_json" | jq --arg n "$1" --arg note "$2" '. + [{name:$n,note:$note}]')"
}

if [ "${TRIBUNAL_CODEX:-on}" = "off" ]; then add_provider codex disabled "TRIBUNAL_CODEX=off"; elif command -v codex >/dev/null 2>&1; then add_provider codex usable "CLI present; non-interactive invocation not probed"; else add_provider codex skipped "CLI not on PATH"; fi
if [ "${TRIBUNAL_GEMINI:-off}" = "on" ]; then if command -v gemini >/dev/null 2>&1; then add_provider gemini usable "CLI present; non-interactive invocation not probed"; else add_provider gemini skipped "CLI not on PATH"; fi; else add_provider gemini disabled "default off"; fi
if [ "${TRIBUNAL_QWEN:-off}" = "on" ]; then if command -v qwen >/dev/null 2>&1; then add_provider qwen usable "CLI present; non-interactive invocation not probed"; else add_provider qwen skipped "CLI not on PATH"; fi; else add_provider qwen disabled "default off"; fi
if [ "${TRIBUNAL_CLAUDE:-on}" = "off" ]; then
  add_provider claude disabled "TRIBUNAL_CLAUDE=off"
elif ! command -v claude >/dev/null 2>&1; then
  add_provider claude skipped "CLI not on PATH"
elif tribunal_claude_authenticated; then
  add_provider claude usable "CLI authenticated; non-interactive invocation not probed"
else
  add_provider claude skipped "CLI not authenticated"
fi

if [ "${TRIBUNAL_GLM:-off}" = "on" ] || [ "${TRIBUNAL_DEEPSEEK:-on}" = "on" ]; then
  if command -v opencode >/dev/null 2>&1; then
    opencode models >/dev/null 2>&1 || true
    models="$(opencode models 2>/dev/null || true)"
    if [ "${TRIBUNAL_GLM:-off}" = "on" ]; then
      printf '%s\n' "$models" | grep -qxF "${TRIBUNAL_GLM_MODEL:-opencode-go/glm-5.1}" && add_provider glm usable "model registered; non-interactive invocation not probed" || add_provider glm skipped "OpenCode model not in registry"
    else
      add_provider glm disabled "default off"
    fi
    if [ "${TRIBUNAL_DEEPSEEK:-on}" = "on" ]; then
      printf '%s\n' "$models" | grep -qxF "${TRIBUNAL_DEEPSEEK_MODEL:-opencode-go/deepseek-v4-pro}" && add_provider deepseek usable "model registered; non-interactive invocation not probed" || add_provider deepseek skipped "OpenCode model not in registry"
    else
      add_provider deepseek disabled "TRIBUNAL_DEEPSEEK=off"
    fi
  else
    [ "${TRIBUNAL_GLM:-off}" = "on" ] && add_provider glm skipped "opencode CLI not on PATH" || add_provider glm disabled "default off"
    [ "${TRIBUNAL_DEEPSEEK:-on}" = "on" ] && add_provider deepseek skipped "opencode CLI not on PATH" || add_provider deepseek disabled "TRIBUNAL_DEEPSEEK=off"
  fi
else
  add_provider glm disabled "default off"
  add_provider deepseek disabled "TRIBUNAL_DEEPSEEK=off"
fi

avail_kb="$(df -Pk "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 2097152 ]; then
  add_warning disk "only $((avail_kb / 1024)) MiB free on ${TMPDIR:-/tmp}; reviewers may stall on writes"
fi

usable="$(printf '%s' "$providers_json" | jq '[.[] | select(.status=="usable")] | length')"
if [ "$usable" -eq 0 ]; then
  echo "PREFLIGHT FAIL: zero active reviewer legs are usable." >&2
  printf '%s\n' "$providers_json" >&2
  exit 1
fi

jq -nc --arg base "$BASE_REF" --arg default "$DEFAULT_BRANCH" --argjson providers "$providers_json" --argjson warnings "$warnings_json" \
  '{status:"ok",base_ref:$base,default_branch:$default,providers:$providers,warnings:$warnings}'
