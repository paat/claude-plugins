#!/usr/bin/env bash
# Persist lease heartbeats across one-shot tool shells.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SINGLE_FLIGHT="$SCRIPT_DIR/single-flight.sh"

usage() {
  echo "usage: lease-guardian.sh start --state-dir DIR --pid-file FILE --failure-file FILE [--interval-seconds N] [--max-seconds N] --lease KEY OWNER_FILE..." >&2
  echo "       lease-guardian.sh check|stop --pid-file FILE --failure-file FILE" >&2
  exit 2
}

valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

process_matches() {
  local pid="$1" token="$2"
  kill -0 "$pid" 2>/dev/null || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fqx -- "$token"
}

read_state() {
  local pid_file="$1"
  [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
  jq -e '.schema_version == 1 and (.pid|type == "number") and .pid > 1 and
    (.token|type == "string") and (.token|test("^[0-9a-f]{32}$"))' "$pid_file" >/dev/null
}

run_guardian() {
  local state_dir="" failure_file="" token="" interval=60 max_seconds=14400 started now key owner
  local -a keys=() owners=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-dir) [ "$#" -ge 2 ] || usage; state_dir="$2"; shift 2 ;;
      --failure-file) [ "$#" -ge 2 ] || usage; failure_file="$2"; shift 2 ;;
      --token) [ "$#" -ge 2 ] || usage; token="$2"; shift 2 ;;
      --interval-seconds) [ "$#" -ge 2 ] || usage; interval="$2"; shift 2 ;;
      --max-seconds) [ "$#" -ge 2 ] || usage; max_seconds="$2"; shift 2 ;;
      --lease) [ "$#" -ge 3 ] || usage; keys+=("$2"); owners+=("$3"); shift 3 ;;
      *) usage ;;
    esac
  done
  [ -n "$state_dir" ] && [ -n "$failure_file" ] && [[ "$token" =~ ^[0-9a-f]{32}$ ]] \
    && valid_uint "$interval" && valid_uint "$max_seconds" && [ "${#keys[@]}" -gt 0 ] || usage
  trap 'exit 0' TERM INT
  started=$(date +%s)
  while :; do
    now=$(date +%s)
    if [ "$((now - started))" -ge "$max_seconds" ]; then
      printf '%s\n' 'guardian lifetime exceeded' > "$failure_file"
      exit 1
    fi
    for ((i = 0; i < ${#keys[@]}; i++)); do
      key=${keys[$i]}; owner=${owners[$i]}
      if ! bash "$SINGLE_FLIGHT" --heartbeat "$key" --state-dir "$state_dir" \
        --owner-file "$owner" >/dev/null; then
        printf '%s\n' 'lease heartbeat failed' > "$failure_file"
        exit 1
      fi
    done
    sleep "$interval" & wait $!
  done
}

start_guardian() {
  local state_dir="" pid_file="" failure_file="" interval=60 max_seconds=14400 token pid old_umask
  local -a lease_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-dir) [ "$#" -ge 2 ] || usage; state_dir="$2"; shift 2 ;;
      --pid-file) [ "$#" -ge 2 ] || usage; pid_file="$2"; shift 2 ;;
      --failure-file) [ "$#" -ge 2 ] || usage; failure_file="$2"; shift 2 ;;
      --interval-seconds) [ "$#" -ge 2 ] || usage; interval="$2"; shift 2 ;;
      --max-seconds) [ "$#" -ge 2 ] || usage; max_seconds="$2"; shift 2 ;;
      --lease) [ "$#" -ge 3 ] || usage; lease_args+=(--lease "$2" "$3"); shift 3 ;;
      *) usage ;;
    esac
  done
  [ -d "$state_dir" ] && [ -n "$pid_file" ] && [ -n "$failure_file" ] \
    && valid_uint "$interval" && valid_uint "$max_seconds" && [ "${#lease_args[@]}" -gt 0 ] || usage
  [ ! -L "$pid_file" ] && [ ! -L "$failure_file" ] || {
    echo "lease-guardian: state paths must not be symlinks" >&2; exit 2; }
  if read_state "$pid_file"; then
    pid=$(jq -r .pid "$pid_file"); token=$(jq -r .token "$pid_file")
    process_matches "$pid" "$token" && { echo "lease-guardian: guardian already active" >&2; exit 1; }
  fi
  mkdir -p "$(dirname -- "$pid_file")" "$(dirname -- "$failure_file")"
  rm -f -- "$pid_file" "$failure_file"
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || { echo "lease-guardian: random token failed" >&2; exit 1; }
  nohup "$0" __run --state-dir "$state_dir" --failure-file "$failure_file" --token "$token" \
    --interval-seconds "$interval" --max-seconds "$max_seconds" "${lease_args[@]}" \
    </dev/null >/dev/null 2>&1 &
  pid=$!
  old_umask=$(umask); umask 077
  jq -n --argjson pid "$pid" --arg token "$token" \
    '{schema_version:1,pid:$pid,token:$token}' > "$pid_file"
  umask "$old_umask"
  sleep 0.1
  process_matches "$pid" "$token" || {
    echo "lease-guardian: guardian failed to start" >&2; exit 1; }
  printf '%s\n' "$pid_file"
}

check_guardian() {
  local pid_file="$1" failure_file="$2" pid token
  [ ! -e "$failure_file" ] || { echo "lease-guardian: heartbeat failure recorded" >&2; exit 1; }
  read_state "$pid_file" || { echo "lease-guardian: invalid guardian state" >&2; exit 1; }
  pid=$(jq -r .pid "$pid_file"); token=$(jq -r .token "$pid_file")
  process_matches "$pid" "$token" || { echo "lease-guardian: guardian is not active" >&2; exit 1; }
}

stop_guardian() {
  local pid_file="$1" pid token n
  [ -e "$pid_file" ] || return 0
  read_state "$pid_file" || { echo "lease-guardian: invalid guardian state" >&2; exit 1; }
  pid=$(jq -r .pid "$pid_file"); token=$(jq -r .token "$pid_file")
  if process_matches "$pid" "$token"; then
    kill "$pid" 2>/dev/null || true
    for ((n = 0; n < 50; n++)); do
      process_matches "$pid" "$token" || break
      sleep 0.1
    done
    process_matches "$pid" "$token" && { echo "lease-guardian: guardian did not stop" >&2; exit 1; }
  fi
  rm -f -- "$pid_file"
}

case "${1:-}" in
  __run) shift; run_guardian "$@" ;;
  start) shift; start_guardian "$@" ;;
  check|stop)
    action=$1; shift; pid_file=""; failure_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pid-file) [ "$#" -ge 2 ] || usage; pid_file=$2; shift 2 ;;
        --failure-file) [ "$#" -ge 2 ] || usage; failure_file=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$pid_file" ] && [ -n "$failure_file" ] || usage
    if [ "$action" = check ]; then check_guardian "$pid_file" "$failure_file"
    else stop_guardian "$pid_file"; fi
    ;;
  *) usage ;;
esac
