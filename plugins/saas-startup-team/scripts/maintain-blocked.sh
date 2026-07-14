#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: maintain-blocked.sh {normalize|active} [--file PATH]... [--now RFC3339]" >&2
  echo "       maintain-blocked.sh upsert --file PATH --number N --reason TEXT --cooldown-until RFC3339" >&2
  exit 2
}

action=${1:-}; [ -n "$action" ] || usage; shift
files=(); now=""; number=""; reason=""; cooldown_until=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) [ "$#" -ge 2 ] || usage; files+=("$2"); shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
    --number) [ "$#" -ge 2 ] || usage; number=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
    --cooldown-until) [ "$#" -ge 2 ] || usage; cooldown_until=$2; shift 2 ;;
    *) usage ;;
  esac
done

schema='def valid_time:
  type == "string"
  and test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$")
  and (. as $value | try ((fromdateiso8601 | todateiso8601) == $value) catch false);
def valid_row:
  type == "object"
  and (.number | type == "number" and . > 0 and floor == .)
  and (.reason | type == "string" and length > 0 and length <= 500
    and (test("[[:cntrl:]]") | not))
  and (.cooldown_until | valid_time);
if all(.[]; valid_row) then map({number,reason,cooldown_until})
else error("invalid cooldown ledger row") end'

normalize_files() {
  local file
  if [ "${#files[@]}" -eq 0 ]; then printf '[]\n'; return 0; fi
  for file in "${files[@]}"; do
    [ -f "$file" ] && [ ! -L "$file" ] || {
      echo "maintain-blocked: unsafe ledger: $file" >&2; return 1; }
  done
  jq -s "$schema" "${files[@]}" || {
    echo "maintain-blocked: invalid cooldown ledger row" >&2
    return 1
  }
}

case "$action" in
  normalize)
    [ -z "$now$number$reason$cooldown_until" ] || usage
    normalize_files
    ;;
  active)
    [ -n "$now" ] && [ -z "$number$reason$cooldown_until" ] || usage
    jq -en --arg now "$now" '
      def valid_time:
        type == "string"
        and test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$")
        and (. as $value | try ((fromdateiso8601 | todateiso8601) == $value) catch false);
      $now | valid_time' >/dev/null || { echo "maintain-blocked: invalid --now" >&2; exit 2; }
    normalized=$(normalize_files) || exit 1
    jq --arg now "$now" '[.[] | select(.cooldown_until > $now) | .number] | unique | sort' \
      <<<"$normalized"
    ;;
  upsert)
    [ "${#files[@]}" -eq 1 ] && [ -z "$now" ] && [ -n "$number$reason$cooldown_until" ] || usage
    case "$number" in *[!0-9]*|0*|'') usage ;; esac
    row=$(jq -cn --argjson number "$number" --arg reason "$reason" \
      --arg cooldown_until "$cooldown_until" \
      '[{number:$number,reason:$reason,cooldown_until:$cooldown_until}]')
    jq -e "$schema" <<<"$row" >/dev/null || {
      echo "maintain-blocked: invalid cooldown row" >&2; exit 2; }
    file=${files[0]}; parent=$(dirname -- "$file")
    mkdir -p -- "$parent"
    [ -d "$parent" ] && [ ! -L "$parent" ] && [ ! -L "$file" ] || {
      echo "maintain-blocked: unsafe ledger path" >&2; exit 1; }
    command -v flock >/dev/null 2>&1 || { echo "maintain-blocked: flock is required" >&2; exit 2; }
    exec 9<"$parent"; flock -x 9
    [ ! -L "$file" ] || { echo "maintain-blocked: unsafe ledger path" >&2; exit 1; }
    if [ -e "$file" ]; then
      files=("$file"); current=$(normalize_files) || exit 1
    else current='[]'; fi
    tmp=$(mktemp "$file.tmp.XXXXXX")
    jq -c --argjson number "$number" --arg reason "$reason" \
      --arg cooldown_until "$cooldown_until" \
      'map(select(.number != $number))[]?,
       {number:$number,reason:$reason,cooldown_until:$cooldown_until}' \
      <<<"$current" > "$tmp"
    chmod 600 "$tmp"; mv -- "$tmp" "$file"
    echo "maintain-blocked: cooldown recorded for #$number"
    ;;
  *) usage ;;
esac
