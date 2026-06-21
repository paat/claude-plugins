#!/usr/bin/env bash
# monitor-dedup.sh — deterministic engine for /monitor-nightly. Generic/project-agnostic.
#   window --state <file>
#   commit --state <file> [--repo S] [--labels a,b] [--repro-recipe TPL] [--dry-run]
# Owns ALL state I/O and ALL `gh` calls (including repo resolution).
set -euo pipefail

_die() { echo "monitor-dedup: $*" >&2; exit 1; }
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_iso_to_epoch() { date -u -d "$1" +%s 2>/dev/null; }   # non-fatal: empty on bad input

# Echo a usable state object, or "" if missing/corrupt.
_read_state() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  if jq -e '.version == 1 and (.patterns|type=="object")' "$f" >/dev/null 2>&1; then
    cat "$f"
  else
    echo ""
  fi
}

cmd_window() {
  local state_file="" minutes since now last epoch
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state_file="$2"; shift 2 ;;
      *) _die "window: unknown arg $1" ;;
    esac
  done
  [ -n "$state_file" ] || _die "window: --state required"
  local state; state="$(_read_state "$state_file")"
  last="$(printf '%s' "$state" | jq -r '.last_run_at // empty' 2>/dev/null || true)"
  now="$(date -u +%s)"
  epoch=""
  if [ -n "$last" ] && [ "$last" != "null" ]; then epoch="$(_iso_to_epoch "$last" || true)"; fi
  if [ -z "$epoch" ]; then
    minutes=1440
  else
    minutes=$(( ( now - epoch ) / 60 ))
    [ "$minutes" -lt 1 ] && minutes=1
    [ "$minutes" -gt 2880 ] && minutes=2880
  fi
  since="$(date -u -d "@$(( now - minutes * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
  echo "MONITOR_SINCE_MINUTES=$minutes"
  echo "MONITOR_SINCE=$since"
}

# cmd_commit added in Task 2; stub keeps the dispatcher honest under set -u.
cmd_commit() { _die "commit: not yet implemented"; }

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    window) cmd_window "$@" ;;
    commit) cmd_commit "$@" ;;
    *) _die "usage: monitor-dedup.sh {window|commit} ..." ;;
  esac
}
main "$@"
