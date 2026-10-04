# Real-script citation verification: mock curl on PATH; no key or network needed.
lifecycle_fixture() {
  mkdir -p "$1/bin" "$1/.startup/laws"
  cat > "$1/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
code=200
rc=0
case "$url" in
  */laws/124/citation*) body='{"text":"Verified replacement text.","status":"valid","in_force":true}' ;;
  */citation*) body="$CITATION_BODY"; code="$CITATION_CODE"; rc="$CITATION_RC" ;;
  */graph*) body='{"act":{"rt_id":"456","title":"Sample law","act_type":"seadus"}}' ;;
  */changes/feed*) body='{"items":[],"total":0,"partial":false}' ;;
  *) echo "Unexpected mock URL: $url" >&2; exit 99 ;;
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
  chmod +x "$1/bin/curl"
  cat > "$1/.startup/law-registry.json" <<'REG'
{"version":2,"last_feed_check_at":"2020-01-01T00:00:00Z","entries":{"sample-law":{"act_id":123,"rt_id":"456","citation":"§ 14 lõige 1","citation_parts":{"paragraph":"14","section":"1"},"status":"valid","verified_at":"2020-01-01T00:00:00Z","needs_review":true,"change_detected_at":"2020-02-01T00:00:00Z","change":{"type":"lifecycle","summary":"Pending review"},"gh_issue_url":"https://example.test/issues/1"}}}
REG
  printf 'OLD SNAPSHOT\n' > "$1/.startup/laws/sample-law.txt"
}

lifecycle_run() {
  local action="$1"
  local -a args=()
  case "$action" in
    ack) args=(sample-law) ;;
    register|register-force)
      args=(sample-law 123 '§ 14 lõige 1' 'Lifecycle regression')
      if [ "$action" = register-force ]; then args+=(--force); action=register; fi ;;
  esac
  lifecycle_rc=0
  (cd "$lifecycle_dir" && PATH="$lifecycle_dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key \
    bash "$PLUGIN_ROOT/scripts/lawyer-$action.sh" "${args[@]}") \
    > "$lifecycle_dir/stdout" 2> "$lifecycle_dir/stderr" || lifecycle_rc=$?
}

lifecycle_prepare() {
  lifecycle_fixture "$lifecycle_dir"
  if [ "$1" = check ]; then
    # Check the unflagged issue reproduction, alongside an existing pending flag.
    jq '.entries.pending = .entries["sample-law"] | .entries["sample-law"].needs_review = false' \
      "$lifecycle_dir/.startup/law-registry.json" > "$lifecycle_dir/registry.tmp"
    mv "$lifecycle_dir/registry.tmp" "$lifecycle_dir/.startup/law-registry.json"
  fi
  lifecycle_before=$(jq -cS '.entries' "$lifecycle_dir/.startup/law-registry.json")
}

lifecycle_preserved() {
  [ "$(jq -cS '.entries' "$lifecycle_dir/.startup/law-registry.json")" = "$lifecycle_before" ] &&
    [ "$(cat "$lifecycle_dir/.startup/laws/sample-law.txt")" = 'OLD SNAPSHOT' ]
}

test_citation_lifecycle() {
  echo -e "\n${CYAN}Suite: citation lifecycle evidence (#592)${NC}"
  local lifecycle_dir lifecycle_rc lifecycle_before scenario action ok messages
  local valid='{"text":"Verified replacement text.","status":"valid","in_force":true,"redaktsioon_date":"2020-01-01"}'
  local CITATION_BODY CITATION_CODE CITATION_RC
  export CITATION_BODY CITATION_CODE CITATION_RC
  lifecycle_dir=$(mktemp -d)
  for scenario in error-json invalid-json http-error http-redirect transport missing-both missing-status missing-in-force missing-status-invalid missing-in-force-invalid null-fields wrong-types; do
    CITATION_CODE=200 CITATION_RC=0
    case "$scenario" in
      error-json) CITATION_BODY='{"detail":"Upstream unavailable"}' ;;
      invalid-json) CITATION_BODY='{invalid json' ;;
      http-error) CITATION_BODY="$valid"; CITATION_CODE=503 ;;
      http-redirect) CITATION_BODY="$valid"; CITATION_CODE=302 ;;
      transport) CITATION_BODY="$valid"; CITATION_RC=28 ;;
      missing-both) CITATION_BODY='{"text":"Unverified replacement text."}' ;;
      missing-status) CITATION_BODY='{"text":"Unverified replacement text.","in_force":true}' ;;
      missing-in-force) CITATION_BODY='{"text":"Unverified replacement text.","status":"valid"}' ;;
      missing-status-invalid) CITATION_BODY='{"text":"Unverified replacement text.","in_force":false}' ;;
      missing-in-force-invalid) CITATION_BODY='{"text":"Unverified replacement text.","status":"repealed"}' ;;
      null-fields) CITATION_BODY='{"text":"Unverified replacement text.","status":null,"in_force":null}' ;;
      wrong-types) CITATION_BODY='{"text":"Unverified replacement text.","status":"valid","in_force":"true"}' ;;
    esac
    for action in check ack ack-all register register-force; do
      lifecycle_prepare "$action"
      lifecycle_run "$action"
      ok=0
      [ "$lifecycle_rc" -ne 0 ] || ok=1
      lifecycle_preserved || ok=1
      messages=$(cat "$lifecycle_dir/stdout" "$lifecycle_dir/stderr")
      if [ "$action" = check ]; then
        messages=$(cat "$lifecycle_dir/stderr")
        [[ "$messages" == *WARNING* ]] || ok=1
      fi
      [[ "$messages" == *sample-law* ]] || ok=1
      # Report the missing evidence distinctly from verified-invalid lifecycle.
      [[ "$messages" == *"lifecycle unknown"* || "$messages" == *incomplete* || "$messages" == *unverified* ]] || ok=1
      record "citation $scenario / $action: fails explicitly, preserves entry and snapshot" "$ok" "exit=$lifecycle_rc; $messages"
    done
  done

  CITATION_CODE=200 CITATION_RC=0
  for scenario in repealed not-in-force superseded; do
    case "$scenario" in
      repealed) CITATION_BODY='{"text":"Repealed text.","status":"repealed","in_force":false}' ;;
      not-in-force) CITATION_BODY='{"text":"Future text.","status":"valid","in_force":false}' ;;
      superseded) CITATION_BODY='{"text":"Old text.","status":"superseded","in_force":true}' ;;
    esac
    for action in check ack ack-all register; do
      lifecycle_prepare "$action"
      lifecycle_run "$action"
      ok=0
      if [ "$action" = check ]; then
        jq -e '.entries["sample-law"].needs_review == true and .entries["sample-law"].change.type == "lifecycle"' \
          "$lifecycle_dir/.startup/law-registry.json" >/dev/null || ok=1
        [ "$(cat "$lifecycle_dir/.startup/laws/sample-law.txt")" = 'OLD SNAPSHOT' ] || ok=1
      else
        [ "$lifecycle_rc" -ne 0 ] || ok=1
        lifecycle_preserved || ok=1
      fi
      record "citation $scenario / $action: explicit invalid lifecycle stays guarded" "$ok" "exit=$lifecycle_rc"
    done
  done

  CITATION_BODY="$valid"
  for action in check ack ack-all register; do
    lifecycle_prepare "$action"
    lifecycle_run "$action"
    ok=0
    [ "$lifecycle_rc" -eq 0 ] || ok=1
    if [ "$action" = check ]; then
      lifecycle_preserved || ok=1
    else
      jq -e '.entries["sample-law"] | .needs_review == false and .status == "valid" and (.verified_at != null and .verified_at != "2020-01-01T00:00:00Z")' \
        "$lifecycle_dir/.startup/law-registry.json" >/dev/null || ok=1
      [ "$(cat "$lifecycle_dir/.startup/laws/sample-law.txt")" = 'Verified replacement text.' ] || ok=1
    fi
    record "citation verified valid / $action: succeeds with expected state" "$ok" "exit=$lifecycle_rc"
  done

  CITATION_CODE=201
  lifecycle_prepare register
  lifecycle_run register
  ok=0
  [ "$lifecycle_rc" -eq 0 ] || ok=1
  jq -e '.entries["sample-law"].verified_at != "2020-01-01T00:00:00Z"' \
    "$lifecycle_dir/.startup/law-registry.json" >/dev/null || ok=1
  [ "$(cat "$lifecycle_dir/.startup/laws/sample-law.txt")" = 'Verified replacement text.' ] || ok=1
  record 'citation HTTP 201 / register: accepts verified-valid 2xx response' "$ok" "exit=$lifecycle_rc"

  CITATION_CODE=200
  CITATION_BODY='{"text":"Unverified replacement text."}'
  lifecycle_prepare ack-all
  jq '.entries["second-law"] = .entries["sample-law"] | .entries["second-law"].act_id = 124' \
    "$lifecycle_dir/.startup/law-registry.json" > "$lifecycle_dir/registry.tmp"
  mv "$lifecycle_dir/registry.tmp" "$lifecycle_dir/.startup/law-registry.json"
  printf 'SECOND OLD SNAPSHOT\n' > "$lifecycle_dir/.startup/laws/second-law.txt"
  lifecycle_run ack-all
  ok=0
  [ "$lifecycle_rc" -ne 0 ] || ok=1
  jq -e --argjson old "$lifecycle_before" '
    .entries["sample-law"] == $old["sample-law"] and
    (.entries["second-law"] | .needs_review == false and .verified_at != null and .verified_at != "2020-01-01T00:00:00Z")
  ' "$lifecycle_dir/.startup/law-registry.json" >/dev/null || ok=1
  [ "$(cat "$lifecycle_dir/.startup/laws/sample-law.txt")" = 'OLD SNAPSHOT' ] || ok=1
  [ "$(cat "$lifecycle_dir/.startup/laws/second-law.txt")" = 'Verified replacement text.' ] || ok=1
  record 'citation mixed ack-all: preserves unknown, refreshes valid, returns failure' "$ok" "exit=$lifecycle_rc"

  CITATION_BODY='{"text":"Future law text.","status":"not_yet_in_force","in_force":false,"redaktsioon_date":"2999-01-01"}'
  lifecycle_prepare register
  lifecycle_run register-force
  ok=0
  [ "$lifecycle_rc" -eq 0 ] || ok=1
  jq -e '.entries["sample-law"] | .status == "not_yet_in_force" and .expected_effective_date == "2999-01-01" and .verified_at == null' \
    "$lifecycle_dir/.startup/law-registry.json" >/dev/null || ok=1
  [ "$(cat "$lifecycle_dir/.startup/laws/sample-law.txt")" = 'Future law text.' ] || ok=1
  record 'citation future law / register --force: intentional override survives' "$ok" "exit=$lifecycle_rc"
  rm -rf "$lifecycle_dir"
}

test_citation_lifecycle
