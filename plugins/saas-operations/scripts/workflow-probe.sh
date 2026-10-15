#!/usr/bin/env bash
# Model-free readiness probe for the host-scheduled nightly monitor.
# Exit 0: work available; 3: clean no-op; 1/2: failure/usage.
set -euo pipefail

die() { echo "workflow-probe: $1" >&2; exit "${2:-1}"; }
usage() { echo "usage: workflow-probe.sh monitor-nightly [--root DIR] [--dry-run]" >&2; }
MODE="${1:-}"; [ "$#" -gt 0 ] && shift || true
[ "$MODE" = monitor-nightly ] || { usage; exit 2; }
ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || { usage; exit 2; }; ROOT="$2"; shift 2 ;;
    --dry-run) shift ;;
    *) usage; exit 2 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "${ROOT:-.}" rev-parse --show-toplevel)" || die "cannot resolve repository root"
ROOT="$(cd "$ROOT" && pwd -P)"
noop() { echo "workflow-probe: monitor-nightly no work to do"; exit 3; }
ready() { echo "workflow-probe: monitor-nightly work available"; exit 0; }

config="$ROOT/.claude/saas-operations.local.md"
[ -f "$config" ] || config="$ROOT/.claude/saas-startup-team.local.md"
marker_dir="$ROOT/.monitor"; custom_checks="$ROOT/.startup/monitor-checks.sh"
state_file="$ROOT/.startup/monitor-state.json"
# Same resolution as the monitor-nightly skill's cfg(): unquoted values lose a ` # comment`, then trim and unquote.
monitor_value() {
  printf '%s\n' "$block" | sed -nE "s/^[[:space:]]+$1:[[:space:]]*(.*)\$/\\1/p" | head -1 \
    | sed -E '/["'"'"']/!s/[[:space:]]+#.*$//; s/^#.*$//; s/[[:space:]]+$//; s/^['"'"'"]//; s/['"'"'"]$//'
}
if [ -f "$config" ] && grep -q '^[[:space:]]*monitor:[[:space:]]*$' "$config"; then
  block="$(sed -n '/^[[:space:]]*monitor:[[:space:]]*$/,/^[^[:space:]#]/p' "$config")"
  value="$(monitor_value marker_dir)"
  if [ -n "$value" ]; then case "$value" in /*) marker_dir="$value" ;; *) marker_dir="$ROOT/${value#./}" ;; esac; fi
  value="$(monitor_value custom_checks)"
  if [ -n "$value" ]; then case "$value" in /*) custom_checks="$value" ;; *) custom_checks="$ROOT/${value#./}" ;; esac; fi
  value="$(monitor_value state_file)"
  if [ -n "$value" ]; then case "$value" in /*) state_file="$value" ;; *) state_file="$ROOT/${value#./}" ;; esac; fi
fi
probe_cache="${state_file}.probe-findings"
if [ -s "$probe_cache" ] && find "$probe_cache" -mmin -60 -print -quit | grep -q .; then ready; fi
rm -f "$probe_cache"
marker_found=0
if [ -d "$marker_dir" ] && find "$marker_dir" -maxdepth 1 -type f -name '*-last-failure.txt' -print -quit | grep -q .; then marker_found=1; fi
if [ -x "$custom_checks" ]; then
  window="$("$SCRIPT_DIR/monitor-dedup.sh" window --state "$state_file")" || die "cannot resolve monitor window"
  eval "$window"
  export MONITOR_SINCE MONITOR_SINCE_MINUTES
  set +e
  custom_output="$(cd "$ROOT" && "$custom_checks")"; custom_ec=$?
  set -e
  if [ "$custom_ec" -ne 0 ] || [ -n "$(printf '%s' "$custom_output" | tr -d '[:space:]')" ]; then
    mkdir -p "$(dirname "$probe_cache")"
    probe_tmp="${probe_cache}.tmp.$$"
    printf '%s\n' "$custom_output" > "$probe_tmp"
    if [ "$custom_ec" -ne 0 ]; then
      jq -nc --arg b "custom-checks exited $custom_ec" \
        '{pattern_key:"ops:monitor-checks:failure",severity:"high",entity:null,title:"[Monitor] custom-checks script failed",body:$b}' >> "$probe_tmp"
    fi
    mv "$probe_tmp" "$probe_cache"
    ready
  fi
  rm -f "$probe_cache"
else
  rm -f "$probe_cache"
fi
[ "$marker_found" -eq 0 ] || ready
noop
