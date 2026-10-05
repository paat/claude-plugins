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
    if [ -n "${CITE_FAIL_ACT:-}" ] && [[ "$url" == *"/laws/${CITE_FAIL_ACT}/citation"* ]]; then
      code=500
      body='{"error":"citation failure"}'
    elif [ "${CITE_CODE:-200}" -ne 200 ]; then
      code="${CITE_CODE:-200}"
      body='{"error":"citation failure"}'
    else
      cite_text="${CITE_TEXT:-Current clause.}"
      body="{\"text\":\"$cite_text\",\"status\":\"valid\",\"in_force\":true}"
      code=200
    fi
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
  mkdir -p "$feed_dir/.startup/laws"
  printf 'Current clause.\n' > "$feed_dir/.startup/laws/open-law.txt"
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
      CITE_CODE="${CITE_CODE:-200}" \
      CITE_TEXT="${CITE_TEXT:-}" \
      CITE_FAIL_ACT="${CITE_FAIL_ACT:-}" \
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

  # A non-object item makes the rt_id match fail. That must not become an empty
  # match that advances the cursor and drops the sibling event.
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 2,
    items: [42, {id:7, rt_id:"456", change_type:"amendment", detected_at:"2026-09-02T00:00:00Z", effective_date:"2026-10-01", description:"Observed amendment"}]
  }')"
  feed_cursor_run
  feed_cursor_check "feed items mixing a non-object with a matching event keep the cursor" 1 kept clean

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
  jq '.entries["unproved-law"] = {
    act_id: 888, rt_id: "777", citation: "§ 1",
    citation_parts: {paragraph:"1", paragraph_qualifier:"", section:"", section_qualifier:"", point:"", point_qualifier:""},
    status: "valid", verified_at: "2020-01-01T00:00:00Z",
    needs_review: false, change_detected_at: null, change: null, gh_issue_url: null
  }' "$feed_dir/.startup/law-registry.json" > "$feed_dir/.startup/law-registry.json.tmp"
  mv "$feed_dir/.startup/law-registry.json.tmp" "$feed_dir/.startup/law-registry.json"
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT=888
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
  CITE_FAIL_ACT=

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
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT=888
  printf '0' > "$feed_dir/calls"
  : > "$feed_dir/urls"
  feed_cursor_reset
  jq '.entries["unproved-law"] = {
    act_id: 888, rt_id: "777", citation: "§ 1",
    citation_parts: {paragraph:"1", paragraph_qualifier:"", section:"", section_qualifier:"", point:"", point_qualifier:""},
    status: "valid", verified_at: "2020-01-01T00:00:00Z",
    needs_review: false, change_detected_at: null, change: null, gh_issue_url: null
  }' "$feed_dir/.startup/law-registry.json" > "$feed_dir/.startup/law-registry.json.tmp"
  mv "$feed_dir/.startup/law-registry.json.tmp" "$feed_dir/.startup/law-registry.json"
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
  unset FEED_BODY_FILE2 FEED_CALLS FEED_URL_LOG CITE_FAIL_ACT

  # ---- Direct verification saturation cases (#608) ----

  # Case a: Saturated page (500 items, none matching rt_id) plus matching snapshot -> cursor advanced to issued-at time, exit 0, no incomplete coverage, not flagged
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=2 FEED_STAMP="$feed_dir/stamp"
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT=
  feed_cursor_reset
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: .,
      rt_id: "999",
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "unrelated event"
    }]
  }' > "$feed_dir/feed.json"
  feed_cursor_run
  feed_cursor_check "feed saturated page with matching snapshot advances cursor to request-issue time" 0 issued clean

  # Case b: Saturated page plus changed citation text -> slug flagged text_change, cursor advances, exit 0
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT="Changed clause text." CITE_FAIL_ACT=
  feed_cursor_reset
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: .,
      rt_id: "999",
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "unrelated event"
    }]
  }' > "$feed_dir/feed.json"
  feed_cursor_run
  sat_b_ok=0
  sat_b_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || sat_b_ok=1
  [ "$sat_b_cursor" != "2026-09-01T00:00:00Z" ] || sat_b_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && sat_b_ok=1
  grep -qF 'tsiteeritud tekst erineb hetktõmmisest' "$feed_dir/stdout" || sat_b_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "text_change" and .change.feed_event_id == null' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || sat_b_ok=1
  [ "$(cat "$feed_dir/.startup/laws/open-law.txt")" = "Current clause." ] || sat_b_ok=1
  record "feed saturated page plus changed citation text flags text_change and advances" "$sat_b_ok" "rc=$feed_rc cursor=$sat_b_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout") stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case c: Saturated page plus one failed citation fetch (non-2xx) -> cursor kept, exit 1, saturation WARNING present
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=500 CITE_TEXT= CITE_FAIL_ACT=
  feed_cursor_reset
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: .,
      rt_id: "999",
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "unrelated event"
    }]
  }' > "$feed_dir/feed.json"
  feed_cursor_run
  sat_c_ok=0
  sat_c_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || sat_c_ok=1
  [ "$sat_c_cursor" = "2026-09-01T00:00:00Z" ] || sat_c_ok=1
  grep -qF 'window is saturated and cannot advance' "$feed_dir/stderr" || sat_c_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || sat_c_ok=1
  jq -e '.entries["open-law"] | .needs_review == false and .change == null' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || sat_c_ok=1
  record "feed saturated page plus failed citation fetch keeps cursor and warns" "$sat_c_ok" "rc=$feed_rc cursor=$sat_c_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case d: Saturated page plus missing snapshot -> cursor kept, exit 1
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT=
  feed_cursor_reset
  rm -f "$feed_dir/.startup/laws/open-law.txt"
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {
      id: .,
      rt_id: "999",
      change_type: "amendment",
      detected_at: "2026-09-02T00:00:00Z",
      effective_date: "2026-10-01",
      description: "unrelated event"
    }]
  }' > "$feed_dir/feed.json"
  feed_cursor_run
  sat_d_ok=0
  sat_d_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || sat_d_ok=1
  [ "$sat_d_cursor" = "2026-09-01T00:00:00Z" ] || sat_d_ok=1
  grep -qF 'snapshot missing or unreadable' "$feed_dir/stderr" || sat_d_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || sat_d_ok=1
  record "feed saturated page plus missing snapshot keeps cursor and exits 1" "$sat_d_ok" "rc=$feed_rc cursor=$sat_d_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case e: Proven (non-saturated) page plus changed citation text -> flagged text_change, cursor advanced, exit 0
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT="Changed clause text." CITE_FAIL_ACT=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  sat_e_ok=0
  sat_e_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || sat_e_ok=1
  [ "$sat_e_cursor" != "2026-09-01T00:00:00Z" ] || sat_e_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && sat_e_ok=1
  grep -qF 'tsiteeritud tekst erineb hetktõmmisest' "$feed_dir/stdout" || sat_e_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "text_change" and .change.feed_event_id == null' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || sat_e_ok=1
  [ "$(cat "$feed_dir/.startup/laws/open-law.txt")" = "Current clause." ] || sat_e_ok=1
  record "feed proven page plus changed citation text flags text_change and advances" "$sat_e_ok" "rc=$feed_rc cursor=$sat_e_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout") stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  rm -rf "$feed_dir"
}

test_feed_cursor
