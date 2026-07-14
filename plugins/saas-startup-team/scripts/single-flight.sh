#!/usr/bin/env bash
#
# single-flight.sh - lease/heartbeat helper for autonomous SaaS work units.
#
# Usage:
#   single-flight.sh --acquire KEY [--state-dir DIR] [--owner ID|--owner-file FILE] [--ttl-seconds N] [--lock-timeout-seconds N] [--replace-stale --reason TEXT]
#   single-flight.sh --heartbeat KEY [--state-dir DIR] (--owner ID|--owner-file FILE)
#   single-flight.sh --release KEY [--state-dir DIR] (--owner ID|--owner-file FILE)
#   single-flight.sh --status KEY [--state-dir DIR] [--json]

set -euo pipefail

ACTION=""; KEY=""; STATE_DIR="${SAAS_SINGLE_FLIGHT_DIR:-.startup/leases}"
OWNER="${SAAS_SINGLE_FLIGHT_OWNER:-}"; OWNER_FILE=""; OWNER_KEY_FILE=""
OWNER_FILE_CREATED=0; OWNER_FILE_LOADED=0
TTL="${SAAS_SINGLE_FLIGHT_TTL:-900}"
LOCK_TIMEOUT="${SAAS_SINGLE_FLIGHT_LOCK_TIMEOUT:-10}"
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
    --lock-timeout-seconds) _need_val "$#" "$1"; LOCK_TIMEOUT="$2"; shift 2 ;;
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
case "$LOCK_TIMEOUT" in ''|*[!0-9]*) echo "single-flight: --lock-timeout-seconds must be numeric" >&2; exit 2 ;; esac

mkdir -p -- "$STATE_DIR" || { echo "single-flight: cannot create $STATE_DIR" >&2; exit 1; }
[ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || {
  echo "single-flight: unsafe state directory: $STATE_DIR" >&2; exit 1; }
STATE_DIR="$(cd -- "$STATE_DIR" && pwd -P)" || exit 1
slug="$(printf '%s' "$KEY" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-')"
[ -n "$slug" ] || slug="lease"
LEASE="$STATE_DIR/$slug"

safe_regular_or_absent() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ]
  fi
}

prepare_legacy_lock() {
  local path="$1" tmp
  if [ -L "$path" ]; then
    rm -- "$path" || return 1
  fi
  if [ ! -e "$path" ]; then
    tmp=$(mktemp "$STATE_DIR/.single-flight-lock.tmp.XXXXXX") || return 1
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    if ! ln "$tmp" "$path" 2>/dev/null \
      && ! { [ -f "$path" ] && [ ! -L "$path" ]; }; then
      rm -f -- "$tmp"
      return 1
    fi
    rm -f -- "$tmp"
  fi
  [ -f "$path" ] && [ ! -L "$path" ]
}

command -v flock >/dev/null 2>&1 || { echo "single-flight: flock is required" >&2; exit 2; }
exec 9<"$STATE_DIR"
flock -x -w "$LOCK_TIMEOUT" 9 || {
  echo "single-flight: timed out locking state directory for $KEY" >&2; exit 1; }

# Old clients synchronize this key through the predictable per-key file. Keep
# that lock in addition to the directory lock until cross-version operation is
# no longer supported, so a legacy heartbeat cannot race stale replacement.
LEGACY_LOCK="$STATE_DIR/.single-flight-$slug.lock"
prepare_legacy_lock "$LEGACY_LOCK" || {
  echo "single-flight: unsafe legacy lock for $KEY" >&2; exit 1; }
exec 7<"$LEGACY_LOCK"
flock -x -w "$LOCK_TIMEOUT" 7 || {
  echo "single-flight: timed out locking legacy lease for $KEY" >&2; exit 1; }

atomic_write() {
  local target="$1" value="$2" parent base tmp
  parent=$(dirname -- "$target"); base=$(basename -- "$target")
  tmp=$(mktemp "$parent/.$base.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! chmod 600 "$tmp" || ! mv -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

append_audit() {
  local line="$1" audit="$LEASE/audit.log" tmp
  safe_regular_or_absent "$LEASE/audit.log" || {
    echo "single-flight: unsafe audit log for $KEY" >&2; return 1; }
  tmp=$(mktemp "$LEASE/.audit.log.tmp.XXXXXX") || return 1
  if { [ ! -e "$audit" ] || tail -n 255 "$audit"; } > "$tmp" \
    && printf '%s\n' "$line" >> "$tmp" \
    && chmod 600 "$tmp" \
    && mv -- "$tmp" "$audit"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

write_owner_identity() {
  local token="$1"
  # Publish the binding first. A crash can leave a harmless key without an
  # owner, while publishing the owner first could strand an unbound identity.
  atomic_write "$OWNER_KEY_FILE" "$KEY" && atomic_write "$OWNER_FILE" "$token"
}

if [ -n "$OWNER_FILE" ]; then
  owner_parent=$(dirname -- "$OWNER_FILE"); owner_base=$(basename -- "$OWNER_FILE")
  case "$owner_base" in ''|.|..|/) echo "single-flight: invalid owner file" >&2; exit 2 ;; esac
  mkdir -p -- "$owner_parent" || { echo "single-flight: cannot create owner-file directory" >&2; exit 1; }
  [ -d "$owner_parent" ] && [ ! -L "$owner_parent" ] || {
    echo "single-flight: unsafe owner-file directory" >&2; exit 1; }
  owner_parent="$(cd -- "$owner_parent" && pwd -P)" || exit 1
  OWNER_FILE="$owner_parent/$owner_base"
  OWNER_KEY_FILE="${OWNER_FILE}.key"
  safe_regular_or_absent "$OWNER_FILE" && safe_regular_or_absent "$OWNER_KEY_FILE" || {
    echo "single-flight: unsafe owner identity" >&2; exit 1; }
  owner_lock_id="$(printf '%s' "$OWNER_FILE" | cksum | awk '{print $1}')"
  LEGACY_OWNER_LOCK="$STATE_DIR/.single-flight-owner-$owner_lock_id.lock"
  prepare_legacy_lock "$LEGACY_OWNER_LOCK" || {
    echo "single-flight: unsafe legacy owner lock for $KEY" >&2; exit 1; }
  exec 6<"$LEGACY_OWNER_LOCK"
  flock -x -w "$LOCK_TIMEOUT" 6 || {
    echo "single-flight: timed out locking legacy owner identity for $KEY" >&2; exit 1; }
  if [ "$owner_parent" != "$STATE_DIR" ]; then
    exec 8<"$owner_parent"
    flock -x -w "$LOCK_TIMEOUT" 8 || {
      echo "single-flight: timed out locking owner identity for $KEY" >&2; exit 1; }
  fi
fi

now="$(date +%s)"

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
      atomic_write "$OWNER_KEY_FILE" "$KEY"
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

validate_lease() {
  local allow_bad_heartbeat="${1:-0}" stored_key
  [ -d "$LEASE" ] && [ ! -L "$LEASE" ] || {
    echo "single-flight: unsafe lease path for $KEY" >&2; return 1; }
  [ -s "$LEASE/owner" ] && [ -f "$LEASE/owner" ] && [ ! -L "$LEASE/owner" ] \
    && [ -f "$LEASE/heartbeat" ] && [ ! -L "$LEASE/heartbeat" ] \
    && [ -s "$LEASE/key" ] && [ -f "$LEASE/key" ] && [ ! -L "$LEASE/key" ] || {
      echo "single-flight: malformed lease for $KEY" >&2; return 1; }
  safe_regular_or_absent "$LEASE/audit.log" || {
    echo "single-flight: unsafe audit log for $KEY" >&2; return 1; }
  stored_key=$(cat "$LEASE/key") || return 1
  [ "$stored_key" = "$KEY" ] || {
    echo "single-flight: lease slug collision: $KEY conflicts with $stored_key" >&2; return 1; }
  HEARTBEAT_VALUE=$(cat "$LEASE/heartbeat") || return 1
  case "$HEARTBEAT_VALUE" in ''|*[!0-9]*)
    [ "$allow_bad_heartbeat" -eq 1 ] || {
      echo "single-flight: malformed heartbeat for $KEY" >&2; return 1; }
    HEARTBEAT_VALUE=0 ;;
  esac
  if [ "$allow_bad_heartbeat" -ne 1 ]; then
    [ "$HEARTBEAT_VALUE" -le "$now" ] || {
      echo "single-flight: future heartbeat for $KEY; refusing replacement" >&2; return 1; }
  fi
  LEASE_OWNER=$(cat "$LEASE/owner") || return 1
}

is_fresh() {
  [ $((now - HEARTBEAT_VALUE)) -le "$TTL" ]
}

prepare_lease() {
  local audit_line="$1"
  PREPARED_LEASE=$(mktemp -d "$STATE_DIR/.single-flight-$slug.lease.XXXXXX") || return 1
  chmod 700 "$PREPARED_LEASE" || return 1
  atomic_write "$PREPARED_LEASE/owner" "$OWNER" \
    && atomic_write "$PREPARED_LEASE/heartbeat" "$now" \
    && atomic_write "$PREPARED_LEASE/key" "$KEY" \
    && atomic_write "$PREPARED_LEASE/audit.log" "$audit_line"
}

publish_new_lease() {
  local audit_line="$1"
  PREPARED_LEASE=""
  if ! prepare_lease "$audit_line" || ! mv -T -- "$PREPARED_LEASE" "$LEASE"; then
    [ -z "${PREPARED_LEASE:-}" ] || rm -rf -- "$PREPARED_LEASE"
    remove_created_owner
    echo "single-flight: cannot publish lease for $KEY" >&2
    return 1
  fi
  PREPARED_LEASE=""
  OWNER_FILE_CREATED=0
}

emit_status() {
  state="missing"; owner=""; heartbeat=0; age=""
  if [ -e "$LEASE" ] || [ -L "$LEASE" ]; then
    validate_lease || exit 2
    owner="$LEASE_OWNER"; heartbeat="$HEARTBEAT_VALUE"; age=$((now - heartbeat))
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
    if [ ! -e "$LEASE" ] && [ ! -L "$LEASE" ]; then
      publish_new_lease "$(date -u +%Y-%m-%dT%H:%M:%SZ) acquired by $OWNER" || exit 1
      echo "single-flight: acquired $KEY"
      exit 0
    fi
    if ! validate_lease; then
      remove_created_owner
      exit 2
    fi
    if is_fresh; then
      remove_created_owner
      echo "single-flight: active owner exists for $KEY: $LEASE_OWNER" >&2
      exit 1
    fi
    if [ "$REPLACE_STALE" -ne 1 ]; then
      remove_created_owner
      echo "single-flight: stale owner exists for $KEY: $LEASE_OWNER; require --replace-stale --reason" >&2
      exit 2
    fi
    [ -n "$REASON" ] || {
      remove_created_owner
      echo "single-flight: stale replacement requires --reason" >&2; exit 2; }
    old_owner="$LEASE_OWNER"
    if [ "$OWNER_FILE_LOADED" -eq 1 ]; then
      OWNER="run-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
      write_owner_identity "$OWNER"
    fi
    atomic_write "$LEASE/owner" "$OWNER" || { echo "single-flight: cannot replace stale owner" >&2; exit 1; }
    # The fresh heartbeat is the replacement commit point. A crash before it
    # leaves a reclaimable stale lease; audit is written only after it succeeds.
    atomic_write "$LEASE/heartbeat" "$now" || {
      echo "single-flight: cannot publish replacement heartbeat" >&2; exit 1; }
    append_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) replaced stale owner=$old_owner reason=$REASON" \
      || echo "single-flight: warning: replacement audit could not be updated" >&2
    OWNER_FILE_CREATED=0
    echo "single-flight: replaced stale lease for $KEY"
    exit 0
    ;;

  heartbeat)
    [ -e "$LEASE" ] || [ -L "$LEASE" ] || { echo "single-flight: no lease for $KEY" >&2; exit 1; }
    validate_lease || exit 2
    [ "$LEASE_OWNER" = "$OWNER" ] || { echo "single-flight: owner mismatch for $KEY: $LEASE_OWNER" >&2; exit 1; }
    atomic_write "$LEASE/heartbeat" "$now" || {
      echo "single-flight: cannot publish heartbeat for $KEY" >&2; exit 1; }
    append_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) heartbeat by $OWNER" \
      || echo "single-flight: warning: heartbeat audit could not be updated" >&2
    echo "single-flight: heartbeat $KEY"
    exit 0
    ;;

  release)
    [ -e "$LEASE" ] || [ -L "$LEASE" ] || {
      [ -z "$OWNER_FILE" ] || rm -f "$OWNER_FILE" "$OWNER_KEY_FILE"
      echo "single-flight: no lease for $KEY"; exit 0; }
    validate_lease 1 || exit 2
    [ "$LEASE_OWNER" = "$OWNER" ] || { echo "single-flight: owner mismatch for $KEY: $LEASE_OWNER" >&2; exit 1; }
    rm -rf -- "$LEASE"
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
