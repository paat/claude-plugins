#!/usr/bin/env bash
# Deterministic prerequisites for /lawyer. Emits no secrets.
set -euo pipefail

source "$(dirname "$0")/lawyer-common.sh"

die() {
  echo "lawyer preflight: $*" >&2
  exit 2
}

if [ -f .startup/law-registry.json ]; then
  jq -e '.version == 2 and (.entries | type == "object")' \
    .startup/law-registry.json >/dev/null 2>&1 \
    || die ".startup/law-registry.json is invalid or not version 2"
fi

[ ! -e .startup/laws ] || [ -d .startup/laws ] \
  || die ".startup/laws exists but is not a directory"

code=$(curl --max-time 10 -s -o /dev/null -w '%{http_code}' \
  "$DATALAKE_URL/api/v1/health/ready" || true)
[ "$code" = 200 ] \
  || die "datalake is not ready at $DATALAKE_URL (HTTP ${code:-unreachable})"

auth_code=$(lawyer_dl_curl --max-time 10 -s -o /dev/null -w '%{http_code}' \
  "$DATALAKE_URL/api/v1/laws/search?q=preflight&limit=1" || true)
if [ -n "${EST_DATALAKE_API_KEY:-}" ]; then
  mode="API key"
  [ "$auth_code" = 200 ] \
    || die "datalake authentication failed (HTTP ${auth_code:-unreachable})"
else
  mode="no API key"
  case "$auth_code" in
    200) ;;
    401|403) die "$DATALAKE_URL requires EST_DATALAKE_API_KEY (HTTP $auth_code)" ;;
    *) die "datalake search probe failed without an API key (HTTP ${auth_code:-unreachable})" ;;
  esac
fi

echo "lawyer preflight: ok ($mode)"
