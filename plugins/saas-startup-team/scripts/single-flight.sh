#!/usr/bin/env bash
#
# single-flight.sh - lease/heartbeat helper for autonomous SaaS work units.
#
# Usage:
#   single-flight.sh --acquire KEY [--state-dir DIR] [--owner ID|--owner-file FILE] [--ttl-seconds N] [--replace-stale --reason TEXT]
#   single-flight.sh --heartbeat KEY [--state-dir DIR] (--owner ID|--owner-file FILE)
#   single-flight.sh --release KEY [--state-dir DIR] (--owner ID|--owner-file FILE)
#   single-flight.sh --status KEY [--state-dir DIR] [--json]

set -euo pipefail

ACTION=""; KEY=""; STATE_DIR="${SAAS_SINGLE_FLIGHT_DIR:-.startup/leases}"
OWNER="${SAAS_SINGLE_FLIGHT_OWNER:-}"; OWNER_FILE=""; OWNER_KEY_FILE=""
OWNER_FILE_CREATED=0; OWNER_FILE_LOADED=0
TTL="${SAAS_SINGLE_FLIGHT_TTL:-900}"
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
    --owner-file) _need_val "$#" "$1"; OWNER_FILE="$2"; shift 2 ;;
    --ttl-seconds) _need_val "$#" "$1"; TTL="$2"; shift 2 ;;
    --replace-stale) REPLACE_STALE=1; shift ;;
    --reason) _need_val "$#" "$1"; REASON="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) echo "single-flight: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ACTION" ] || { echo "single-flight: action required" >&2; exit 2; }
[ -n "$KEY" ] || { echo "single-flight: key required" >&2; exit 2; }
[ -z "$OWNER" ] || [ -z "$OWNER_FILE" ] || { echo "single-flight: use --owner or --owner-file, not both" >&2; exit 2; }
case "$TTL" in ''|*[!0-9]*) echo "single-flight: --ttl-seconds must be numeric" >&2; exit 2 ;; esac

slug="$(printf '%s' "$KEY" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-')"
[ -n "$slug" ] || slug="lease"
LEASE="$STATE_DIR/$slug"
now="$(date +%s)"

mkdir -p "$STATE_DIR" || { echo "single-flight: cannot create $STATE_DIR" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "single-flight: flock is required" >&2; exit 2; }
exec 9>"$STATE_DIR/.single-flight-$slug.lock"
flock -x 9

write_owner_identity() {
  local token="$1" old_umask owner_tmp key_tmp
  old_umask="$(umask)"; umask 077
  owner_tmp="${OWNER_FILE}.tmp.$$"; key_tmp="${OWNER_KEY_FILE}.tmp.$$"
  printf '%s\n' "$token" > "$owner_tmp"
  printf '%s\n' "$KEY" > "$key_tmp"
  mv "$owner_tmp" "$OWNER_FILE"
  mv "$key_tmp" "$OWNER_KEY_FILE"
  umask "$old_umask"
}

if [ -n "$OWNER_FILE" ]; then
  mkdir -p "$(dirname "$OWNER_FILE")" || { echo "single-flight: cannot create owner-file directory" >&2; exit 1; }
  OWNER_KEY_FILE="${OWNER_FILE}.key"
  owner_lock_id="$(printf '%s' "$(realpath -m -- "$OWNER_FILE")" | cksum | awk '{print $1}')"
  exec 8>"$STATE_DIR/.single-flight-owner-$owner_lock_id.lock"
  flock -x 8
fi

# Owner-token creation and lease inspection share key and owner-file locks.
if [ "$ACTION" != "status" ] && [ -n "$OWNER_FILE" ]; then
  if [ -s "$OWNER_FILE" ]; then
    OWNER="$(sed -n '1p' "$OWNER_FILE")"
    if [ -s "$OWNER_KEY_FILE" ]; then
      stored_key="$(sed -n '1p' "$OWNER_KEY_FILE")"
      [ "$stored_key" = "$KEY" ] || {
        echo "single-flight: owner file is bound to another key: $stored_key" >&2; exit 2; }
    elif [ -d "$LEASE" ] && [ "$(cat "$LEASE/owner" 2>/dev/null || true)" = "$OWNER" ]; then
      # Adopt a pre-metadata owner file only when its existing lease proves identity.
      printf '%s\n' "$KEY" > "$OWNER_KEY_FILE"
    else
      echo "single-flight: legacy owner file cannot be safely bound to $KEY" >&2
      exit 2
    fi
    OWNER_FILE_LOADED=1
  elif [ "$ACTION" = "acquire" ]; then
    OWNER="run-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
    write_owner_identity "$OWNER"
    OWNER_FILE_CREATED=1
  elif [ "$ACTION" = "release" ]; then
    # Idempotent handled cleanup: the lease may already be gone with its owner file.
    OWNER="__missing_owner_file__"
  else
    echo "single-flight: owner file missing or empty: $OWNER_FILE" >&2
    exit 2
  fi
fi
if [ "$ACTION" != "status" ] && [ -z "$OWNER" ]; then
  if [ "$ACTION" = "acquire" ]; then
    OWNER="run-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  else
    echo "single-flight: heartbeat/release requires --owner or --owner-file" >&2
    exit 2
  fi
fi

remove_created_owner() {
  local current=""
  [ "$OWNER_FILE_CREATED" -eq 1 ] || return 0
  [ -f "$OWNER_FILE" ] && current="$(sed -n '1p' "$OWNER_FILE")"
  [ "$current" != "$OWNER" ] || rm -f "$OWNER_FILE" "$OWNER_KEY_FILE"
}

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
      '{key:$key,state:$state,owner:$owner,heartbeat:$heartbeat,
        age_seconds:(if $age=="" then null else ($age|tonumber) end)}'
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
      remove_created_owner
      echo "single-flight: active owner exists for $KEY: $(read_owner)" >&2
      exit 1
    fi
    if [ "$REPLACE_STALE" -ne 1 ]; then
      remove_created_owner
      echo "single-flight: stale owner exists for $KEY: $(read_owner); require --replace-stale --reason" >&2
      exit 2
    fi
    [ -n "$REASON" ] || {
      remove_created_owner
      echo "single-flight: stale replacement requires --reason" >&2; exit 2; }
    old_owner="$(read_owner)"
    if [ "$OWNER_FILE_LOADED" -eq 1 ]; then
      OWNER="run-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
      write_owner_identity "$OWNER"
    fi
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
    [ -d "$LEASE" ] || {
      [ -z "$OWNER_FILE" ] || rm -f "$OWNER_FILE" "$OWNER_KEY_FILE"
      echo "single-flight: no lease for $KEY"; exit 0; }
    lease_owner="$(read_owner)"
    [ "$lease_owner" = "$OWNER" ] || { echo "single-flight: owner mismatch for $KEY: $lease_owner" >&2; exit 1; }
    printf '%s released by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OWNER" >> "$LEASE/audit.log"
    rm -rf "$LEASE"
    [ -z "$OWNER_FILE" ] || rm -f "$OWNER_FILE" "$OWNER_KEY_FILE"
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
