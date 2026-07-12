#!/usr/bin/env bash
# Compatibility wrapper for the profile-aware, explicitly pinned Codex launcher.
#
# Usage: codex-implement.sh --handoff FILE [--plan FILE] [options]
#        codex-implement.sh --task TEXT [options]
# Options: --profile light|standard|deep --model MODEL --effort EFFORT
#          --timeout DURATION --log FILE

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF="" TASK="" PLAN="" MODEL="" EFFORT="" TIMEOUT="" LOG=""
PROFILE="${TF_CODEX_PROFILE:-standard}"

usage() {
  echo "usage: codex-implement.sh (--handoff FILE [--plan FILE] | --task TEXT) [--profile light|standard|deep] [--model MODEL] [--effort EFFORT] [--timeout DURATION] [--log FILE]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --handoff) [ "$#" -ge 2 ] || usage; HANDOFF="$2"; shift 2 ;;
    --task) [ "$#" -ge 2 ] || usage; TASK="$2"; shift 2 ;;
    --plan) [ "$#" -ge 2 ] || usage; PLAN="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; PROFILE="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || usage; MODEL="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || usage; EFFORT="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || usage; TIMEOUT="$2"; shift 2 ;;
    --log) [ "$#" -ge 2 ] || usage; LOG="$2"; shift 2 ;;
    *) usage ;;
  esac
done

case "$PROFILE" in light|standard|deep) : ;; *) usage ;; esac
if { [ -n "$HANDOFF" ] && [ -n "$TASK" ]; } || { [ -z "$HANDOFF" ] && [ -z "$TASK" ]; }; then
  usage
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "codex-implement: not inside a git worktree" >&2
  exit 4
}
resolve_file() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;; esac
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
combined="$tmpdir/task.md"
{
  printf '%s\n' 'TECH-FOUNDER IMPLEMENTATION CONTRACT'
  printf '%s\n' '- Write only the scoped source, tests, and workflow-spec changes required by the task.'
  printf '%s\n' '- Preserve authentication, validation, Unicode text, and bounded network timeouts.'
  printf '%s\n' '- Add a regression guard for bug or incident fixes and run the canonical local check.'
  printf '%s\n' '- Leave the verified diff uncommitted for the supervisor-owned commit gate.'
  printf '\n================ HANDOFF / TASK ================\n'
  if [ -n "$HANDOFF" ]; then
    handoff_path="$(resolve_file "$HANDOFF")"
    [ -f "$handoff_path" ] && [ -r "$handoff_path" ] || {
      echo "codex-implement: handoff file not readable: $HANDOFF" >&2
      exit 4
    }
    cat "$handoff_path"
  else
    [ -n "$(printf '%s' "$TASK" | tr -d '[:space:]')" ] || usage
    printf '%s\n' "$TASK"
  fi
  if [ -n "$PLAN" ]; then
    plan_path="$(resolve_file "$PLAN")"
    [ -f "$plan_path" ] && [ -r "$plan_path" ] || {
      echo "codex-implement: plan file not readable: $PLAN" >&2
      exit 4
    }
    printf '\n================ TECHNICAL PLAN ================\n'
    cat "$plan_path"
  fi
} > "$combined"

upper="${PROFILE^^}"
env_args=()
effective_model="${MODEL:-${TF_CODEX_MODEL:-}}"
effective_effort="${EFFORT:-${TF_CODEX_EFFORT:-}}"
[ -z "$effective_model" ] || env_args+=("SAAS_CODEX_${upper}_MODEL=$effective_model")
[ -z "$effective_effort" ] || env_args+=("SAAS_CODEX_${upper}_EFFORT=$effective_effort")
effective_timeout="${TIMEOUT:-${TF_CODEX_TIMEOUT:-}}"
[ -z "$effective_timeout" ] || env_args+=("SAAS_CODEX_ROLE_TIMEOUT=$effective_timeout")
if [ -n "$LOG" ]; then
  case "$LOG" in /*) : ;; *) LOG="$REPO_ROOT/$LOG" ;; esac
  env_args+=("SAAS_CODEX_LOG_FILE=$LOG")
fi

rc=0
env "${env_args[@]}" "$SCRIPT_DIR/codex-run-role.sh" \
  --role tech-founder --profile "$PROFILE" --task-file "$combined" || rc=$?
exit "$rc"
