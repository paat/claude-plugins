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

schema_defs='def valid_time:
  type == "string"
  and test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$")
  and (. as $value | try ((fromdateiso8601 | todateiso8601) == $value) catch false);
def valid_row:
  type == "object"
  and (.number | type == "number" and . > 0 and floor == .)
  and (.reason | type == "string" and length > 0 and length <= 500
    and (test("[[:cntrl:]]") | not))
  and (.cooldown_until | valid_time);'

schema="$schema_defs
if all(.[]; valid_row) then map({number,reason,cooldown_until}) else empty end"

invalid_row="$schema_defs
to_entries
| map(select((.value | valid_row) | not))
| .[0]
| if (.value | type) == \"object\" and (.value.number | type) == \"number\"
  then \"row \\(.key + 1), issue #\\(.value.number)\"
  else \"row \\(.key + 1), issue unknown\"
  end"

legacy_normalize='def canonical_time:
  if type == "string"
    and test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])$")
  then . + "T00:00:00Z"
  else . end;
map(if type == "object" then
  (if (.reason | type) == "string" then .reason = .reason[:500] else . end)
  | .cooldown_until |= canonical_time
else . end)'

normalize_file() {
  local file="$1" raw normalized canonical overlong bad_row
  raw=$(jq -cs '.' "$file") || {
    echo "maintain-blocked: invalid JSON: $file" >&2
    return 1
  }
  overlong=$(jq -r '[.[]
    | select(type == "object" and (.reason | type == "string" and length > 500))
    | if (.number | type) == "number" then "#\(.number)" else "unknown issue" end]
    | join(", ")' <<<"$raw")
  if [ -n "$overlong" ]; then
    echo "maintain-blocked: truncating overlong reason in memory: $file ($overlong)" >&2
  fi
  normalized=$(jq -c "$legacy_normalize" <<<"$raw") || return 1
  if ! canonical=$(jq -ce "$schema" <<<"$normalized"); then
    bad_row=$(jq -r "$invalid_row" <<<"$normalized")
    echo "maintain-blocked: invalid cooldown ledger row: $file ($bad_row)" >&2
    return 1
  fi
  printf '%s\n' "$canonical"
}

normalize_files() {
  local file normalized combined='[]'
  if [ "${#files[@]}" -eq 0 ]; then printf '[]\n'; return 0; fi
  for file in "${files[@]}"; do
    [ -f "$file" ] && [ ! -L "$file" ] || {
      echo "maintain-blocked: unsafe ledger: $file" >&2; return 1; }
    normalized=$(normalize_file "$file") || return 1
    combined=$(jq -cn --argjson current "$combined" --argjson next "$normalized" \
      '$current + $next') || return 1
  done
  printf '%s\n' "$combined"
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
      '[{number:$number,reason:$reason[:500],cooldown_until:$cooldown_until}]')
    jq -e "$schema" <<<"$row" >/dev/null || {
      echo "maintain-blocked: invalid cooldown row" >&2; exit 2; }
    reason=$(jq -r '.[0].reason' <<<"$row")
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
