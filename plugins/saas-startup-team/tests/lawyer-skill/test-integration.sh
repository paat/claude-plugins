#!/usr/bin/env bash
set -u

# Real-network integration smoke test. Skips cleanly when EST_DATALAKE_API_KEY
# is unset so the default harness stays offline-safe. When the key is set,
# this test guards against future API schema drift (the class of bug that
# v0.29.x shipped with).

if [ -z "${EST_DATALAKE_API_KEY:-}" ]; then
  echo "SKIP: test-integration (set EST_DATALAKE_API_KEY to enable)"
  exit 0
fi

: "${DATALAKE_URL:=https://datalake.r-53.com}"
AUTH=( -H "X-API-Key: $EST_DATALAKE_API_KEY" )

fail() { echo "FAIL: $1"; exit 1; }

# 1. Health
code=$(curl --max-time 10 -s -o /dev/null -w "%{http_code}" "$DATALAKE_URL/api/v1/health/ready")
[ "$code" = "200" ] || fail "health not 200 (got $code)"

# 2. /changes/feed response has .items (not .events) and expected field names
resp=$(curl --max-time 30 -s "${AUTH[@]}" "$DATALAKE_URL/api/v1/changes/feed?limit=3")
echo "$resp" | jq -e '.items | type == "array"' >/dev/null || fail "feed response missing .items array"
echo "$resp" | jq -e '.total | type == "number"' >/dev/null || fail "feed response missing .total"
if [ "$(echo "$resp" | jq '.items | length')" -gt 0 ]; then
  for field in id change_type act_title rt_id detected_at domains; do
    echo "$resp" | jq -e ".items[0] | has(\"$field\")" >/dev/null || fail "feed event missing .$field"
  done
  echo "$resp" | jq -e '.items[0].domains | type == "array"' >/dev/null || fail ".domains not an array"
fi

# 3. /laws/search returns ActSummary with .id (integer) and .rt_id (string)
resp=$(curl --max-time 30 -s "${AUTH[@]}" "$DATALAKE_URL/api/v1/laws/search?q=isikuandmete+kaitse&limit=1")
echo "$resp" | jq -e '.items | type == "array"' >/dev/null || fail "/laws/search missing .items"
echo "$resp" | jq -e '.items[0].id | type == "number"' >/dev/null || fail "/laws/search .items[0].id not integer"
echo "$resp" | jq -e '.items[0].rt_id | type == "string"' >/dev/null || fail "/laws/search .items[0].rt_id not string"
ACT_ID=$(echo "$resp" | jq -r '.items[0].id')

# 4. /laws/{act_id}/graph — canonical rt_id + title resolver
resp=$(curl --max-time 30 -s -w '\n%{http_code}' "${AUTH[@]}" "$DATALAKE_URL/api/v1/laws/${ACT_ID}/graph")
code=$(printf '%s' "$resp" | tail -n1)
body=$(printf '%s' "$resp" | sed '$d')
[ "$code" = "200" ] || fail "/laws/$ACT_ID/graph HTTP $code"
echo "$body" | jq -e '.act.id | type == "number"' >/dev/null || fail "graph .act.id not integer"
echo "$body" | jq -e '.act.rt_id | type == "string"' >/dev/null || fail "graph .act.rt_id not string"

# 5. /laws/{act_id}/citation — integer act_id, paragraph as query param
resp=$(curl --max-time 30 -s -w '\n%{http_code}' "${AUTH[@]}" "$DATALAKE_URL/api/v1/laws/${ACT_ID}/citation?paragraph=1")
code=$(printf '%s' "$resp" | tail -n1)
body=$(printf '%s' "$resp" | sed '$d')
# Some acts don't have paragraph 1 — accept 200 or 404 as "endpoint works",
# anything else (500, 422 on path type, HTML) is a schema drift.
case "$code" in
  200) echo "$body" | jq -e '.text | type == "string"' >/dev/null || fail "citation .text not string" ;;
  404) ;;  # valid: "Citation not found" / "Act not found"
  *) fail "/laws/${ACT_ID}/citation unexpected HTTP $code" ;;
esac

# 6. /compliance/checklist requires business_type (sanity-check 422 on missing field)
resp=$(curl --max-time 30 -s -w '\n%{http_code}' -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
  -d '{}' "$DATALAKE_URL/api/v1/compliance/checklist")
code=$(printf '%s' "$resp" | tail -n1)
[ "$code" = "422" ] || fail "compliance/checklist with empty body should 422, got $code"

echo "PASS: test-integration (real datalake)"
