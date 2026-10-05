#!/usr/bin/env bash
# Regression tests: fixplan collector records failed citation fetches as
# fetch_error instead of presenting them as empty new law text.

fixplan_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/.startup/laws" "$dir/plan"

  cat > "$dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
code=200
rc=0
body=""
case "$url" in
  */laws/*/citation*)
    body="$CITATION_BODY"
    code="${CITATION_CODE:-200}"
    rc="${CITATION_RC:-0}"
    ;;
  */graph*)
    body='{"act":{"rt_id":"456","title":"Sample law","act_type":"seadus"}}'
    ;;
  */changes/feed*)
    body='{"items":[],"total":0,"partial":false}'
    ;;
  *)
    echo "Unexpected mock URL: $url" >&2
    exit 99
    ;;
esac
printf '%s' "$body"
for arg in "$@"; do
  if [ "$arg" = -w ] || [ "$arg" = --write-out ]; then
    printf '\n%s' "$code"
    break
  fi
done
exit "$rc"
MOCK
  chmod +x "$dir/bin/curl"

  for slug in "${@:2}"; do
    echo "OLD SNAPSHOT" > "$dir/.startup/laws/$slug.txt"
  done

  local keys
  keys=$(printf '%s\n' "${@:2}" | jq -R . | jq -s -c .)
  jq -n --argjson keys "$keys" '{
    version: 1,
    entries: ($keys | map({
      (.): {
        act_id: 124,
        citation: "§ 14 lõige 1",
        citation_parts: {paragraph: "14", section: "1"},
        needs_review: true,
        gh_issue_url: null,
        verified_at: "2024-01-01T00:00:00Z",
        dependent_files: [],
        purpose: "test"
      }
    }) | add)
  }' > "$dir/.startup/law-registry.json"
}

test_fixplan_fetch_error() {
  local dir rc
  local valid_body='{"text":"Verified replacement text.","status":"valid","in_force":true}'
  local ok=0

  # Case a: transport failure (curl exit 6)
  dir=$(mktemp -d); fixplan_fixture "$dir" "slug-a"
  rc=0
  (cd "$dir" && PATH="$dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    CITATION_RC=6 CITATION_CODE=200 CITATION_BODY="$valid_body" \
    bash "$PLUGIN_ROOT/scripts/lawyer-fixplan-collect.sh" "$dir/plan") > "$dir/out" 2>&1 || rc=$?
  local got
  got=$(jq -r '[.fetch_error, .new_text, (.status|tostring), (.in_force|tostring)] | join("|")' "$dir/plan/slug-a.json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ "$got" != "transport failure||null|null" ] \
     || ! grep -q "WARNING: transport failure" "$dir/out"; then
    echo "  ${CYAN}transport: rc=$rc got=$got${NC}"
    ok=1
  fi

  # Case b: non-2xx (HTTP 503)
  dir=$(mktemp -d); fixplan_fixture "$dir" "slug-b"
  rc=0
  (cd "$dir" && PATH="$dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    CITATION_RC=0 CITATION_CODE=503 CITATION_BODY='{}' \
    bash "$PLUGIN_ROOT/scripts/lawyer-fixplan-collect.sh" "$dir/plan") > "$dir/out" 2>&1 || rc=$?
  got=$(jq -r '[.fetch_error, .new_text, (.status|tostring), (.in_force|tostring)] | join("|")' "$dir/plan/slug-b.json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ "$got" != "HTTP 503||null|null" ] \
     || ! grep -q "WARNING: HTTP 503" "$dir/out"; then
    echo "  ${CYAN}http-503: rc=$rc got=$got${NC}"
    ok=1
  fi

  # Case c: error-shaped JSON on 200
  dir=$(mktemp -d); fixplan_fixture "$dir" "slug-c"
  rc=0
  (cd "$dir" && PATH="$dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    CITATION_RC=0 CITATION_CODE=200 CITATION_BODY='{"detail":"Upstream unavailable"}' \
    bash "$PLUGIN_ROOT/scripts/lawyer-fixplan-collect.sh" "$dir/plan") > "$dir/out" 2>&1 || rc=$?
  got=$(jq -r '[.fetch_error, .new_text, (.status|tostring), (.in_force|tostring)] | join("|")' "$dir/plan/slug-c.json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ "$got" != "invalid response or missing lifecycle fields||null|null" ]; then
    echo "  ${CYAN}error-json: rc=$rc got=$got${NC}"
    ok=1
  fi

  # Case d: valid response — unchanged artifact, fetch_error null
  dir=$(mktemp -d); fixplan_fixture "$dir" "slug-d"
  rc=0
  (cd "$dir" && PATH="$dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    CITATION_RC=0 CITATION_CODE=200 CITATION_BODY="$valid_body" \
    bash "$PLUGIN_ROOT/scripts/lawyer-fixplan-collect.sh" "$dir/plan") > "$dir/out" 2>&1 || rc=$?
  got=$(jq -r '[(.fetch_error|tostring), .new_text, .status, (.in_force|tostring)] | join("|")' "$dir/plan/slug-d.json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ "$got" != "null|Verified replacement text.|valid|true" ]; then
    echo "  ${CYAN}valid: rc=$rc got=$got${NC}"
    ok=1
  fi

  # Case e: valid response with genuinely empty text
  dir=$(mktemp -d); fixplan_fixture "$dir" "slug-e"
  rc=0
  (cd "$dir" && PATH="$dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    CITATION_RC=0 CITATION_CODE=200 \
    CITATION_BODY='{"text":"","status":"valid","in_force":true}' \
    bash "$PLUGIN_ROOT/scripts/lawyer-fixplan-collect.sh" "$dir/plan") > "$dir/out" 2>&1 || rc=$?
  got=$(jq -r '[(.fetch_error|tostring), .new_text] | join("|")' "$dir/plan/slug-e.json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ "$got" != "null|" ]; then
    echo "  ${CYAN}valid-empty: rc=$rc got=$got${NC}"
    ok=1
  fi

  # Case f: two flagged slugs, first fails — second artifact still correct.
  # Citation URLs carry the act_id, not the slug, so give slug-f2 a distinct
  # act_id and route the mock on act id.
  dir=$(mktemp -d)
  fixplan_fixture "$dir" "slug-f1" "slug-f2"
  jq '(.entries["slug-f2"].act_id) = 125' "$dir/.startup/law-registry.json" > "$dir/.startup/law-registry.json.tmp" \
    && mv "$dir/.startup/law-registry.json.tmp" "$dir/.startup/law-registry.json"
  cat > "$dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
code=200
rc=0
body=""
case "$url" in
  */laws/124/citation*)
    rc=6
    ;;
  */laws/125/citation*)
    body='{"text":"Second slug text.","status":"valid","in_force":true}'
    ;;
  */graph*)
    body='{"act":{"rt_id":"456","title":"Sample law","act_type":"seadus"}}'
    ;;
  */changes/feed*)
    body='{"items":[],"total":0,"partial":false}'
    ;;
  *)
    echo "Unexpected mock URL: $url" >&2
    exit 99
    ;;
esac
printf '%s' "$body"
for arg in "$@"; do
  if [ "$arg" = -w ] || [ "$arg" = --write-out ]; then
    printf '\n%s' "$code"
    break
  fi
done
exit "$rc"
MOCK
  chmod +x "$dir/bin/curl"
  rc=0
  (cd "$dir" && PATH="$dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    bash "$PLUGIN_ROOT/scripts/lawyer-fixplan-collect.sh" "$dir/plan") > "$dir/out" 2>&1 || rc=$?
  local first second
  first=$(jq -r '[(.fetch_error|tostring), .new_text] | join("|")' "$dir/plan/slug-f1.json" 2>/dev/null)
  second=$(jq -r '[(.fetch_error|tostring), .new_text] | join("|")' "$dir/plan/slug-f2.json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$first" ] || [ -z "$second" ] \
     || [ "$first" != "transport failure|" ] || [ "$second" != "null|Second slug text." ]; then
    echo "  ${CYAN}two-slugs: rc=$rc first=$first second=$second${NC}"
    ok=1
  fi

  record "fixplan collector records citation fetch failures as fetch_error" "$ok" \
    "fetch_error set for transport/HTTP/invalid failures; valid and genuinely-empty responses keep fetch_error null; a failing slug does not break later slugs"
}

test_fixplan_fetch_error
