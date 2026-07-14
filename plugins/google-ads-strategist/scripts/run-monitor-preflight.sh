#!/usr/bin/env bash
# Normalize expected monitor blockers without turning them into recoverable tool errors.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
campaign=""
range="7d"
range_seen=0

terminal_result() {
  local status="$1" diagnostic="$2"
  diagnostic="${diagnostic//\\/\\\\}"
  diagnostic="${diagnostic//\"/\\\"}"
  diagnostic="${diagnostic//$'\n'/\\n}"
  diagnostic="${diagnostic//$'\r'/\\r}"
  diagnostic="${diagnostic//$'\t'/\\t}"
  printf '{"status":"%s","terminal":true,"diagnostic":"%s"}\n' "$status" "$diagnostic"
  exit 0
}

blocked() { terminal_result "blocked" "$1"; }
internal_error() { terminal_result "error" "ads-monitor preflight: internal prerequisite check failed"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --range)
      [ "$#" -ge 2 ] || blocked "ads-monitor preflight: --range requires 7d or 30d"
      [ "$range_seen" -eq 0 ] || blocked "ads-monitor preflight: range may be specified only once"
      range="$2"
      range_seen=1
      shift 2
      ;;
    --range=*)
      [ "$range_seen" -eq 0 ] || blocked "ads-monitor preflight: range may be specified only once"
      range="${1#--range=}"
      range_seen=1
      shift
      ;;
    --*)
      blocked "ads-monitor preflight: unexpected argument"
      ;;
    *)
      [ -z "$campaign" ] || blocked "ads-monitor preflight: expected at most one campaign"
      campaign="$1"
      shift
      ;;
  esac
done

case "$range" in
  7d|30d) ;;
  *) blocked "ads-monitor preflight: range must be 7d or 30d" ;;
esac

if [ -z "$campaign" ]; then
  shopt -s nullglob
  briefs=(docs/ads/*/brief.md)
  [ "${#briefs[@]}" -eq 1 ] || {
    blocked "ads-monitor preflight: expected exactly one campaign; pass a campaign name"
  }
  campaign_dir="${briefs[0]%/brief.md}"
  campaign="${campaign_dir##*/}"
else
  campaign_dir="docs/ads/$campaign"
fi

case "$campaign" in
  .*|*[!A-Za-z0-9._-]*)
    blocked "ads-monitor preflight: campaign must be a directory slug"
    ;;
esac

rc=0
output="$(bash "$SCRIPT_DIR/check-metrics-preflight.sh" --require-read-only "$campaign_dir" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  diagnostic="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -n 1)"
  case "$rc" in
    2|3)
      case "$diagnostic" in
        "ads campaign path: "*|"ads-metrics preflight: "*|"ads-monitor preflight: "*) ;;
        *) internal_error ;;
      esac
      ;;
    *) internal_error ;;
  esac
  [ -n "$diagnostic" ] || diagnostic="ads-monitor preflight: prerequisite check failed"
  blocked "$diagnostic"
fi

mapfile -t account_fields < <(printf '%s\n' "$output" | sed -n 's/^ads_account_id=//p')
mapfile -t campaign_fields < <(printf '%s\n' "$output" | sed -n 's/^campaign_id=//p')
mapfile -t access_fields < <(printf '%s\n' "$output" | sed -n 's/^metrics_access=//p')
[ "${#account_fields[@]}" -eq 1 ] &&
  [ "${#campaign_fields[@]}" -eq 1 ] &&
  [ "${#access_fields[@]}" -eq 1 ] || {
    internal_error
  }
printf '%s' "${account_fields[0]}" | grep -Eq '^[0-9]{10}$' || {
  internal_error
}
printf '%s' "${campaign_fields[0]}" | grep -Eq '^[1-9][0-9]{0,18}$' || {
  internal_error
}
[ "${access_fields[0]}" = "read-only" ] || {
  internal_error
}

printf '{"status":"ready","terminal":false,"campaign":"%s","range":"%s","ads_account_id":"%s","campaign_id":"%s","metrics_access":"read-only"}\n' \
  "$campaign" "$range" "${account_fields[0]}" "${campaign_fields[0]}"
