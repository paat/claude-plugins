#!/usr/bin/env bash
# Fail closed before an authenticated metrics read can enter the wrong Ads account.
set -euo pipefail

require_read_only=0
if [ "${1:-}" = "--require-read-only" ]; then require_read_only=1; shift; fi
campaign_dir="${1:-}"
[ "$#" -eq 1 ] && [ -n "$campaign_dir" ] || {
  echo "usage: check-metrics-preflight.sh [--require-read-only] <campaign-dir>" >&2
  exit 2
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/check-campaign-path.sh" --require-current "$campaign_dir" >/dev/null

brief="$campaign_dir/brief.md"
[ -f "$brief" ] || { echo "ads-metrics preflight: missing $brief" >&2; exit 3; }
[ -s "$campaign_dir/launched_at" ] || {
  echo "ads-metrics preflight: missing or empty $campaign_dir/launched_at" >&2
  exit 3
}
launch_raw="$(cat "$campaign_dir/launched_at")"
if ! printf '%s' "$launch_raw" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-](0[0-9]|1[0-9]|2[0-3]):[0-5][0-9])$'; then
  echo "ads-metrics preflight: launched_at must contain one ISO timestamp" >&2
  exit 3
fi
DATE_BIN="$(command -v gdate 2>/dev/null || command -v date 2>/dev/null || true)"
[ -n "$DATE_BIN" ] && "$DATE_BIN" -d "$launch_raw" +%s >/dev/null 2>&1 || {
  echo "ads-metrics preflight: launched_at is not a real date" >&2
  exit 3
}

field() {
  local kind="$1"
  case "$kind" in
    account)
      sed -n \
        -e 's/^[[:space:]]*-[[:space:]]*\*\*Google Ads account ID\*\*:[[:space:]]*//p' \
        -e 's/^[[:space:]]*-[[:space:]]*\*\*ads_account_id\*\*:[[:space:]]*//p' \
        -e 's/^[[:space:]]*ads_account_id:[[:space:]]*//p' "$brief"
      ;;
    campaign)
      sed -n \
        -e 's/^[[:space:]]*-[[:space:]]*\*\*Google Ads campaign ID\*\*:[[:space:]]*//p' \
        -e 's/^[[:space:]]*-[[:space:]]*\*\*campaign_id\*\*:[[:space:]]*//p' \
        -e 's/^[[:space:]]*campaign_id:[[:space:]]*//p' "$brief"
      ;;
    access)
      sed -n \
        -e 's/^[[:space:]]*-[[:space:]]*\*\*Google Ads metrics access\*\*:[[:space:]]*//p' "$brief"
      ;;
  esac
}

mapfile -t account_fields < <(field account)
mapfile -t campaign_fields < <(field campaign)
[ "${#account_fields[@]}" -eq 1 ] || {
  echo "ads-metrics preflight: brief.md must contain exactly one account ID field" >&2
  exit 3
}
[ "${#campaign_fields[@]}" -eq 1 ] || {
  echo "ads-metrics preflight: brief.md must contain exactly one campaign ID field" >&2
  exit 3
}
account_raw="${account_fields[0]}"
campaign_raw="${campaign_fields[0]}"

if [ "$require_read_only" -eq 1 ]; then
  mapfile -t access_fields < <(field access)
  [ "${#access_fields[@]}" -eq 1 ] || {
    echo "ads-monitor preflight: brief.md must contain exactly one metrics access field" >&2
    exit 3
  }
  if ! printf '%s' "${access_fields[0]}" | grep -Eq '^[[:space:]`]*read-only[[:space:]`]*$'; then
    echo "ads-monitor preflight: Google Ads metrics access must be read-only" >&2
    exit 3
  fi
fi

if ! printf '%s' "$account_raw" | grep -Eq '^[[:space:]`]*[0-9][0-9 -]*[[:space:]`]*$'; then
  echo "ads-metrics preflight: brief.md needs a verified Google Ads account ID" >&2
  exit 3
fi
account_id="$(printf '%s' "$account_raw" | tr -cd '0-9')"
[ "${#account_id}" -eq 10 ] || {
  echo "ads-metrics preflight: Google Ads account ID must contain exactly 10 digits" >&2
  exit 3
}

if ! printf '%s' "$campaign_raw" | grep -Eq '^[[:space:]`]*[1-9][0-9]*[[:space:]`]*$'; then
  echo "ads-metrics preflight: brief.md needs a verified numeric Google Ads campaign ID" >&2
  exit 3
fi
campaign_id="$(printf '%s' "$campaign_raw" | tr -cd '0-9')"

printf 'ads-metrics preflight: ok\n'
printf 'ads_account_id=%s\n' "$account_id"
printf 'campaign_id=%s\n' "$campaign_id"
[ "$require_read_only" -eq 0 ] || printf 'metrics_access=read-only\n'
