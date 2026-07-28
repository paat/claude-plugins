#!/usr/bin/env bash
# dispatch.sh — path-scoped hook dispatcher (issue #391).
#
# Invoked from hooks.json for PreToolUse / PostToolUse. Routes to scripts/gate.sh
# only. Never commits, never mutates orchestration state, never redacts in place.
#
# Usage (stdin = host hook JSON):
#   dispatch.sh pre-write   # Write|Edit before mutation
#   dispatch.sh pre-bash    # Bash before execution
#   dispatch.sh post-write  # Write|Edit after mutation
#
# Critical rules fail closed (exit 2). Advisory rules fail open (exit 0 + warning).
# Missing gate binary fails closed for pre-* (critical path) and open for post-*.

set -uo pipefail

MODE="${1:-}"
case "$MODE" in
  pre-write|pre-bash|post-write) ;;
  *)
    echo '{"systemMessage":"[saas-startup-team] dispatch: usage: dispatch.sh pre-write|pre-bash|post-write"}' >&2
    exit 2
    ;;
esac

# Prefer the plugin that owns this dispatcher (never a random repo-local gate.sh).
PLUGIN_ROOT=""
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/scripts/gate.sh" ]; then
  PLUGIN_ROOT="$here"
fi
if [ -z "$PLUGIN_ROOT" ]; then
  for r in "${CLAUDE_PLUGIN_ROOT:-}" "${CODEX_PLUGIN_ROOT:-}"; do
    if [ -n "$r" ] && [ -f "$r/scripts/gate.sh" ]; then
      PLUGIN_ROOT="$r"
      break
    fi
  done
fi

GATE="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/gate.sh}"
if [ -z "${GATE:-}" ] || [ ! -f "$GATE" ]; then
  cat >/dev/null 2>&1 || true
  if [ "$MODE" = "post-write" ]; then
    echo '{"systemMessage":"[saas-startup-team] gate.sh not found — post-write advisory skip"}' >&2
    exit 0
  fi
  echo '{"systemMessage":"[saas-startup-team] critical gate target not found: scripts/gate.sh"}' >&2
  exit 2
fi

INPUT=$(timeout 5 cat 2>/dev/null || true)
[ -n "$INPUT" ] || INPUT='{}'

run_gate() {
  printf '%s' "$INPUT" | bash "$GATE" "$@"
}

file_path=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
# Write usually has content; Edit may only have old_string/new_string.
content=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
has_content=0
[ -n "$content" ] && has_content=1

case "$MODE" in
  pre-write)
    # Secrets before write only when the host supplies content (blocking PreToolUse).
    if [ "$has_content" -eq 1 ]; then
      run_gate pii --hook-stdin --mode secrets || exit $?
    fi
    # Schema / spend: require content so we never block a fix using stale on-disk state.
    if [ "$has_content" -eq 1 ]; then
      case "${file_path:-}" in
        *.json) run_gate schema --hook-stdin || exit $? ;;
      esac
      case "${file_path:-}" in
        *docs/growth/channels/ads.md) run_gate spend ads --hook-stdin || exit $? ;;
      esac
      case "${file_path:-}" in
        *docs/growth/channels/linkedin.md) run_gate spend linkedin --hook-stdin || true ;;
      esac
    fi
    exit 0
    ;;

  pre-bash)
    run_gate regression --hook-stdin || exit $?
    exit 0
    ;;

  post-write)
    case "${file_path:-}" in
      *.json) run_gate schema --hook-stdin || exit $? ;;
    esac
    case "${file_path:-}" in
      *docs/growth/channels/ads.md) run_gate spend ads --hook-stdin || exit $? ;;
    esac
    case "${file_path:-}" in
      *docs/growth/channels/linkedin.md) run_gate spend linkedin --hook-stdin || true ;;
    esac
    exit 0
    ;;
esac
