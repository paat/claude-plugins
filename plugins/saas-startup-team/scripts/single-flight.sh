#!/usr/bin/env bash
#
# single-flight.sh - lease/heartbeat helper for autonomous SaaS work units.
#
# Usage:
#   single-flight.sh --acquire KEY [--state-dir DIR] [--owner ID] [--ttl-seconds N] [--replace-stale --reason TEXT]
#   single-flight.sh --heartbeat KEY [--state-dir DIR] [--owner ID]
#   single-flight.sh --release KEY [--state-dir DIR] [--owner ID]
#   single-flight.sh --status KEY [--state-dir DIR] [--json]

set -uo pipefail

ACTION=""; KEY=""; STATE_DIR="${SAAS_SINGLE_FLIGHT_DIR:-.startup/leases}"
OWNER="${SAAS_SINGLE_FLIGHT_OWNER:-$$}"; TTL="${SAAS_SINGLE_FLIGHT_TTL:-900}"
REPLACE_STALE=0; REASON=""; JSON=0

_need_val() { [ "$1" -ge 2 ] || { echo "single-flight: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --acquire) _need_val "$#" "$1"; ACTION="acquire"; KEY="$2"; shift 2 ;;
    --heartbeat) _need_val "$#" "$1"; ACTION="heartbeat"; KEY="$2"; shift 2 ;;
    --release) _need_val "$#" "$1"; ACTION="release"; KEY="$2"; shift 2 ;;
    --status) _need_val "$#" "$1"; ACTION="status"; KEY="$2"; shift 2 ;;
    --state-dir) _need_val "$#" "$1"; STATE_DIR="$2"; shift 2 ;;
    --owner) _need_val "$#" "$1"; OWNER="$2"; shift 2 ;;
    --ttl-seconds) _need_val "$#" "$1"; TTL="$2"; shift 2 ;;
    --replace-stale) REPLACE_STALE=1; shift ;;
    --reason) _need_val "$#" "$1"; REASON="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) echo "single-flight: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ACTION" ] || { echo "single-flight: action required" >&2; exit 2; }
[ -n "$KEY" ] || { echo "single-flight: key required" >&2; exit 2; }
case "$TTL" in ''|*[!0-9]*) echo "single-flight: --ttl-seconds must be numeric" >&2; exit 2 ;; esac

slug="$(printf '%s' "$KEY" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-')"
[ -n "$slug" ] || slug="lease"
LEASE="$STATE_DIR/$slug"
now="$(date +%s)"

mkdir -p "$STATE_DIR" || { echo "single-flight: cannot create $STATE_DIR" >&2; exit 1; }

read_heartbeat() {
  cat "$LEASE/heartbeat" 2>/dev/null || echo 0
}

read_owner() {
  cat "$LEASE/owner" 2>/dev/null || echo unknown
}

is_fresh() {
  hb="$(read_heartbeat)"
  case "$hb" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - hb)) -le "$TTL" ]
}

emit_status() {
  state="missing"; owner=""; heartbeat=0; age=""
  if [ -d "$LEASE" ]; then
    owner="$(read_owner)"; heartbeat="$(read_heartbeat)"
    case "$heartbeat" in ''|*[!0-9]*) age="" ;; *) age=$((now - heartbeat)) ;; esac
    if is_fresh; then state="active"; else state="stale"; fi
  fi
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg key "$KEY" --arg state "$state" --arg owner "$owner" \
      --argjson heartbeat "${heartbeat:-0}" --arg age "${age:-}" \
      '{key:$key,state:$state,owner:$owner,heartbeat:$heartbeat,age_seconds:($age|tonumber?)}'
  else
    echo "single-flight: $KEY is $state${owner:+ (owner=$owner)}"
  fi
}

case "$ACTION" in
  acquire)
    if mkdir "$LEASE" 2>/dev/null; then
      printf '%s\n' "$OWNER" > "$LEASE/owner"
      printf '%s\n' "$now" > "$LEASE/heartbeat"
      printf '%s\n' "$KEY" > "$LEASE/key"
      printf '%s acquired by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OWNER" >> "$LEASE/audit.log"
      echo "single-flight: acquired $KEY"
      exit 0
    fi
    if is_fresh; then
      echo "single-flight: active owner exists for $KEY: $(read_owner)" >&2
      exit 1
    fi
    if [ "$REPLACE_STALE" -ne 1 ]; then
      echo "single-flight: stale owner exists for $KEY: $(read_owner); require --replace-stale --reason" >&2
      exit 2
    fi
    [ -n "$REASON" ] || { echo "single-flight: stale replacement requires --reason" >&2; exit 2; }
    old_owner="$(read_owner)"
    rm -rf "$LEASE" || { echo "single-flight: cannot clear stale lease" >&2; exit 1; }
    mkdir "$LEASE" || { echo "single-flight: cannot replace stale lease" >&2; exit 1; }
    printf '%s\n' "$OWNER" > "$LEASE/owner"
    printf '%s\n' "$now" > "$LEASE/heartbeat"
    printf '%s\n' "$KEY" > "$LEASE/key"
    printf '%s replaced stale owner=%s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$old_owner" "$REASON" >> "$LEASE/audit.log"
    echo "single-flight: replaced stale lease for $KEY"
    exit 0
    ;;

  heartbeat)
    [ -d "$LEASE" ] || { echo "single-flight: no lease for $KEY" >&2; exit 1; }
    lease_owner="$(read_owner)"
    [ "$lease_owner" = "$OWNER" ] || { echo "single-flight: owner mismatch for $KEY: $lease_owner" >&2; exit 1; }
    printf '%s\n' "$now" > "$LEASE/heartbeat"
    printf '%s heartbeat by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OWNER" >> "$LEASE/audit.log"
    echo "single-flight: heartbeat $KEY"
    exit 0
    ;;

  release)
    [ -d "$LEASE" ] || { echo "single-flight: no lease for $KEY"; exit 0; }
    lease_owner="$(read_owner)"
    [ "$lease_owner" = "$OWNER" ] || { echo "single-flight: owner mismatch for $KEY: $lease_owner" >&2; exit 1; }
    printf '%s released by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OWNER" >> "$LEASE/audit.log"
    rm -rf "$LEASE"
    echo "single-flight: released $KEY"
    exit 0
    ;;

  status)
    emit_status
    exit 0
    ;;

  *)
    echo "single-flight: unknown action: $ACTION" >&2; exit 2 ;;
esac
