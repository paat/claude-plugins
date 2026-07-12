#!/bin/bash
# Validate the canonical owner spend-envelope contract and print normalized JSON.
set -euo pipefail

channel=""

deny() {
  printf 'spend-envelope: invalid: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel)
      [ "$#" -ge 2 ] || deny "--channel needs a value"
      channel="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) deny "unknown argument: $1" ;;
    *) break ;;
  esac
done

[ "$#" -eq 1 ] || deny "expected one envelope path"
envelope="$1"
[ -f "$envelope" ] || deny "file not found"
command -v jq >/dev/null 2>&1 || deny "missing dependency: jq"

if command -v gdate >/dev/null 2>&1; then
  date_bin="$(command -v gdate)"
elif command -v date >/dev/null 2>&1; then
  date_bin="$(command -v date)"
else
  deny "missing dependency: date"
fi

# Caps are bounded so downstream bash integer arithmetic can never overflow
# or receive scientific notation — an absurd cap is a typo, not authorization.
jq -e '
  type == "object"
  and ((.monthly_cap_eur | type) == "number" and .monthly_cap_eur >= 0 and .monthly_cap_eur <= 1000000 and .monthly_cap_eur == (.monthly_cap_eur | floor))
  and ((.daily_cap_eur | type) == "number" and .daily_cap_eur >= 0 and .daily_cap_eur <= 1000000 and .daily_cap_eur == (.daily_cap_eur | floor))
  and (.buyer_intent_only == true)
  and ((.channels | type) == "array" and (.channels | length) > 0 and all(.channels[]; type == "string" and length > 0))
  and ((.authorized_by | type) == "string" and (.authorized_by | length) > 0)
  and ((.authorized_at | type) == "string" and (.authorized_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
  and ((.expires_at | type) == "string" and (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
' "$envelope" >/dev/null 2>&1 || deny "schema"

if [ -n "$channel" ] && ! jq -e --arg channel "$channel" \
  '.channels | index($channel) != null' "$envelope" >/dev/null 2>&1; then
  deny "channel not authorized: $channel"
fi

to_epoch() { # GNU date -d, then BSD date -j -f; 0 = unparseable (fail closed)
  "$date_bin" -d "$1" +%s 2>/dev/null && return 0
  "$date_bin" -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
  echo 0
}
fields="$(jq -r '[.authorized_at, .expires_at] | @tsv' "$envelope")"
IFS=$'\t' read -r authorized_at expires_at <<< "$fields"
authorized_epoch="$(to_epoch "$authorized_at")"
expires_epoch="$(to_epoch "$expires_at")"
now_epoch="$($date_bin +%s)"

[ "$authorized_epoch" -gt 0 ] 2>/dev/null || deny "authorized_at"
[ "$authorized_epoch" -le "$now_epoch" ] || deny "authorization is in the future"
[ "$now_epoch" -le "$expires_epoch" ] || deny "expired"

jq -c '{monthly_cap_eur, daily_cap_eur, channels, buyer_intent_only, authorized_by, authorized_at, expires_at}' "$envelope"
