# Real-script change-feed coverage (#591). Mock curl is first on PATH.
# No network and no live API key: EST_DATALAKE_API_KEY is synthetic.

feed_cursor_install() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/.startup/laws"
  cat > "$dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
emit_code=0
for a in "$@"; do
  if [ "$a" = "-w" ] || [ "$a" = "--write-out" ]; then
    emit_code=1
  fi
done
case "$url" in
  */changes/feed*)
    if [ "${FEED_SLEEP:-0}" != 0 ]; then
      sleep "$FEED_SLEEP"
    fi
    if [ -n "${FEED_STAMP:-}" ]; then
      date -u +%Y-%m-%dT%H:%M:%SZ > "$FEED_STAMP"
    fi
    if [ "${FEED_RC:-0}" -ne 0 ]; then
      exit "$FEED_RC"
    fi
    if [ -n "${FEED_URL_LOG:-}" ]; then
      printf '%s\n' "$url" >> "$FEED_URL_LOG"
    fi
    if [ -n "${FEED_BODY_FILE:-}" ]; then
      body=$(cat "$FEED_BODY_FILE")
      if [ -n "${FEED_CALLS:-}" ]; then
        n=$(cat "$FEED_CALLS" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" > "$FEED_CALLS"
        if [ "$n" -ge 2 ] && [ -n "${FEED_BODY_FILE2:-}" ]; then
          body=$(cat "$FEED_BODY_FILE2")
        fi
      fi
    else
      body=""
    fi
    code="${FEED_CODE:-200}"
    ;;
  */citation*)
    body='{"text":"Current clause.","status":"valid","in_force":true}'
    code=200
    ;;
  *)
    echo "Unexpected mock URL: $url" >&2
    exit 99
    ;;
esac
if [ "$emit_code" = 1 ]; then
  printf '%s\n%s' "$body" "$code"
else
  printf '%s' "$body"
fi
MOCK
  chmod +x "$dir/bin/curl"
}

feed_cursor_reset() {
  jq -n '{
    version: 2,
    last_feed_check_at: "2026-09-01T00:00:00Z",
    entries: {
      "pending-law": {
        act_id: 1, rt_id: "111", citation: "§ 1",
        citation_parts: {paragraph:"1", paragraph_qualifier:"", section:"", section_qualifier:"", point:"", point_qualifier:""},
        status: "valid", verified_at: "2020-01-01T00:00:00Z",
        needs_review: true, change_detected_at: "2020-02-01T00:00:00Z",
        change: {feed_event_id:null, type:"lifecycle", summary:"Pending review", effective_date:null},
        gh_issue_url: "https://example.test/issues/9"
      },
      "open-law": {
        act_id: 123, rt_id: "456", citation: "§ 14 lõige 1",
        citation_parts: {paragraph:"14", paragraph_qualifier:"", section:"1", section_qualifier:"", point:"", point_qualifier:""},
        status: "valid", verified_at: "2020-01-01T00:00:00Z",
        needs_review: false, change_detected_at: null, change: null, gh_issue_url: null
      }
    }
  }' > "$feed_dir/.startup/law-registry.json"
}

feed_cursor_run() {
  feed_rc=0
  (
    cd "$feed_dir" && PATH="$feed_dir/bin:$PATH" \
      EST_DATALAKE_API_KEY=synthetic-key \
      DATALAKE_URL=https://example.invalid \
      FEED_BODY_FILE="$feed_dir/feed.json" \
      FEED_BODY_FILE2="${FEED_BODY_FILE2:-}" \
      FEED_CALLS="${FEED_CALLS:-}" \
      FEED_URL_LOG="${FEED_URL_LOG:-}" \
      FEED_CODE="${FEED_CODE:-200}" \
      FEED_RC="${FEED_RC:-0}" \
      FEED_SLEEP="${FEED_SLEEP:-0}" \
      FEED_STAMP="${FEED_STAMP:-}" \
      bash "$PLUGIN_ROOT/scripts/lawyer-check.sh"
  ) > "$feed_dir/stdout" 2> "$feed_dir/stderr" || feed_rc=$?
}

# feed_cursor_check LABEL rc cursor-mode open-mode
# cursor-mode: kept | advanced | issued
# open-mode: clean | flagged
feed_cursor_check() {
  local label="$1" expect_rc="$2" cursor_mode="$3" open_mode="$4"
  local ok=0 cursor stamp
  cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq "$expect_rc" ] || ok=1
  if [ "$expect_rc" -ne 0 ]; then
    grep -qF 'WARNING' "$feed_dir/stderr" || ok=1
    grep -qF 'incomplete coverage' "$feed_dir/stderr" || ok=1
    grep -qF 'seaduste muudatuste kontroll' "$feed_dir/stderr" || ok=1
  else
    if grep -qF 'incomplete coverage' "$feed_dir/stderr"; then
      ok=1
    fi
  fi
  case "$cursor_mode" in
    kept) [ "$cursor" = "2026-09-01T00:00:00Z" ] || ok=1 ;;
    advanced) [ "$cursor" != "2026-09-01T00:00:00Z" ] || ok=1 ;;
    issued)
      [ "$cursor" != "2026-09-01T00:00:00Z" ] || ok=1
      stamp=$(cat "$feed_dir/stamp")
      # Request time is captured before curl; the stamp is written after the mock sleeps.
      [[ "$cursor" < "$stamp" ]] || ok=1
      ;;
  esac
  jq -e '.entries["pending-law"] | .needs_review == true and .change.summary == "Pending review" and .change_detected_at == "2020-02-01T00:00:00Z"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || ok=1
  if [ "$open_mode" = flagged ]; then
    jq -e '.entries["open-law"] | .needs_review == true and .change.type == "amendment" and .change.feed_event_id == 7' \
      "$feed_dir/.startup/law-registry.json" >/dev/null || ok=1
  else
    jq -e '.entries["open-law"] | .needs_review == false and .change == null' \
      "$feed_dir/.startup/law-registry.json" >/dev/null || ok=1
  fi
  record "$label" "$ok" "exit=$feed_rc cursor=$cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr") stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"
}

feed_cursor_body() {
  printf '%s' "$1" > "$feed_dir/feed.json"
}

feed_cursor_item() {
  jq -n '{
    partial: false,
    warnings: [],
    total: 1,
    items: [{
      id: 7, rt_id: "456", change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01",
      description: "Observed amendment"
    }]
  }'
}

test_feed_cursor() {
  echo -e "\n${CYAN}Suite: change-feed cursor advances only over proven coverage (#591)${NC}"
  local feed_dir feed_rc
  feed_dir=$(mktemp -d)
  feed_cursor_install "$feed_dir"

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body '{"items":[],"partial":true,"warnings":["law provider unavailable"]}'
  feed_cursor_run
  feed_cursor_check "feed partial 200 keeps cursor, warns on stderr, exits non-zero" 1 kept clean

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: true, warnings: ["law provider unavailable"], total: 1,
    items: [{id:7, rt_id:"456", change_type:"amendment", detected_at:"2026-09-02T00:00:00Z", effective_date:"2026-10-01", description:"Observed amendment"}]
  }')"
  feed_cursor_run
  feed_cursor_check "feed partial 200 flags contained items without advancing" 1 kept flagged

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body '{invalid json'
  feed_cursor_run
  feed_cursor_check "feed malformed JSON is unproven coverage" 1 kept clean

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body '{"total":0,"partial":false}'
  feed_cursor_run
  feed_cursor_check "feed schema-invalid body (items not an array) is unproven" 1 kept clean

  FEED_CODE=503 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(feed_cursor_item)"
  feed_cursor_run
  feed_cursor_check "feed non-2xx keeps cursor and does not apply the error body" 1 kept clean

  FEED_CODE=200 FEED_RC=28 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(feed_cursor_item)"
  feed_cursor_run
  feed_cursor_check "feed transport failure keeps cursor; pending flag survives" 1 kept clean

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=2 FEED_STAMP="$feed_dir/stamp"
  feed_cursor_reset
  feed_cursor_body "$(feed_cursor_item)"
  feed_cursor_run
  feed_cursor_check "feed proven page advances cursor to request-issue time" 0 issued flagged

  FEED_CODE=201 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(feed_cursor_item)"
  feed_cursor_run
  feed_cursor_check "feed HTTP 201 is proven 2xx coverage" 0 advanced flagged

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: (if . == 0 then 7 else . end),
      rt_id: (if . == 0 then "456" else "999" end),
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "page"
    }]
  }' > "$feed_dir/feed.json"
  feed_cursor_run
  feed_cursor_check "feed full page (limit 500) is unproven; contained items still flag" 1 kept flagged

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: ["law provider unavailable"], total: 1,
    items: [{id:7, rt_id:"456", change_type:"amendment", detected_at:"2026-09-02T00:00:00Z", effective_date:"2026-10-01", description:"Observed amendment"}]
  }')"
  feed_cursor_run
  feed_cursor_check "feed warnings with partial false are unproven coverage" 1 kept flagged

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 50,
    items: [{id:7, rt_id:"456", change_type:"amendment", detected_at:"2026-09-02T00:00:00Z", effective_date:"2026-10-01", description:"Observed amendment"}]
  }')"
  feed_cursor_run
  feed_cursor_check "feed short page with total greater than items is proven" 0 advanced flagged

  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  jq -n '{
    partial: false, warnings: [], total: 499,
    items: [range(499) | {
      id: (if . == 0 then 7 else . end),
      rt_id: (if . == 0 then "456" else "999" end),
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "page"
    }]
  }' > "$feed_dir/feed.json"
  feed_cursor_run
  feed_cursor_check "feed page under limit 500 is proven coverage" 0 advanced flagged

  # Order and whether `since` is inclusive are undocumented, so two full pages
  # must not move the cursor. The second mock call is the next slice; the
  # WARNING has to say the window is saturated and cannot advance.
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  FEED_BODY_FILE2="$feed_dir/feed-next.json"
  FEED_CALLS="$feed_dir/calls"
  FEED_URL_LOG="$feed_dir/urls"
  printf '0' > "$feed_dir/calls"
  : > "$feed_dir/urls"
  feed_cursor_reset
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: (if . == 0 then 7 else . end),
      rt_id: (if . == 0 then "456" else "999" end),
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "page"
    }]
  }' > "$feed_dir/feed.json"
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: (if . == 0 then 8 else (1000 + .) end),
      rt_id: (if . == 0 then "456" else "998" end),
      change_type: "amendment",
      detected_at: "2026-09-15T00:00:00Z",
      effective_date: "2026-11-01",
      description: "Next slice"
    }]
  }' > "$feed_dir/feed-next.json"
  feed_cursor_run
  sat_rc1=$feed_rc
  sat_err1=$(cat "$feed_dir/stderr")
  feed_cursor_run
  sat_ok=0
  sat_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$sat_rc1" -eq 1 ] || sat_ok=1
  [ "$feed_rc" -eq 1 ] || sat_ok=1
  [ "$sat_cursor" = "2026-09-01T00:00:00Z" ] || sat_ok=1
  grep -qF 'window is saturated and cannot advance' <<<"$sat_err1" || sat_ok=1
  grep -qF 'window is saturated and cannot advance' "$feed_dir/stderr" || sat_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || sat_ok=1
  [ "$(grep -c 'since=2026-09-01T00:00:00Z' "$feed_dir/urls")" -eq 2 ] || sat_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.feed_event_id == 8 and .change.summary == "Next slice"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || sat_ok=1
  jq -e '.entries["pending-law"] | .needs_review == true and .change.summary == "Pending review"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || sat_ok=1
  record "feed two full pages stay saturated and cannot advance" "$sat_ok" "rc1=$sat_rc1 rc2=$feed_rc cursor=$sat_cursor urls=$(tr '\n' ' ' < "$feed_dir/urls") stderr1=$(tr '\n' ' ' <<<"$sat_err1") stderr2=$(tr '\n' ' ' < "$feed_dir/stderr")"
  unset FEED_BODY_FILE2 FEED_CALLS FEED_URL_LOG

  rm -rf "$feed_dir"
}

test_feed_cursor
