#!/bin/bash
# bus.sh — cross-container handoff bus over a shared-mount directory.
# One JSON file per message; tmp+mv writes (readers never see partials);
# ack by mv into done/. No daemon, no queue, no delivery guarantees beyond
# mv-atomicity. Convention: <dir>/<recipient>/inbox/<msg-id>.json.
# Usage: bus.sh {send|poll|wait|gc} [options]
set -euo pipefail

usage() { echo "usage: bus.sh {send|poll|wait|gc} [options]" >&2; exit 2; }

MAX_BODY=$((64 * 1024))

now_epoch() { echo "${MC_NOW_EPOCH:-$(date +%s)}"; }
rand4() { printf '%04x' "$(( ((RANDOM << 8) ^ RANDOM) & 0xffff ))"; }
valid_name() { case "${1:-}" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac; }

# dir precedence: --dir flag > MC_BUS_DIR env > config .bus_dir (via MC_CONFIG)
resolve_dir() {
  local d="${1:-}"
  [ -n "$d" ] || d="${MC_BUS_DIR:-}"
  if [ -z "$d" ] && [ -n "${MC_CONFIG:-}" ] && [ -f "${MC_CONFIG:-}" ]; then
    d="$(jq -r '.bus_dir // empty' "$MC_CONFIG")"
  fi
  [ -n "$d" ] || { echo "bus: no bus dir (--dir | MC_BUS_DIR | config .bus_dir)" >&2; exit 2; }
  echo "$d"
}

CMD="${1:-}"; shift || usage
DIR=""; TO=""; FROM=""; SUBJECT=""; BODY=""; BODYFILE=""; REPLY_TO=""
NAME=""; CONSUME=0; JSON=0; TIMEOUT=""; BODY_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        DIR="${2:?--dir needs a value}"; shift 2 ;;
    --to)         TO="${2:?--to needs a value}"; shift 2 ;;
    --from)       FROM="${2:?--from needs a value}"; shift 2 ;;
    --subject)    SUBJECT="${2:?--subject needs a value}"; shift 2 ;;
    --body)       BODY="${2:?--body needs a value}"; BODY_SET=1; shift 2 ;;
    --body-file)  BODYFILE="${2:?--body-file needs a value}"; shift 2 ;;
    --reply-to)   REPLY_TO="${2:?--reply-to needs a value}"; shift 2 ;;
    --name)       NAME="${2:?--name needs a value}"; shift 2 ;;
    --consume)    CONSUME=1; shift ;;
    --json)       JSON=1; shift ;;
    --timeout)    TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    *) echo "bus: unexpected argument: $1" >&2; usage ;;
  esac
done

# list inbox message filenames oldest-first (msg-id starts with epoch)
inbox_files() { ls -1 "$1" 2>/dev/null | grep '\.json$' | sort || true; }

cmd_send() {
  local dir; dir="$(resolve_dir "$DIR")"
  [ -n "$TO" ] && [ -n "$FROM" ] && [ -n "$SUBJECT" ] \
    || { echo "bus: send needs non-empty --to, --from, --subject" >&2; exit 2; }
  valid_name "$TO"   || { echo "bus: invalid --to (allowed: [A-Za-z0-9_-]): $TO" >&2; exit 2; }
  valid_name "$FROM" || { echo "bus: invalid --from (allowed: [A-Za-z0-9_-]): $FROM" >&2; exit 2; }
  if [ -n "$BODYFILE" ]; then
    [ "$BODY_SET" = 0 ] || { echo "bus: use --body or --body-file, not both" >&2; exit 2; }
    [ -f "$BODYFILE" ] || { echo "bus: --body-file not found: $BODYFILE" >&2; exit 2; }
    BODY="$(cat "$BODYFILE")"
  fi
  local n=${#BODY}
  [ "$n" -le "$MAX_BODY" ] \
    || { echo "bus: body ${n}B exceeds 64KB cap; put the file on the shared mount and send its path" >&2; exit 2; }
  mkdir -p "$dir/.tmp" "$dir/$TO/inbox" "$dir/$TO/done" 2>/dev/null \
    || { echo "bus: cannot create bus dirs under $dir" >&2; exit 1; }
  local id created tmp
  id="$(now_epoch)-$FROM-$$-$(rand4)"
  while [ -e "$dir/$TO/inbox/$id.json" ] || [ -e "$dir/$TO/done/$id.json" ]; do
    id="$(now_epoch)-$FROM-$$-$(rand4)"
  done
  created="$(date -u -d "@$(now_epoch)" +%FT%TZ)"
  tmp="$dir/.tmp/$id.json"
  jq -n --arg id "$id" --arg from "$FROM" --arg to "$TO" --arg created "$created" \
        --arg subject "$SUBJECT" --arg body "$BODY" --arg reply_to "$REPLY_TO" \
        '{id:$id, from:$from, to:$to, created:$created}
         + (if $reply_to == "" then {} else {reply_to:$reply_to} end)
         + {subject:$subject, body:$body}' > "$tmp" \
    || { echo "bus: write failed under $dir/.tmp" >&2; exit 1; }
  mv "$tmp" "$dir/$TO/inbox/$id.json"
  echo "$id"
}

cmd_poll() {
  local dir; dir="$(resolve_dir "$DIR")"
  valid_name "$NAME" || { echo "bus: poll needs --name (allowed: [A-Za-z0-9_-])" >&2; exit 2; }
  local inbox="$dir/$NAME/inbox" done_d="$dir/$NAME/done" f p
  [ -d "$inbox" ] || return 0
  [ "$CONSUME" = 0 ] || mkdir -p "$done_d" \
    || { echo "bus: cannot create $done_d" >&2; exit 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    p="$inbox/$f"; [ -f "$p" ] || continue
    if [ "$CONSUME" = 1 ]; then mv "$p" "$done_d/$f"; p="$done_d/$f"; fi
    if [ "$JSON" = 1 ]; then jq -c . "$p"; else jq . "$p"; fi
  done < <(inbox_files "$inbox")
}

cmd_wait() {
  local dir; dir="$(resolve_dir "$DIR")"
  valid_name "$NAME" || { echo "bus: wait needs --name (allowed: [A-Za-z0-9_-])" >&2; exit 2; }
  [ -n "$REPLY_TO" ] || { echo "bus: wait needs --reply-to" >&2; exit 2; }
  case "$TIMEOUT" in ''|*[!0-9]*) echo "bus: wait needs --timeout <seconds>" >&2; exit 2 ;; esac
  # real wall clock: wait is a live primitive, independent of MC_NOW_EPOCH
  local deadline=$(( $(date +%s) + TIMEOUT )) backoff=1
  local inbox="$dir/$NAME/inbox" done_d="$dir/$NAME/done" f p
  while :; do
    if [ -d "$inbox" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        p="$inbox/$f"; [ -f "$p" ] || continue
        if [ "$(jq -r '.reply_to // empty' "$p")" = "$REPLY_TO" ]; then
          mkdir -p "$done_d" || { echo "bus: cannot create $done_d" >&2; exit 1; }
          mv "$p" "$done_d/$f"; jq . "$done_d/$f"; return 0
        fi
      done < <(inbox_files "$inbox")
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { echo "bus: wait timeout (reply_to=$REPLY_TO)" >&2; return 1; }
    sleep "$backoff"
    backoff=$(( backoff * 2 )); [ "$backoff" -le 15 ] || backoff=15
  done
}

cmd_gc() {
  local dir; dir="$(resolve_dir "$DIR")"
  [ -d "$dir" ] || return 0
  local rd=""
  [ -n "${MC_CONFIG:-}" ] && [ -f "${MC_CONFIG:-}" ] && rd="$(jq -r '.retention_days // empty' "$MC_CONFIG")"
  [ -n "$rd" ] || rd=14
  find "$dir" -path '*/done/*' -type f -mtime +"$rd" -delete 2>/dev/null || true
}

case "$CMD" in
  send) cmd_send ;;
  poll) cmd_poll ;;
  wait) cmd_wait ;;
  gc)   cmd_gc ;;
  *) usage ;;
esac
