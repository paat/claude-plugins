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
    if [ -n "${CITE_URL_LOG:-}" ]; then
      printf '%s\n' "$url" >> "$CITE_URL_LOG"
    fi
    if [ -n "${CITE_FAIL_ACT:-}" ] && [[ "$url" == *"/laws/${CITE_FAIL_ACT}/citation"* ]]; then
      code=500
      body='{"error":"citation failure"}'
    elif [ "${CITE_CODE:-200}" -ne 200 ]; then
      code="${CITE_CODE:-200}"
      body='{"error":"citation failure"}'
    else
      cite_text="${CITE_TEXT:-Current clause.}"
      cite_red_id="${CITE_RED_ID:-100000000001}"
      cite_url="${CITE_URL:-https://www.riigiteataja.ee/akt/$cite_red_id}"
      if [ -n "${CITE_RED_DATE:-}" ]; then
        red_part=",\"redaktsioon_date\":\"$CITE_RED_DATE\""
      else
        red_part=""
      fi
      if [ -n "${CITE_OMIT_NEXT_DATE:-}" ]; then
        next_part=""
      elif [ -n "${CITE_NEXT_DATE:-}" ]; then
        next_part=",\"next_redaktsioon_date\":\"$CITE_NEXT_DATE\""
      else
        next_part=",\"next_redaktsioon_date\":null"
      fi
      body="{\"text\":\"$cite_text\",\"status\":\"valid\",\"in_force\":true,\"url\":\"$cite_url\"$next_part$red_part}"
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
  cat > "$dir/bin/mv" <<'MOCK_MV'
#!/usr/bin/env bash
if [ -n "${MV_FAIL_N:-}" ]; then
  calls_file="${MV_CALLS_FILE:-$(dirname "$0")/../mv_calls}"
  n=0
  if [ -f "$calls_file" ]; then
    n=$(cat "$calls_file" 2>/dev/null || echo 0)
  fi
  n=$((n + 1))
  printf '%s' "$n" > "$calls_file"
  if [ "$n" -ge "$MV_FAIL_N" ] && { [ -z "${MV_FAIL_MAX:-}" ] || [ "$n" -le "$MV_FAIL_MAX" ]; }; then
    exit 1
  fi
fi
if [ -x /usr/bin/mv ]; then
  exec /usr/bin/mv "$@"
elif [ -x /bin/mv ]; then
  exec /bin/mv "$@"
else
  command -p mv "$@"
fi
MOCK_MV
  chmod +x "$dir/bin/mv"
}

feed_cursor_reset() {
  rm -f "$feed_dir/mv_calls"
  mkdir -p "$feed_dir/.startup/laws"
  printf 'Current clause.\n' > "$feed_dir/.startup/laws/open-law.txt"
  jq -n '{
    version: 2,
    last_feed_check_at: "2026-09-01T00:00:00Z",
    entries: {
      "pending-law": {
        act_id: 1, rt_id: "111", redaktsioon_id: "100000000001", next_redaktsioon_date: null, citation: "§ 1",
        citation_parts: {paragraph:"1", paragraph_qualifier:"", section:"", section_qualifier:"", point:"", point_qualifier:""},
        status: "valid", verified_at: "2020-01-01T00:00:00Z",
        needs_review: true, change_detected_at: "2020-02-01T00:00:00Z",
        change: {feed_event_id:null, type:"lifecycle", summary:"Pending review", effective_date:null, served_redaktsioon_id:"100000000001", served_next_redaktsioon_date:null},
        gh_issue_url: "https://example.test/issues/9"
      },
      "open-law": {
        act_id: 123, rt_id: "456", redaktsioon_id: "100000000001", next_redaktsioon_date: null, citation: "§ 14 lõige 1",
        citation_parts: {paragraph:"14", paragraph_qualifier:"", section:"1", section_qualifier:"", point:"", point_qualifier:""},
        status: "valid", verified_at: "2020-01-01T00:00:00Z",
        needs_review: false, change_detected_at: null, change: null, gh_issue_url: null
      }
    }
  }' > "$feed_dir/.startup/law-registry.json"
}

# Align the flagged pending-law fixture's recorded proof with what the mock serves.
feed_cursor_pending_proof() {
  jq --arg i "$1" --arg n "$2" '.entries["pending-law"].change.served_redaktsioon_id = $i | .entries["pending-law"].change.served_next_redaktsioon_date = (if $n == "" then null else $n end)' \
    "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
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
      CITE_RED_ID="${CITE_RED_ID:-}" \
      CITE_RED_DATE="${CITE_RED_DATE:-}" \
      CITE_URL="${CITE_URL:-}" \
      CITE_NEXT_DATE="${CITE_NEXT_DATE:-}" \
      CITE_OMIT_NEXT_DATE="${CITE_OMIT_NEXT_DATE:-}" \
      CITE_URL_LOG="${CITE_URL_LOG:-}" \
      MV_FAIL_N="${MV_FAIL_N:-}" \
      MV_FAIL_MAX="${MV_FAIL_MAX:-}" \
      MV_CALLS_FILE="$feed_dir/mv_calls" \
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
    act_id: 888, rt_id: "777", redaktsioon_id: "100000000001", next_redaktsioon_date: null, citation: "§ 1",
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
    act_id: 888, rt_id: "777", redaktsioon_id: "100000000001", next_redaktsioon_date: null, citation: "§ 1",
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

  # Case f: Saturated page registry write mv failure paths (#608)
  # Assertion 1: saturated page, matching snapshot, the FIRST mv fails -> exit 1, cursor kept, registry byte-identical,
  # no law-registry.json.tmp, stderr has registry write failed and incomplete coverage, saturation sentence appears exactly once
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT=
  MV_FAIL_N=1
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
  cp "$feed_dir/.startup/law-registry.json" "$feed_dir/reg.orig"
  feed_cursor_run
  sat_f1_ok=0
  sat_f1_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || sat_f1_ok=1
  [ "$sat_f1_cursor" = "2026-09-01T00:00:00Z" ] || sat_f1_ok=1
  cmp -s "$feed_dir/.startup/law-registry.json" "$feed_dir/reg.orig" || sat_f1_ok=1
  [ ! -e "$feed_dir/.startup/law-registry.json.tmp" ] || sat_f1_ok=1
  grep -qF 'registry write failed' "$feed_dir/stderr" || sat_f1_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || sat_f1_ok=1
  [ "$(grep -c 'window is saturated and cannot advance' "$feed_dir/stderr")" -eq 1 ] || sat_f1_ok=1
  record "feed saturated page with first mv failure keeps cursor, cleans tmp, warns" "$sat_f1_ok" "rc=$feed_rc cursor=$sat_f1_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Assertion 2: saturated page, matching snapshot, only fallback mv fails (feed rewrite mv succeeds) -> exit 1,
  # cursor kept, no .tmp left, stderr has registry write failed
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT=
  MV_FAIL_N=2
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
  sat_f2_ok=0
  sat_f2_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || sat_f2_ok=1
  [ "$sat_f2_cursor" = "2026-09-01T00:00:00Z" ] || sat_f2_ok=1
  [ ! -e "$feed_dir/.startup/law-registry.json.tmp" ] || sat_f2_ok=1
  grep -qF 'registry write failed' "$feed_dir/stderr" || sat_f2_ok=1
  record "feed saturated page with fallback mv failure keeps cursor, cleans tmp, warns" "$sat_f2_ok" "rc=$feed_rc cursor=$sat_f2_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"
  unset MV_FAIL_N

  # Case A: Saturated page, text equal, served id changed -> redaction_change flagged, snapshot unchanged, cursor advanced, exit 0 (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="100000000002" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
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
  test_a_ok=0
  test_a_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_a_ok=1
  [ "$test_a_cursor" != "2026-09-01T00:00:00Z" ] || test_a_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_a_ok=1
  grep -qF 'WARNING: open-law: akti redaktsioon muutus (100000000001 -> 100000000002) — märgitud läbivaatamiseks' "$feed_dir/stdout" || test_a_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "redaction_change" and .change.feed_event_id == null' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_a_ok=1
  [ "$(cat "$feed_dir/.startup/laws/open-law.txt")" = "Current clause." ] || test_a_ok=1
  record "feed saturated page with served redaction id changed flags redaction_change and advances" "$test_a_ok" "rc=$feed_rc cursor=$test_a_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout") stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case B: Saturated page, text and id equal, next_redaktsioon_date set -> future_amendment flagged with effective_date = that date; cursor advanced (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
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
  test_b_ok=0
  test_b_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_b_ok=1
  [ "$test_b_cursor" != "2026-09-01T00:00:00Z" ] || test_b_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_b_ok=1
  grep -qF 'WARNING: open-law: aktile on avaldatud tulevane redaktsioon (jõustub 2026-11-01) — märgitud läbivaatamiseks' "$feed_dir/stdout" || test_b_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "future_amendment" and .change.effective_date == "2026-11-01"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_b_ok=1
  [ "$(cat "$feed_dir/.startup/laws/open-law.txt")" = "Current clause." ] || test_b_ok=1
  record "feed saturated page with next_redaktsioon_date flags future_amendment and advances" "$test_b_ok" "rc=$feed_rc cursor=$test_b_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout") stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case C: Saturated page, stored redaktsioon_id null -> cursor advanced, exit 1, stderr names the slug and /lawyer ack (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].redaktsioon_id = null' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
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
  test_c_ok=0
  test_c_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || test_c_ok=1
  [ "$test_c_cursor" != "2026-09-01T00:00:00Z" ] || test_c_ok=1
  grep -qF 'open-law' "$feed_dir/stderr" || test_c_ok=1
  grep -qF '/lawyer ack open-law' "$feed_dir/stderr" || test_c_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || test_c_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_c_ok=1
  record "feed saturated page with stored redaktsioon_id null advances cursor and warns" "$test_c_ok" "rc=$feed_rc cursor=$test_c_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Cases #613: a legacy entry adopts the served redaction id only when the stored redaktsioon_date equals the served one
  jq -n '{
    partial: false, warnings: [], total: 500,
    items: [range(500) | {id: ., rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated event"}]
  }' > "$feed_dir/sat613.json"
  adopt_reg() {
    feed_cursor_reset
    feed_cursor_pending_proof "$CITE_RED_ID" ""
    jq --arg i "$1" --arg d "$2" '.entries["open-law"].redaktsioon_id = (if $i == "" then null else $i end) | .entries["open-law"].redaktsioon_date = (if $d == "" then null else $d end)' \
      "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
    cp "$feed_dir/sat613.json" "$feed_dir/feed.json"
  }
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=

  # a: equal dates -> adopt, exit 0, cursor advanced
  CITE_RED_ID="100000000009" CITE_RED_DATE="2026-03-01"
  adopt_reg 456 "2026-03-01"
  feed_cursor_run
  t613a_ok=0
  [ "$feed_rc" -eq 0 ] || t613a_ok=1
  [ "$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json")" != "2026-09-01T00:00:00Z" ] || t613a_ok=1
  jq -e '.entries["open-law"] | .redaktsioon_id == "100000000009" and .needs_review == false and .change == null and .verified_at == "2020-01-01T00:00:00Z"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613a_ok=1
  ! grep -qF 'akti redaktsiooni ei saa tõendada' "$feed_dir/stderr" || t613a_ok=1
  record "feed saturated legacy entry with equal redaktsioon_date adopts served id and advances (#613)" "$t613a_ok" "rc=$feed_rc stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # b: different dates -> no adoption, WARNING
  CITE_RED_ID="100000000009" CITE_RED_DATE="2026-09-15"
  adopt_reg 456 "2026-03-01"
  feed_cursor_run
  t613b_ok=0
  [ "$feed_rc" -eq 1 ] || t613b_ok=1
  grep -qF 'akti redaktsiooni ei saa tõendada' "$feed_dir/stderr" || t613b_ok=1
  jq -e '.entries["open-law"].redaktsioon_id == "456"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613b_ok=1
  record "feed saturated legacy entry with different redaktsioon_date is not adopted (#613)" "$t613b_ok" "rc=$feed_rc stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # c: stored date null -> non-saturated run then saturated run never adopt
  CITE_RED_ID="100000000009" CITE_RED_DATE="2026-03-01"
  adopt_reg 456 ""
  feed_cursor_body '{"items":[],"partial":false,"warnings":[]}'
  feed_cursor_run
  t613c_ok=0
  [ "$feed_rc" -eq 0 ] || t613c_ok=1
  jq -e '.entries["open-law"].redaktsioon_id == "456"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613c_ok=1
  cp "$feed_dir/sat613.json" "$feed_dir/feed.json"
  feed_cursor_run
  [ "$feed_rc" -eq 1 ] || t613c_ok=1
  grep -qF 'akti redaktsiooni ei saa tõendada' "$feed_dir/stderr" || t613c_ok=1
  jq -e '.entries["open-law"].redaktsioon_id == "456"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613c_ok=1
  record "feed legacy entry with null redaktsioon_date is never adopted across runs (#613)" "$t613c_ok" "rc=$feed_rc stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # d: served id equals rt_id -> no adoption
  CITE_RED_ID="456" CITE_RED_DATE="2026-03-01"
  adopt_reg 456 "2026-03-01"
  feed_cursor_run
  t613d_ok=0
  [ "$feed_rc" -eq 1 ] || t613d_ok=1
  grep -qF 'akti redaktsiooni ei saa tõendada' "$feed_dir/stderr" || t613d_ok=1
  jq -e '.entries["open-law"].redaktsioon_id == "456"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613d_ok=1
  record "feed legacy entry whose served id equals rt_id is not adopted (#613)" "$t613d_ok" "rc=$feed_rc stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # e: adoption write fails -> exit 1, cursor kept, no .tmp
  CITE_RED_ID="100000000009" CITE_RED_DATE="2026-03-01"
  adopt_reg 456 "2026-03-01"
  MV_FAIL_N=2 MV_FAIL_MAX=2
  feed_cursor_run
  unset MV_FAIL_N MV_FAIL_MAX
  t613e_ok=0
  [ "$feed_rc" -eq 1 ] || t613e_ok=1
  [ "$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json")" = "2026-09-01T00:00:00Z" ] || t613e_ok=1
  [ ! -e "$feed_dir/.startup/law-registry.json.tmp" ] || t613e_ok=1
  jq -e '.entries["open-law"].redaktsioon_id == "456"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613e_ok=1
  grep -qF 'open-law: registry write failed' "$feed_dir/stderr" || t613e_ok=1
  record "feed legacy adoption write failure keeps cursor and cleans tmp (#613)" "$t613e_ok" "rc=$feed_rc stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # f: stored id null, equal dates -> adopt, exit 0, cursor advanced
  CITE_RED_ID="100000000009" CITE_RED_DATE="2026-03-01"
  adopt_reg "" "2026-03-01"
  feed_cursor_run
  t613f_ok=0
  [ "$feed_rc" -eq 0 ] || t613f_ok=1
  [ "$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json")" != "2026-09-01T00:00:00Z" ] || t613f_ok=1
  jq -e '.entries["open-law"].redaktsioon_id == "100000000009"' "$feed_dir/.startup/law-registry.json" >/dev/null || t613f_ok=1
  ! grep -qF 'akti redaktsiooni ei saa tõendada' "$feed_dir/stderr" || t613f_ok=1
  record "feed saturated null-id entry with equal redaktsioon_date adopts served id (#613)" "$t613f_ok" "rc=$feed_rc stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"
  CITE_RED_ID= CITE_RED_DATE=

  # Case D1: Saturated page, stored id equals rt_id -> cursor advanced, exit 1 (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].redaktsioon_id = "456"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
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
  test_d1_ok=0
  test_d1_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || test_d1_ok=1
  [ "$test_d1_cursor" != "2026-09-01T00:00:00Z" ] || test_d1_ok=1
  grep -qF 'open-law' "$feed_dir/stderr" || test_d1_ok=1
  grep -qF 'stored redaktsioon_id missing or not redaction-unique — run /lawyer ack open-law' "$feed_dir/stderr" || test_d1_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || test_d1_ok=1
  record "feed saturated page with stored id equals rt_id advances cursor and warns" "$test_d1_ok" "rc=$feed_rc cursor=$test_d1_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case D2: Saturated page, served URL id equals rt_id -> cursor advanced, exit 1 (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="456" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
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
  test_d2_ok=0
  test_d2_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || test_d2_ok=1
  [ "$test_d2_cursor" != "2026-09-01T00:00:00Z" ] || test_d2_ok=1
  grep -qF 'open-law' "$feed_dir/stderr" || test_d2_ok=1
  grep -qF 'served citation URL has no redaction-unique id — review the act manually' "$feed_dir/stderr" || test_d2_ok=1
  grep -qF '/lawyer ack' "$feed_dir/stderr" && test_d2_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || test_d2_ok=1
  record "feed saturated page with served URL id equals rt_id advances cursor and warns" "$test_d2_ok" "rc=$feed_rc cursor=$test_d2_cursor stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case D3: EUR-Lex served URL has no redaction-unique id, two consecutive saturated runs each exit 1 and advance cursor (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL="https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32016R0679" CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
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
  test_d3_ok=0
  test_d3_cursor1=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || test_d3_ok=1
  [ "$test_d3_cursor1" != "2026-09-01T00:00:00Z" ] || test_d3_ok=1
  grep -qF 'open-law' "$feed_dir/stderr" || test_d3_ok=1
  grep -qF 'served citation URL has no redaction-unique id — review the act manually' "$feed_dir/stderr" || test_d3_ok=1
  grep -qF '/lawyer ack' "$feed_dir/stderr" && test_d3_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || test_d3_ok=1

  # Second consecutive saturated run
  sleep 1
  feed_cursor_run
  test_d3_cursor2=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || test_d3_ok=1
  [ "$test_d3_cursor2" != "$test_d3_cursor1" ] || test_d3_ok=1
  grep -qF 'open-law' "$feed_dir/stderr" || test_d3_ok=1
  grep -qF 'served citation URL has no redaction-unique id — review the act manually' "$feed_dir/stderr" || test_d3_ok=1
  grep -qF '/lawyer ack' "$feed_dir/stderr" && test_d3_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || test_d3_ok=1
  record "feed EUR-Lex served URL two consecutive saturated runs each exit 1 and advance cursor" "$test_d3_ok" "rc=$feed_rc cursor1=$test_d3_cursor1 cursor2=$test_d3_cursor2"

  # Case E: Saturated page, key next_redaktsioon_date omitted, everything else proven -> cursor advanced, exit 0, stdout has the NOTE line (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=1
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
  test_e_ok=0
  test_e_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_e_ok=1
  [ "$test_e_cursor" != "2026-09-01T00:00:00Z" ] || test_e_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_e_ok=1
  grep -qF 'NOTE: muudatuste aken oli küllastunud; tulevaste redaktsioonide etteteatamist ei saa täielikult tõendada (/citation ei tagasta next_redaktsioon_date või tagastab ainult varaseima)' "$feed_dir/stdout" || test_e_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_e_ok=1
  record "feed saturated page with omitted next_redaktsioon_date advances with NOTE" "$test_e_ok" "rc=$feed_rc cursor=$test_e_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case F1: Non-saturated proven page, served id changed -> redaction_change flagged, cursor advanced, exit 0 (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="100000000002" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_f1_ok=0
  test_f1_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_f1_ok=1
  [ "$test_f1_cursor" != "2026-09-01T00:00:00Z" ] || test_f1_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_f1_ok=1
  grep -qF 'WARNING: open-law: akti redaktsioon muutus (100000000001 -> 100000000002) — märgitud läbivaatamiseks' "$feed_dir/stdout" || test_f1_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "redaction_change" and .change.feed_event_id == null' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_f1_ok=1
  record "feed proven page with served redaction id changed flags redaction_change and advances" "$test_f1_ok" "rc=$feed_rc cursor=$test_f1_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case F1b: Redaction change with new next_redaktsioon_date names it in summary; without next date omits it (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="100000000002" CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_f1b_ok=0
  [ "$feed_rc" -eq 0 ] || test_f1b_ok=1
  [ "$(jq '[.entries[] | select(.needs_review == true)] | length' "$feed_dir/.startup/law-registry.json")" -eq 2 ] || test_f1b_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "redaction_change" and (.change.summary | contains("jõustub 2026-11-01"))' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_f1b_ok=1

  # Plus the same without a next date -> summary has no jõustub
  CITE_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  [ "$feed_rc" -eq 0 ] || test_f1b_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "redaction_change" and (.change.summary | contains("jõustub") | not)' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_f1b_ok=1
  record "feed redaction_change names new next redaction date in summary and omits without one" "$test_f1b_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case F1c: Text change with new next_redaktsioon_date names it in summary (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT="Changed clause text." CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_f1c_ok=0
  [ "$feed_rc" -eq 0 ] || test_f1c_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "text_change" and (.change.summary | contains("jõustub 2026-11-01"))' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_f1c_ok=1
  record "feed text_change names new next redaction date in summary" "$test_f1c_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case F2: Non-saturated page with stored id null -> no flag, no new warning, exit 0 (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].redaktsioon_id = null' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_f2_ok=0
  test_f2_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_f2_ok=1
  [ "$test_f2_cursor" != "2026-09-01T00:00:00Z" ] || test_f2_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_f2_ok=1
  grep -qF 'WARNING:' "$feed_dir/stdout" && test_f2_ok=1
  grep -qF 'WARNING:' "$feed_dir/stderr" && test_f2_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_f2_ok=1
  record "feed proven page with stored id null does not flag and advances" "$test_f2_ok" "rc=$feed_rc cursor=$test_f2_cursor"

  # Case G: The served next date equals the stored one -> no flag (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_pending_proof 100000000001 2026-11-01
  jq '.entries["open-law"].next_redaktsioon_date = "2026-11-01"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
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
  test_g_ok=0
  test_g_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_g_ok=1
  [ "$test_g_cursor" != "2026-09-01T00:00:00Z" ] || test_g_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_g_ok=1
  grep -qF 'WARNING:' "$feed_dir/stdout" && test_g_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_g_ok=1
  record "feed saturated page with matching next date does not flag" "$test_g_ok" "rc=$feed_rc cursor=$test_g_cursor"

  # Case G2: Saturated page, matching next date -> cursor advanced, exit 0, stdout has the NOTE line (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].next_redaktsioon_date = "2026-11-01"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
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
  test_g2_ok=0
  test_g2_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_g2_ok=1
  [ "$test_g2_cursor" != "2026-09-01T00:00:00Z" ] || test_g2_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_g2_ok=1
  grep -qF 'NOTE: muudatuste aken oli küllastunud; tulevaste redaktsioonide etteteatamist ei saa täielikult tõendada (/citation ei tagasta next_redaktsioon_date või tagastab ainult varaseima)' "$feed_dir/stdout" || test_g2_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_g2_ok=1
  record "feed saturated page with matching next date advances with NOTE" "$test_g2_ok" "rc=$feed_rc cursor=$test_g2_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case H1: Non-saturated proven page, stored redaktsioon_id null, served next_redaktsioon_date new -> future_amendment flagged, exit 0, cursor advanced (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].redaktsioon_id = null' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_h1_ok=0
  test_h1_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 0 ] || test_h1_ok=1
  [ "$test_h1_cursor" != "2026-09-01T00:00:00Z" ] || test_h1_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_h1_ok=1
  grep -qF 'WARNING: open-law: aktile on avaldatud tulevane redaktsioon (jõustub 2026-11-01) — märgitud läbivaatamiseks' "$feed_dir/stdout" || test_h1_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "future_amendment" and .change.effective_date == "2026-11-01"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_h1_ok=1
  record "feed proven page with stored redaktsioon_id null flags future_amendment and advances" "$test_h1_ok" "rc=$feed_rc cursor=$test_h1_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case H2: Saturated page, stored redaktsioon_id null, served next_redaktsioon_date new -> future_amendment flagged, cursor ADVANCED, exit 1, stderr names slug and /lawyer ack (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_URL= CITE_NEXT_DATE="2026-11-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].redaktsioon_id = null' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
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
  test_h2_ok=0
  test_h2_cursor=$(jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json" 2>/dev/null || echo "<missing>")
  [ "$feed_rc" -eq 1 ] || test_h2_ok=1
  [ "$test_h2_cursor" != "2026-09-01T00:00:00Z" ] || test_h2_ok=1
  grep -qF 'open-law' "$feed_dir/stderr" || test_h2_ok=1
  grep -qF '/lawyer ack open-law' "$feed_dir/stderr" || test_h2_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" || test_h2_ok=1
  grep -qF 'WARNING: open-law: aktile on avaldatud tulevane redaktsioon (jõustub 2026-11-01) — märgitud läbivaatamiseks' "$feed_dir/stdout" || test_h2_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "future_amendment" and .change.effective_date == "2026-11-01"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_h2_ok=1
  record "feed saturated page with stored redaktsioon_id null flags future_amendment and advances" "$test_h2_ok" "rc=$feed_rc cursor=$test_h2_cursor stdout=$(tr '\n' ' ' < "$feed_dir/stdout") stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # Case I1 (T-001): stored future redaction date withdrawn (served null) -> future_amendment flagged, effective_date null, summary contains stored date
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_RED_DATE="2026-01-01" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].next_redaktsioon_date = "2099-01-01"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_i1_ok=0
  [ "$feed_rc" -eq 0 ] || test_i1_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "future_amendment" and .change.effective_date == null and (.change.summary | contains("2099-01-01"))' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_i1_ok=1
  record "feed withdrawn future redaction flags future_amendment with null effective_date" "$test_i1_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case I2: withdrawn with stored 2020-06-01, served redaktsioon_date 2020-01-01, served next null -> future_amendment, effective_date null (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_RED_DATE="2020-01-01" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].next_redaktsioon_date = "2020-06-01"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_i2_ok=0
  [ "$feed_rc" -eq 0 ] || test_i2_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "future_amendment" and .change.effective_date == null and (.change.summary | contains("2020-06-01"))' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_i2_ok=1
  record "feed withdrawn future redaction with passed date flags future_amendment" "$test_i2_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case I2b: took effect: stored 2020-06-01, served redaktsioon_date 2020-06-01, served next null -> no flag (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID= CITE_RED_DATE="2020-06-01" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].next_redaktsioon_date = "2020-06-01"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_i2b_ok=0
  [ "$feed_rc" -eq 0 ] || test_i2b_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_i2b_ok=1
  record "feed next redaction took effect with matching served date does not flag" "$test_i2b_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Case I3 (T-001): cited text changed and stored future date withdrawn -> text_change summary contains ei ole enam avaldatud
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT="Changed clause text." CITE_FAIL_ACT= CITE_RED_ID= CITE_RED_DATE="2026-01-01" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].next_redaktsioon_date = "2099-01-01"' "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  feed_cursor_body "$(jq -n '{
    partial: false, warnings: [], total: 1,
    items: [{id: 7, rt_id: "999", change_type: "amendment", detected_at: "2026-09-02T00:00:00Z", effective_date: "2026-10-01", description: "unrelated"}]
  }')"
  feed_cursor_run
  test_i3_ok=0
  [ "$feed_rc" -eq 0 ] || test_i3_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "text_change" and (.change.summary | contains("ei ole enam avaldatud"))' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_i3_ok=1
  record "feed text_change with withdrawn future redaction notes it in summary" "$test_i3_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout")"

  # Ack case: after ack, redaktsioon_id and next_redaktsioon_date equal served values, next check flags nothing (#610)
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="100000000099" CITE_URL= CITE_NEXT_DATE="2026-12-01" CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_pending_proof 100000000099 2026-12-01
  jq '.entries["open-law"].needs_review = true | .entries["open-law"].change = {feed_event_id:null, type:"redaction_change", summary:"flagged", effective_date:null}' \
    "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  ack_rc=0
  (
    cd "$feed_dir" && PATH="$feed_dir/bin:$PATH" \
      EST_DATALAKE_API_KEY=synthetic-key \
      DATALAKE_URL=https://example.invalid \
      CITE_CODE=200 \
      CITE_TEXT="Current clause." \
      CITE_RED_ID="100000000099" \
      CITE_NEXT_DATE="2026-12-01" \
      bash "$PLUGIN_ROOT/scripts/lawyer-ack.sh" open-law
  ) > "$feed_dir/stdout_ack" 2> "$feed_dir/stderr_ack" || ack_rc=$?
  test_ack_ok=0
  [ "$ack_rc" -eq 0 ] || test_ack_ok=1
  jq -e '.entries["open-law"] | .needs_review == false and .change == null and .redaktsioon_id == "100000000099" and .next_redaktsioon_date == "2026-12-01"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_ack_ok=1
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
  [ "$feed_rc" -eq 0 ] || test_ack_ok=1
  grep -qF 'WARNING:' "$feed_dir/stdout" && test_ack_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && test_ack_ok=1
  jq -e '.entries["open-law"].needs_review == false' "$feed_dir/.startup/law-registry.json" >/dev/null || test_ack_ok=1
  record "lawyer ack refreshes redaktsioon_id and next_redaktsioon_date and check flags nothing" "$test_ack_ok" "ack_rc=$ack_rc check_rc=$feed_rc"

  # Ack case 2 (T-003): ack with key omitted keeps a stored 2099-01-01
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="100000000001" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=1
  feed_cursor_reset
  jq '.entries["open-law"].needs_review = true | .entries["open-law"].next_redaktsioon_date = "2099-01-01"' \
    "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  ack_rc2=0
  (
    cd "$feed_dir" && PATH="$feed_dir/bin:$PATH" \
      EST_DATALAKE_API_KEY=synthetic-key \
      DATALAKE_URL=https://example.invalid \
      CITE_CODE=200 \
      CITE_TEXT="Current clause." \
      CITE_RED_ID="100000000001" \
      CITE_NEXT_DATE= \
      CITE_OMIT_NEXT_DATE=1 \
      bash "$PLUGIN_ROOT/scripts/lawyer-ack.sh" open-law
  ) > "$feed_dir/stdout_ack2" 2> "$feed_dir/stderr_ack2" || ack_rc2=$?
  test_ack_omit_ok=0
  [ "$ack_rc2" -eq 0 ] || test_ack_omit_ok=1
  jq -e '.entries["open-law"] | .needs_review == false and .next_redaktsioon_date == "2099-01-01"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_ack_omit_ok=1
  record "lawyer ack with omitted next_redaktsioon_date key keeps stored date" "$test_ack_omit_ok" "ack_rc=$ack_rc2"

  # Ack case 3 (T-003): ack with an explicit null writes null
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_ID="100000000001" CITE_URL= CITE_NEXT_DATE= CITE_OMIT_NEXT_DATE=
  feed_cursor_reset
  jq '.entries["open-law"].needs_review = true | .entries["open-law"].next_redaktsioon_date = "2099-01-01"' \
    "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  ack_rc3=0
  (
    cd "$feed_dir" && PATH="$feed_dir/bin:$PATH" \
      EST_DATALAKE_API_KEY=synthetic-key \
      DATALAKE_URL=https://example.invalid \
      CITE_CODE=200 \
      CITE_TEXT="Current clause." \
      CITE_RED_ID="100000000001" \
      CITE_NEXT_DATE= \
      CITE_OMIT_NEXT_DATE= \
      bash "$PLUGIN_ROOT/scripts/lawyer-ack.sh" open-law
  ) > "$feed_dir/stdout_ack3" 2> "$feed_dir/stderr_ack3" || ack_rc3=$?
  test_ack_null_ok=0
  [ "$ack_rc3" -eq 0 ] || test_ack_null_ok=1
  jq -e '.entries["open-law"] | .needs_review == false and .next_redaktsioon_date == null' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || test_ack_null_ok=1
  record "lawyer ack with explicit null next_redaktsioon_date writes null" "$test_ack_null_ok" "ack_rc=$ack_rc3"

  # ---- #612: a flagged entry on a saturated window is proven only by its recorded served state ----
  reg612() {
    jq "$@" "$feed_dir/.startup/law-registry.json" > "$feed_dir/reg.tmp" && mv "$feed_dir/reg.tmp" "$feed_dir/.startup/law-registry.json"
  }
  sat612() {
    reg612 '.last_feed_check_at = "2026-09-01T00:00:00Z"'
    cp "$feed_dir/sat613.json" "$feed_dir/feed.json"
    feed_cursor_run
  }
  cursor612() { jq -r '.last_feed_check_at' "$feed_dir/.startup/law-registry.json"; }
  open612() { jq -c '.entries["open-law"].change' "$feed_dir/.startup/law-registry.json"; }
  # Run 1: saturated, flags open-law future_amendment with recorded proof.
  flag612() {
    CITE_RED_ID= CITE_NEXT_DATE="2026-11-01"
    feed_cursor_reset
    feed_cursor_pending_proof 100000000001 2026-11-01
    sat612
  }
  FEED_CODE=200 FEED_RC=0 FEED_SLEEP=0 FEED_STAMP=
  CITE_CODE=200 CITE_TEXT= CITE_FAIL_ACT= CITE_RED_DATE= CITE_URL= CITE_OMIT_NEXT_DATE=

  # a: run 2 serves a new redaction id -> redaction_change re-flag keeps the future_amendment in previous
  flag612
  t612a_ok=0
  [ "$feed_rc" -eq 0 ] || t612a_ok=1
  jq -e '.entries["open-law"].change | .type == "future_amendment" and .served_redaktsioon_id == "100000000001" and .served_next_redaktsioon_date == "2026-11-01" and (has("previous") | not)' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || t612a_ok=1
  CITE_RED_ID="100000000002"
  sat612
  [ "$feed_rc" -eq 0 ] || t612a_ok=1
  [ "$(cursor612)" != "2026-09-01T00:00:00Z" ] || t612a_ok=1
  grep -qF 'WARNING: open-law: akti redaktsioon muutus (100000000001 -> 100000000002) — märgitud läbivaatamiseks' "$feed_dir/stdout" || t612a_ok=1
  jq -e '.entries["open-law"] | .needs_review == true and .change.type == "redaction_change" and .change.served_redaktsioon_id == "100000000002"
    and (.change.previous | length) == 1 and .change.previous[0].type == "future_amendment" and (.change.previous[0] | has("previous") | not)' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || t612a_ok=1
  record "feed saturated flagged entry with new served redaction id is re-flagged with previous (#612)" "$t612a_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout") change=$(open612)"

  # b: run 2 serves a different next date, same id -> future_amendment re-flag with previous
  flag612
  CITE_NEXT_DATE="2026-10-15"
  sat612
  t612b_ok=0
  [ "$feed_rc" -eq 0 ] || t612b_ok=1
  grep -qF 'WARNING: open-law: aktile on avaldatud tulevane redaktsioon (jõustub 2026-10-15)' "$feed_dir/stdout" || t612b_ok=1
  jq -e '.entries["open-law"].change | .type == "future_amendment" and .effective_date == "2026-10-15" and .served_next_redaktsioon_date == "2026-10-15"
    and (.previous | length) == 1 and .previous[0].effective_date == "2026-11-01"' \
    "$feed_dir/.startup/law-registry.json" >/dev/null || t612b_ok=1
  record "feed saturated flagged entry with new next date is re-flagged future_amendment (#612)" "$t612b_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout") change=$(open612)"

  # c: run 2 with nothing changed -> proven, cursor advanced, change untouched
  flag612
  t612c_before=$(open612)
  sat612
  t612c_ok=0
  [ "$feed_rc" -eq 0 ] || t612c_ok=1
  [ "$(cursor612)" != "2026-09-01T00:00:00Z" ] || t612c_ok=1
  [ "$(open612)" = "$t612c_before" ] || t612c_ok=1
  grep -qF 'WARNING:' "$feed_dir/stdout" && t612c_ok=1
  grep -qF 'incomplete coverage' "$feed_dir/stderr" && t612c_ok=1
  record "feed saturated flagged entry with unchanged served state is proven (#612)" "$t612c_ok" "rc=$feed_rc stdout=$(tr '\n' ' ' < "$feed_dir/stdout") stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # d: legacy/feed flag with no recorded proof -> exit 1, cursor advanced, WARNING names the slug, change untouched
  CITE_RED_ID= CITE_NEXT_DATE=
  feed_cursor_reset
  reg612 '.entries["open-law"].needs_review = true | .entries["open-law"].change = {feed_event_id: 7, type: "amendment", summary: "legacy", effective_date: null}'
  t612d_before=$(open612)
  sat612
  t612d_ok=0
  [ "$feed_rc" -eq 1 ] || t612d_ok=1
  [ "$(cursor612)" != "2026-09-01T00:00:00Z" ] || t612d_ok=1
  grep -qF 'WARNING: open-law: akti redaktsiooni ei saa tõendada (pending-review entry has no recorded redaction — run /lawyer ack open-law after review)' "$feed_dir/stderr" || t612d_ok=1
  [ "$(open612)" = "$t612d_before" ] || t612d_ok=1
  record "feed saturated flagged entry without recorded redaction exits 1 and names the slug (#612)" "$t612d_ok" "rc=$feed_rc cursor=$(cursor612) stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # e: flagged entry whose /citation fails -> cursor kept, exit 1
  flag612
  CITE_FAIL_ACT=123
  sat612
  CITE_FAIL_ACT=
  t612e_ok=0
  [ "$feed_rc" -eq 1 ] || t612e_ok=1
  [ "$(cursor612)" = "2026-09-01T00:00:00Z" ] || t612e_ok=1
  grep -qF 'WARNING: open-law: citation lifecycle unknown' "$feed_dir/stderr" || t612e_ok=1
  record "feed saturated flagged entry with failed citation keeps cursor (#612)" "$t612e_ok" "rc=$feed_rc cursor=$(cursor612) stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"

  # f: future_amendment flagged on a legacy stored id records no served id; the next saturated run cannot prove it
  for t612f_id in "" 456; do
    CITE_RED_ID= CITE_NEXT_DATE="2026-11-01"
    feed_cursor_reset
    feed_cursor_pending_proof 100000000001 2026-11-01
    reg612 --arg i "$t612f_id" '.entries["open-law"].redaktsioon_id = (if $i == "" then null else $i end)'
    sat612
    t612f_ok=0
    jq -e '.entries["open-law"].change | .type == "future_amendment" and .served_redaktsioon_id == null and .served_next_redaktsioon_date == "2026-11-01"' \
      "$feed_dir/.startup/law-registry.json" >/dev/null || t612f_ok=1
    sat612
    [ "$feed_rc" -eq 1 ] || t612f_ok=1
    [ "$(cursor612)" != "2026-09-01T00:00:00Z" ] || t612f_ok=1
    grep -qF 'WARNING: open-law: akti redaktsiooni ei saa tõendada (pending-review entry has no recorded redaction' "$feed_dir/stderr" || t612f_ok=1
    record "feed future_amendment on legacy stored id '${t612f_id:-null}' records no id and stays unprovable (#612)" "$t612f_ok" "rc=$feed_rc change=$(open612) stderr=$(tr '\n' ' ' < "$feed_dir/stderr")"
  done

  # g: a non-saturated run never fetches /citation for flagged entries
  CITE_RED_ID= CITE_NEXT_DATE=
  feed_cursor_reset
  rm -f "$feed_dir/cite_urls"
  feed_cursor_body '{"items":[],"partial":false,"warnings":[]}'
  CITE_URL_LOG="$feed_dir/cite_urls"
  feed_cursor_run
  CITE_URL_LOG=
  t612g_ok=0
  [ "$feed_rc" -eq 0 ] || t612g_ok=1
  grep -qF '/laws/123/citation' "$feed_dir/cite_urls" || t612g_ok=1
  grep -qF '/laws/1/citation' "$feed_dir/cite_urls" && t612g_ok=1
  record "feed non-saturated run makes no citation call for flagged entries (#612)" "$t612g_ok" "rc=$feed_rc urls=$(tr '\n' ' ' < "$feed_dir/cite_urls" 2>/dev/null)"

  # h: re-flagged redaction_change then ack -> change null, previous gone
  CITE_RED_ID="100000000002" CITE_NEXT_DATE=
  feed_cursor_reset
  feed_cursor_pending_proof 100000000002 ""
  sat612
  CITE_RED_ID="100000000003"
  feed_cursor_pending_proof 100000000003 ""
  sat612
  t612h_ok=0
  jq -e '.entries["open-law"].change | .type == "redaction_change" and (.previous | length) == 1' "$feed_dir/.startup/law-registry.json" >/dev/null || t612h_ok=1
  (
    cd "$feed_dir" && PATH="$feed_dir/bin:$PATH" \
      EST_DATALAKE_API_KEY=synthetic-key \
      DATALAKE_URL=https://example.invalid \
      CITE_CODE=200 \
      CITE_TEXT="Current clause." \
      CITE_RED_ID="100000000003" \
      bash "$PLUGIN_ROOT/scripts/lawyer-ack.sh" open-law
  ) > "$feed_dir/stdout_ack612" 2> "$feed_dir/stderr_ack612" || t612h_ok=1
  jq -e '.entries["open-law"] | .needs_review == false and .change == null' "$feed_dir/.startup/law-registry.json" >/dev/null || t612h_ok=1
  record "lawyer ack clears a re-flagged change including previous (#612)" "$t612h_ok" "change=$(open612) stderr=$(tr '\n' ' ' < "$feed_dir/stderr_ack612")"
  CITE_RED_ID=

  rm -rf "$feed_dir"
}

test_feed_cursor
