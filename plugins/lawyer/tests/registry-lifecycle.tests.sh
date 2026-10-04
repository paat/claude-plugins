# Sourced by run-tests.sh: law-registry lifecycle guard (in_force / status).
# A 200 + text from /laws/{act_id}/citation does NOT mean the law is in force;
# these run scripts/lawyer-*.sh against a mock curl.

# Install a mock `curl` under $1/bin that answers datalake calls from env vars
# FAKE_GRAPH / FAKE_CITATION / FAKE_FEED. Emits a trailing HTTP-code line only
# when the caller passed -w (matching the command body's `-w '\n%{http_code}'`).
make_mock_curl() {
  local bindir="$1/bin"
  mkdir -p "$bindir"
  cat > "$bindir/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
emit_code=0
for a in "$@"; do [ "$a" = "-w" ] && emit_code=1; done
case "$url" in
  *"/graph"*)        body="$FAKE_GRAPH" ;;
  *"/citation"*)     body="$FAKE_CITATION" ;;
  *"/changes/feed"*) body="$FAKE_FEED" ;;
  *)                 body="{}" ;;
esac
[ -n "$body" ] || body="{}"
if [ "$emit_code" = 1 ]; then printf '%s\n%s' "$body" "${FAKE_CODE:-200}"; else printf '%s' "$body"; fi
MOCK
  chmod +x "$bindir/curl"
}

test_lawyer_lifecycle() {
  echo -e "\n${CYAN}Suite V: /lawyer lifecycle guard (in_force/status)${NC}"
  local skill="$PLUGIN_ROOT/skills/lawyer/SKILL.md"
  local ref="$PLUGIN_ROOT/references/law-registry.md"
  local scr="$PLUGIN_ROOT/scripts"
  local reg="$scr/lawyer-register.sh"
  local chk="$scr/lawyer-check.sh"
  local ackscr="$scr/lawyer-ack.sh"
  local ackall="$scr/lawyer-ack-all.sh"
  local workdir ec output has

  # --- Spec assertions: guard present on each script + docs ---
  assert_file_contains "V1: register uses shared lifecycle classification" "$reg" 'lawyer_fetch_citation'
  assert_file_contains "V2: register refuses non-valid (message)" "$reg" "not in force"
  assert_file_contains "V3: register honours --force" "$reg" 'FORCE=1'
  assert_file_contains "V4: change detection lifecycle re-check" "$chk" 'lawyer_fetch_citation'
  assert_file_contains "V5: check lifecycle re-check" "$chk" 'elutsükli-kontrolliga'
  assert_file_contains "V6: ack refuses non-valid" "$ackscr" 'Refusing to ack'
  assert_file_contains "V7: ack-all skips non-valid" "$ackall" 'flag kept'
  assert_file_contains "V8: SKILL documents in_force/status" "$skill" 'in_force'
  assert_file_contains "V9: SKILL workflow 200 caution" "$skill" 'A 200 does not mean the law is in force'
  assert_file_contains "V10: law-registry doc 200 caution" "$ref" '200 ≠ in force'

  # --- Executable: register MUST REFUSE a repealed act ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup"  # /lawyer pre-flight guarantees .startup/ exists
  assert_file_exists "V11: register script present" "$reg"
  export FAKE_GRAPH='{"act":{"rt_id":"1061448","title":"Julgeolekumaksu seadus","act_type":"seadus"}}'
  export FAKE_CITATION='{"act_id":34398,"act_title":"Julgeolekumaksu seadus","paragraph":"18","text":"Maksumäär on 2%.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"repealed","in_force":false,"redaktsioon_date":"2026-01-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$reg" julgeolekumaks 34398 "§ 18" "phantom tax" 2>&1) || ec=$?
  assert_exit_code "V12: register refuses repealed (non-zero)" "$ec" 1
  assert_output_contains "V13: refusal explains not in force" "$output" "not in force"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -f "$workdir/.startup/laws/julgeolekumaks.txt" ]; then
    echo -e "  ${GREEN}PASS${NC} V14: no snapshot written for refused register"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} V14: snapshot written despite refusal"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("V14: snapshot written despite refusal")
  fi
  if [ -f "$workdir/.startup/law-registry.json" ]; then
    has=$(jq -r '.entries | has("julgeolekumaks")' "$workdir/.startup/law-registry.json" 2>/dev/null || echo "true")
  else
    has="false"
  fi
  assert_equals "V15: no registry entry for refused register" "$has" "false"
  rm -rf "$workdir"

  # --- Executable: --force overrides the guard ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup"  # /lawyer pre-flight guarantees .startup/ exists
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$reg" julgeolekumaks 34398 "§ 18" "phantom tax" --force 2>&1) || ec=$?
  assert_exit_code "V16: register --force on repealed exits 0" "$ec" 0
  assert_file_exists "V17: --force writes snapshot" "$workdir/.startup/laws/julgeolekumaks.txt"
  assert_json_field "V18: --force stores status=repealed" "$workdir/.startup/law-registry.json" '.entries.julgeolekumaks.status' "repealed"
  rm -rf "$workdir"

  # --- Executable: a VALID act registers and stores lifecycle fields ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup"  # /lawyer pre-flight guarantees .startup/ exists
  export FAKE_GRAPH='{"act":{"rt_id":"1045568","title":"Isikuandmete kaitse seadus","act_type":"seadus"}}'
  export FAKE_CITATION='{"act_id":30087,"act_title":"Isikuandmete kaitse seadus","paragraph":"10","text":"Töötlemine on lubatud.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"valid","in_force":true,"redaktsioon_date":"2026-03-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$reg" consent 30087 "§ 10" "lawful basis" 2>&1) || ec=$?
  assert_exit_code "V19: register valid act exits 0" "$ec" 0
  assert_json_field "V20: valid act stored status=valid" "$workdir/.startup/law-registry.json" '.entries.consent.status' "valid"
  assert_json_field "V21: valid act stored redaktsioon_date" "$workdir/.startup/law-registry.json" '.entries.consent.redaktsioon_date' "2026-03-01"
  rm -rf "$workdir"

  # --- Executable: `check` flags an act that flipped to repealed (no feed event) ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup/laws"
  cat > "$workdir/.startup/law-registry.json" <<'REG'
{"version":2,"last_feed_check_at":null,"entries":{
  "phantom":{"act_id":34398,"rt_id":"1061448","redaktsioon_id":"106032026010","redaktsioon_date":"2026-01-01","status":"valid","act_title":"Julgeolekumaksu seadus","act_type":"seadus","citation":"§ 18","citation_parts":{"paragraph":"18","paragraph_qualifier":"","section":"","section_qualifier":"","point":"","point_qualifier":""},"rt_url":"https://www.riigiteataja.ee/akt/106032026010","registered_at":"2026-01-01T00:00:00Z","verified_at":"2026-01-01T00:00:00Z","registered_by":"lawyer","purpose":"x","needs_review":false,"change_detected_at":null,"change":null,"gh_issue_url":null}
}}
REG
  export FAKE_FEED='{"items":[],"total":0}'
  export FAKE_CITATION='{"act_id":34398,"act_title":"Julgeolekumaksu seadus","paragraph":"18","text":"Maksumäär on 2%.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"repealed","in_force":false,"redaktsioon_date":"2026-01-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$chk" 2>&1) || ec=$?
  assert_exit_code "V23: check exits 0" "$ec" 0
  assert_json_field "V24: repealed entry flagged needs_review" "$workdir/.startup/law-registry.json" '.entries.phantom.needs_review' "true"
  assert_json_field "V25: change.type is lifecycle" "$workdir/.startup/law-registry.json" '.entries.phantom.change.type' "lifecycle"
  assert_json_field "V26: status updated to repealed" "$workdir/.startup/law-registry.json" '.entries.phantom.status' "repealed"
  unset FAKE_FEED FAKE_CITATION FAKE_GRAPH
  rm -rf "$workdir"

  # --- Executable: `ack` MUST REFUSE to re-bless a repealed redaction ---
  workdir=$(make_workdir)
  make_mock_curl "$workdir"
  mkdir -p "$workdir/.startup/laws"
  printf 'OLD TEXT\n' > "$workdir/.startup/laws/phantom.txt"
  cat > "$workdir/.startup/law-registry.json" <<'REG'
{"version":2,"last_feed_check_at":null,"entries":{
  "phantom":{"act_id":34398,"rt_id":"1061448","redaktsioon_id":"106032026010","redaktsioon_date":"2026-01-01","status":"valid","act_title":"Julgeolekumaksu seadus","act_type":"seadus","citation":"§ 18","citation_parts":{"paragraph":"18","paragraph_qualifier":"","section":"","section_qualifier":"","point":"","point_qualifier":""},"rt_url":"https://www.riigiteataja.ee/akt/106032026010","registered_at":"2026-01-01T00:00:00Z","verified_at":"2026-01-01T00:00:00Z","registered_by":"lawyer","purpose":"x","needs_review":true,"change_detected_at":"2026-05-01T00:00:00Z","change":{"feed_event_id":null,"type":"lifecycle","summary":"x","effective_date":null},"gh_issue_url":null}
}}
REG
  export FAKE_CITATION='{"act_id":34398,"act_title":"Julgeolekumaksu seadus","paragraph":"18","text":"Maksumäär on 2%.","url":"https://www.riigiteataja.ee/akt/106032026010","status":"repealed","in_force":false,"redaktsioon_date":"2026-01-01"}'
  ec=0
  output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" EST_DATALAKE_API_KEY=test bash "$ackscr" phantom 2>&1) || ec=$?
  assert_exit_code "V27: ack refuses repealed (non-zero)" "$ec" 1
  assert_output_contains "V28: ack refusal message" "$output" "Refusing to ack"
  assert_json_field "V29: ack kept needs_review=true" "$workdir/.startup/law-registry.json" '.entries.phantom.needs_review' "true"
  assert_equals "V30: ack did not overwrite snapshot" "$(cat "$workdir/.startup/laws/phantom.txt")" "OLD TEXT"
  unset FAKE_CITATION
  rm -rf "$workdir"

  # --- Pure text-processing helpers (no network) ---
  # V31: citation parser preserves the superscript qualifier (§ 14 lõige 1¹ punkt 3)
  output=$(bash -c 'source "$1/lawyer-common.sh"; lawyer_parse_citation "§ 14 lõige 1¹ punkt 3"' _ "$scr")
  assert_equals "V31: parse_citation pipes parts + qualifier" "$output" "14||1|1|3|"
  # V32: citation-URL builder re-attaches + URL-encodes the superscript
  output=$(bash -c 'source "$1/lawyer-common.sh"; lawyer_cite_url 30087 14 "" 1 1 "" ""' _ "$scr")
  assert_equals "V32: cite_url encodes section=1¹" "$output" "https://datalake.r-53.com/api/v1/laws/30087/citation?paragraph=14&section=1%C2%B9"
  # V33: DATALAKE_URL override is honoured by the builder
  output=$(DATALAKE_URL="https://example.test" bash -c 'source "$1/lawyer-common.sh"; lawyer_cite_url 30087 10 "" "" "" "" ""' _ "$scr")
  assert_output_contains "V33: cite_url honours DATALAKE_URL override" "$output" "https://example.test/api/v1/laws/30087/citation"
  # V34: marker scan maps every comma-separated slug to file:line, skips docs/legal/
  workdir=$(make_workdir)
  mkdir -p "$workdir/src" "$workdir/docs/legal"
  printf '// LAW: consent-basis, cookie-x\n' > "$workdir/src/a.ts"
  printf '<!-- LAW: should-not-appear -->\n' > "$workdir/docs/legal/out.md"
  output=$(cd "$workdir" && bash "$scr/lawyer-marker-scan.sh")
  assert_output_contains "V34a: marker scan finds first slug" "$output" $'consent-basis\tsrc/a.ts:1'
  assert_output_contains "V34b: marker scan splits comma slug" "$output" $'cookie-x\tsrc/a.ts:1'
  assert_output_not_contains "V34c: marker scan excludes docs/legal/" "$output" "should-not-appear"
  rm -rf "$workdir"
}

test_lawyer_lifecycle
