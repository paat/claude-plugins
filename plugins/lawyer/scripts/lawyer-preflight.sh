#!/usr/bin/env bash
# Deterministic prerequisites for /lawyer. Emits no secrets.
set -euo pipefail

: "${DATALAKE_URL:=https://datalake.r-53.com}"

die() {
  echo "lawyer preflight: $*" >&2
  exit 2
}

[ -n "${EST_DATALAKE_API_KEY:-}" ] \
  || die "EST_DATALAKE_API_KEY is not set"

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

auth_code=$(curl --max-time 10 -s -o /dev/null -w '%{http_code}' \
  -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/search?q=preflight&limit=1" || true)
[ "$auth_code" = 200 ] \
  || die "datalake authentication failed (HTTP ${auth_code:-unreachable})"

echo "lawyer preflight: ok"
