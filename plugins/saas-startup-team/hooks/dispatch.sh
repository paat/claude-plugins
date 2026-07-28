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

# Resolve plugin root (Claude/Codex/plugin checkout).
PLUGIN_ROOT=""
for r in "${CLAUDE_PLUGIN_ROOT:-}" "${CODEX_PLUGIN_ROOT:-}" "${PWD:-}" "${PWD:-}/.."; do
  if [ -n "$r" ] && [ -f "$r/scripts/gate.sh" ]; then
    PLUGIN_ROOT="$r"
    break
  fi
done
if [ -z "$PLUGIN_ROOT" ]; then
  # Also try relative to this script when installed as hooks/dispatch.sh.
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd || true)"
  if [ -n "$here" ] && [ -f "$here/scripts/gate.sh" ]; then
    PLUGIN_ROOT="$here"
  fi
fi

GATE="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/gate.sh}"
if [ -z "${GATE:-}" ] || [ ! -f "$GATE" ]; then
  # Drain stdin so PostToolUse pipes do not SIGPIPE the host.
  cat >/dev/null 2>&1 || true
  if [ "$MODE" = "post-write" ]; then
    echo '{"systemMessage":"[saas-startup-team] gate.sh not found — post-write advisory skip"}' >&2
    exit 0
  fi
  echo '{"systemMessage":"[saas-startup-team] critical gate target not found: scripts/gate.sh"}' >&2
  exit 2
fi

# One stdin read for all path-scoped rules.
INPUT=$(timeout 5 cat 2>/dev/null || true)
[ -n "$INPUT" ] || INPUT='{}'

run_gate() {
  # $1... = gate args; feeds $INPUT on stdin.
  printf '%s' "$INPUT" | bash "$GATE" "$@"
}

file_path=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
command=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

case "$MODE" in
  pre-write)
    # Critical: credential/token patterns before write when content is present.
    run_gate pii --hook-stdin --mode secrets || exit $?
    # Critical: schema for .json pre-write content.
    case "${file_path:-}" in
      *.json) run_gate schema --hook-stdin || exit $? ;;
    esac
    # Critical: ad budget hard stop (path-scoped).
    case "${file_path:-}" in
      *docs/growth/channels/ads.md) run_gate spend ads --hook-stdin || exit $? ;;
    esac
    # Advisory: LinkedIn rate limits (fail open).
    case "${file_path:-}" in
      *docs/growth/channels/linkedin.md) run_gate spend linkedin --hook-stdin || true ;;
    esac
    exit 0
    ;;

  pre-bash)
    # Regression gate self-filters to `gh pr merge` only; fail closed when it blocks.
    run_gate regression --hook-stdin || exit $?
    exit 0
    ;;

  post-write)
    # Critical: JSON syntax after write (content already on disk).
    case "${file_path:-}" in
      *.json) run_gate schema --hook-stdin || exit $? ;;
    esac
    # Critical: re-check spend if ads.md was written without pre-write content.
    case "${file_path:-}" in
      *docs/growth/channels/ads.md) run_gate spend ads --hook-stdin || exit $? ;;
    esac
    # Advisory: LinkedIn.
    case "${file_path:-}" in
      *docs/growth/channels/linkedin.md) run_gate spend linkedin --hook-stdin || true ;;
    esac
    exit 0
    ;;
esac
