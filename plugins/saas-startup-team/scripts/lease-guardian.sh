#!/usr/bin/env bash
# Keep leases alive while a foreground child command runs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SINGLE_FLIGHT="$SCRIPT_DIR/single-flight.sh"

usage() {
  echo "usage: lease-guardian.sh probe" >&2
  echo "       lease-guardian.sh hold [--state-dir DIR --lease KEY OWNER_FILE]... [--lease-at DIR KEY OWNER_FILE]... [--interval-seconds N] [--max-seconds N] -- COMMAND..." >&2
  exit 2
}

valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

CONTAINMENT_SETPRIV=""
CONTAINMENT_BASH=""
CONTAINMENT_PYTHON=""
CONTAINMENT_TRACER="$SCRIPT_DIR/trace-containment.py"
probe_containment() {
  CONTAINMENT_SETPRIV=$(command -v setpriv 2>/dev/null || true)
  CONTAINMENT_BASH=$(command -v bash 2>/dev/null || true)
  CONTAINMENT_PYTHON=$(command -v python3 2>/dev/null || true)
  [ -n "$CONTAINMENT_SETPRIV" ] && [ -x "$CONTAINMENT_SETPRIV" ] \
    && [ -n "$CONTAINMENT_BASH" ] && [ -x "$CONTAINMENT_BASH" ] || {
    echo "lease-guardian: util-linux setpriv and bash are required for child containment" >&2
    return 1
  }
  [ -n "$CONTAINMENT_PYTHON" ] && [ -x "$CONTAINMENT_PYTHON" ] \
    && [ -x "$CONTAINMENT_TRACER" ] || {
    echo "lease-guardian: Python 3 and trace-containment.py are required for child containment" >&2
    return 1
  }
  if ! "$CONTAINMENT_SETPRIV" --pdeathsig KILL "$CONTAINMENT_BASH" -c '
    expected_parent=$1
    shift
    [ "$PPID" = "$expected_parent" ] || exit 125
    exec "$@"
  ' lease-parent-check "$$" "$CONTAINMENT_PYTHON" "$CONTAINMENT_TRACER" \
    "$CONTAINMENT_BASH" -c ':'; then
    echo "lease-guardian: Linux ptrace support is required; parent-death signaling is also required for child containment" >&2
    return 1
  fi
}

heartbeat_leases() {
  local lock_timeout="$1" state_dir key owner
  shift
  while [ "$#" -gt 0 ]; do
    state_dir="$1"; key="$2"; owner="$3"; shift 3
    bash "$SINGLE_FLIGHT" --heartbeat "$key" --state-dir "$state_dir" \
      --owner-file "$owner" --lock-timeout-seconds "$lock_timeout" \
      >/dev/null || return 1
  done
}

stop_child_group() {
  local child="$1" group="$2" signal="${3:-TERM}"
  kill -s "$signal" -- "-$group" 2>/dev/null \
    || kill -s "$signal" "$child" 2>/dev/null || true
}

hold_command() {
  local state_dir="" interval=60 max_seconds=14400 started now last_heartbeat child="" child_group="" rc=0 monitor=0 i
  local pending_signal="" pending_status=0 heartbeat_rc=0 containment_token="" cleanup_rc=0
  local group_verified=0
  local setpriv_bin="" bash_bin="" python_bin="" tracer_bin="" PROC_STATE="" PROC_PPID="" PROC_PGRP="" PROC_START=""
  local -a lease_pairs=() lease_triples=() command=()
  local -A tracked_start=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-dir) [ "$#" -ge 2 ] || usage; state_dir="$2"; shift 2 ;;
      --interval-seconds) [ "$#" -ge 2 ] || usage; interval="$2"; shift 2 ;;
      --max-seconds) [ "$#" -ge 2 ] || usage; max_seconds="$2"; shift 2 ;;
      --lease) [ "$#" -ge 3 ] || usage; lease_pairs+=("$2" "$3"); shift 3 ;;
      --lease-at) [ "$#" -ge 4 ] || usage; lease_triples+=("$2" "$3" "$4"); shift 4 ;;
      --) shift; command=("$@"); break ;;
      *) usage ;;
    esac
  done
  valid_uint "$interval" && valid_uint "$max_seconds" \
    && [ $((${#lease_pairs[@]} + ${#lease_triples[@]})) -gt 0 ] \
    && [ "${#command[@]}" -gt 0 ] || usage
  [ "$interval" -le 60 ] || {
    echo "lease-guardian: heartbeat interval must be at most 60 seconds" >&2
    return 2
  }
  [ $((${#lease_pairs[@]} % 2)) -eq 0 ] || usage
  [ $((${#lease_triples[@]} % 3)) -eq 0 ] || usage
  if [ "${#lease_pairs[@]}" -gt 0 ]; then
    [ -d "$state_dir" ] || usage
    while [ "${#lease_pairs[@]}" -gt 0 ]; do
      lease_triples+=("$state_dir" "${lease_pairs[0]}" "${lease_pairs[1]}")
      lease_pairs=("${lease_pairs[@]:2}")
    done
  fi
  for ((i=0; i<${#lease_triples[@]}; i+=3)); do
    [ -d "${lease_triples[$i]}" ] || usage
  done

  read_proc_identity() {
    local pid="$1" line rest
    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r line 2>/dev/null < "/proc/$pid/stat" || return 1
    rest=${line##*) }
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    PROC_STATE=$1; PROC_PPID=$2; PROC_PGRP=$3; PROC_START=${20}
    [[ "$PROC_PPID$PROC_PGRP$PROC_START" =~ ^[0-9]+[0-9]+[0-9]+$ ]] || return 1
  }

  process_has_token() {
    local pid="$1" entry
    read_proc_identity "$pid" && [ "$PROC_STATE" != Z ] || return 1
    [ -r "/proc/$pid/environ" ] || return 1
    while IFS= read -r -d '' entry; do
      [ "$entry" != "SAAS_LEASE_GUARDIAN_TOKEN=$containment_token" ] || return 0
    done < "/proc/$pid/environ" 2>/dev/null
    return 1
  }

  track_descendants() {
    local path pid changed=1 candidate_ppid candidate_start parent_start
    [ -n "$child" ] || return 0
    if read_proc_identity "$child"; then tracked_start[$child]=$PROC_START; fi
    while [ "$changed" -eq 1 ]; do
      changed=0
      for path in /proc/[0-9]*; do
        pid=${path##*/}
        [ "$pid" != "$$" ] || continue
        read_proc_identity "$pid" || continue
        candidate_ppid=$PROC_PPID; candidate_start=$PROC_START
        parent_start=${tracked_start[$candidate_ppid]:-}
        if [ "$pid" = "$child" ] \
          || { [ -n "$parent_start" ] && read_proc_identity "$candidate_ppid" \
            && [ "$PROC_START" = "$parent_start" ]; }; then
          if [ -z "${tracked_start[$pid]+x}" ]; then
            tracked_start[$pid]=$candidate_start
            changed=1
          fi
        fi
      done
    done
  }

  signal_tracked() {
    local signal="$1" pid
    for pid in "${!tracked_start[@]}"; do
      if read_proc_identity "$pid" \
        && [ "$PROC_START" = "${tracked_start[$pid]}" ] \
        && [ "$PROC_STATE" != Z ]; then
        kill -s "$signal" "$pid" 2>/dev/null || true
      fi
    done
  }

  signal_tagged() {
    local signal="$1" path pid
    for path in /proc/[0-9]*; do
      pid=${path##*/}
      [ "$pid" != "$$" ] || continue
      process_has_token "$pid" || continue
      kill -s "$signal" "$pid" 2>/dev/null || true
    done
  }

  group_alive() {
    local path pid
    [ "$group_verified" -eq 1 ] && [ -n "$child_group" ] || return 1
    for path in /proc/[0-9]*; do
      pid=${path##*/}
      read_proc_identity "$pid" || continue
      [ "$PROC_STATE" = Z ] && continue
      [ "$PROC_PGRP" != "$child_group" ] || return 0
    done
    return 1
  }

  managed_alive() {
    local path pid
    group_alive && return 0
    for pid in "${!tracked_start[@]}"; do
      if read_proc_identity "$pid" \
        && [ "$PROC_START" = "${tracked_start[$pid]}" ] \
        && [ "$PROC_STATE" != Z ]; then return 0; fi
    done
    for path in /proc/[0-9]*; do
      pid=${path##*/}
      [ "$pid" != "$$" ] || continue
      process_has_token "$pid" && return 0
    done
    return 1
  }

  stop_managed() {
    local signal="${1:-TERM}" n
    track_descendants
    if [ "$group_verified" -eq 1 ] && group_alive; then
      stop_child_group "$child" "$child_group" "$signal"
    else
      kill -s "$signal" "$child" 2>/dev/null || true
    fi
    signal_tracked "$signal"
    signal_tagged "$signal"
    for ((n=0; n<5; n++)); do
      track_descendants
      managed_alive || return 0
      sleep 1
    done
    if [ "$group_verified" -eq 1 ] && group_alive; then
      stop_child_group "$child" "$child_group" KILL
    else
      kill -KILL "$child" 2>/dev/null || true
    fi
    signal_tracked KILL
    signal_tagged KILL
    for ((n=0; n<20; n++)); do
      managed_alive || return 0
      sleep 0.05
    done
    echo "lease-guardian: child containment could not be drained" >&2
    return 1
  }

  verify_child_containment() {
    local n
    for ((n=0; n<50; n++)); do
      kill -0 "$child" 2>/dev/null || return 0
      if process_has_token "$child" && [ "$PROC_PGRP" = "$child_group" ]; then
        group_verified=1
        track_descendants
        return 0
      fi
      sleep 0.02
    done
    return 1
  }

  [ -d /proc ] && read_proc_identity "$$" && [ -r "/proc/$$/environ" ] || {
    echo "lease-guardian: inspectable Linux /proc is required for child containment" >&2
    return 1
  }

  forward_signal() {
    local signal="$1" status="$2"
    trap - INT TERM HUP
    [ -z "$child" ] || stop_managed "$signal" || true
    [ -z "$child" ] || wait "$child" 2>/dev/null || true
    exit "$status"
  }
  receive_signal() {
    pending_signal="$1"; pending_status="$2"
    [ -z "$child" ] || forward_signal "$pending_signal" "$pending_status"
  }
  trap 'receive_signal INT 130' INT
  trap 'receive_signal TERM 143' TERM
  trap 'receive_signal HUP 129' HUP

  heartbeat_leases 1 "${lease_triples[@]}" || heartbeat_rc=$?
  if [ -n "$pending_signal" ]; then
    trap - INT TERM HUP
    return "$pending_status"
  fi
  [ "$heartbeat_rc" -eq 0 ] || {
    echo "lease-guardian: initial lease heartbeat failed" >&2
    trap - INT TERM HUP
    return 1
  }

  case $- in *m*) monitor=1 ;; esac

  # Nested hold under an outer guardian cannot re-ptrace (PTRACE_TRACEME → EPERM
  # while already traced). Outer containment already covers descendants; only
  # heartbeat leases while running the command. Live-proof under maintain hold
  # hits this path (aruannik #1273 post-merge).
  if [ -n "${SAAS_LEASE_GUARDIAN_TOKEN:-}" ]; then
    echo "lease-guardian: nested hold under existing containment; ptrace skipped" >&2
    set -m
    "${command[@]}" &
    child=$!
    child_group=$child
    group_verified=1
    [ "$monitor" -eq 1 ] || set +m
    [ -z "$pending_signal" ] || forward_signal "$pending_signal" "$pending_status"
    track_descendants
  else
  containment_token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ "$containment_token" =~ ^[0-9a-f]{32}$ ]] || {
    echo "lease-guardian: cannot create child containment identity" >&2; return 1; }
  probe_containment || return 1
  setpriv_bin=$CONTAINMENT_SETPRIV
  bash_bin=$CONTAINMENT_BASH
  python_bin=$CONTAINMENT_PYTHON
  tracer_bin=$CONTAINMENT_TRACER

  # setpriv makes guardian death kill the ptrace supervisor. The immediate
  # PPID check closes the fork-before-prctl race: an already-orphaned child
  # exits before it can start the command. PTRACE_O_EXITKILL then makes tracer
  # death kill every descendant, including processes that detached or reparented.
  set -m
  SAAS_LEASE_GUARDIAN_TOKEN="$containment_token" \
    "$setpriv_bin" --pdeathsig KILL "$bash_bin" -c '
      expected_parent=$1
      shift
      [ "$PPID" = "$expected_parent" ] || exit 125
      exec "$@"
    ' lease-parent-check "$$" \
    "$python_bin" "$tracer_bin" "${command[@]}" &
  child=$!
  child_group=$child
  [ "$monitor" -eq 1 ] || set +m
  [ -z "$pending_signal" ] || forward_signal "$pending_signal" "$pending_status"
  if ! verify_child_containment; then
    echo "lease-guardian: child containment identity is not inspectable" >&2
    stop_managed TERM || true
    wait "$child" 2>/dev/null || true
    trap - INT TERM HUP
    return 1
  fi
  fi

  started=$SECONDS
  last_heartbeat=$started
  while kill -0 "$child" 2>/dev/null; do
    track_descendants
    now=$SECONDS
    if [ "$((now - started))" -ge "$max_seconds" ]; then
      echo "lease-guardian: command lifetime exceeded" >&2
      stop_managed TERM || cleanup_rc=$?
      wait "$child" 2>/dev/null || true
      trap - INT TERM HUP
      [ "$cleanup_rc" -eq 0 ] || return 1
      return 1
    fi
    if [ "$((now - last_heartbeat))" -ge "$interval" ]; then
      if ! heartbeat_leases 1 "${lease_triples[@]}"; then
        echo "lease-guardian: lease heartbeat failed; terminating child" >&2
        stop_managed TERM || cleanup_rc=$?
        wait "$child" 2>/dev/null || true
        trap - INT TERM HUP
        [ "$cleanup_rc" -eq 0 ] || return 1
        return 1
      fi
      last_heartbeat=$SECONDS
    fi
    sleep 1
  done
  wait "$child" || rc=$?
  stop_managed TERM || cleanup_rc=$?
  trap - INT TERM HUP
  [ "$cleanup_rc" -eq 0 ] || return 1
  return "$rc"
}

case "${1:-}" in
  probe) [ "$#" -eq 1 ] || usage; probe_containment ;;
  hold) shift; hold_command "$@" ;;
  *) usage ;;
esac
