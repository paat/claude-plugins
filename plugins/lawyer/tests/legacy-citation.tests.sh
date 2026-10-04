# Legacy v2 entries whose citation_parts predate qualifier fields (#593): the real
# registered-entry builder must recover qualifiers from the citation or refuse.
legacy_fixture() {
  mkdir -p "$1/bin" "$1/.startup/laws"
  cat > "$1/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  */citation*) printf '%s\n' "$url" >> "$LEGACY_URL_LOG"
    body='{"text":"Verified replacement text.","status":"valid","in_force":true}' ;;
  */changes/feed*) body='{"items":[],"total":0,"partial":false}' ;;
  *) echo "Unexpected mock URL: $url" >&2; exit 99 ;;
esac
printf '%s' "$body"
for arg in "$@"; do
  [ "$arg" = -w ] && { printf '\n200'; break; }
done
MOCK
  chmod +x "$1/bin/curl"
  jq -n --arg c "$2" --argjson p "$3" --argjson flag "$4" '{version:2,last_feed_check_at:"2020-01-01T00:00:00Z",entries:{"sample-law":{
    act_id:123,rt_id:"456",citation:$c,citation_parts:$p,needs_review:$flag,status:"valid",gh_issue_url:null}}}' \
    > "$1/.startup/law-registry.json"
  printf 'OLD SNAPSHOT\n' > "$1/.startup/laws/sample-law.txt"
  : > "$1/urls"
}

# legacy_run <action> <citation> <parts-json> → legacy_rc, legacy_url, legacy_msg
legacy_run() {
  local flag=true
  [ "$1" = check ] && flag=false
  legacy_fixture "$legacy_dir" "$2" "$3" "$flag"
  legacy_before=$(jq -cS '.entries' "$legacy_dir/.startup/law-registry.json")
  local -a args=()
  [ "$1" = ack ] && args=(sample-law)
  legacy_rc=0
  (cd "$legacy_dir" && PATH="$legacy_dir/bin:$PATH" EST_DATALAKE_API_KEY=synthetic-key LEGACY_URL_LOG="$legacy_dir/urls" \
    bash "$PLUGIN_ROOT/scripts/lawyer-$1.sh" "${args[@]}") > "$legacy_dir/out" 2>&1 || legacy_rc=$?
  legacy_url=$(cat "$legacy_dir/urls")
  legacy_msg=$(cat "$legacy_dir/out")
}

test_legacy_citation() {
  echo -e "\n${CYAN}Suite: legacy v2 citation_parts reconciliation (#593)${NC}"
  local legacy_dir legacy_rc legacy_url legacy_msg legacy_before name cit parts want action ok
  legacy_dir=$(mktemp -d)
  local base='https://datalake.r-53.com/api/v1/laws/123/citation?'
  # name | citation | stored citation_parts | expected query
  while IFS='|' read -r name cit parts want; do
    for action in ack ack-all check; do
      legacy_run "$action" "$cit" "$parts"
      ok=0
      [ "$legacy_rc" -eq 0 ] || ok=1
      [ "$legacy_url" = "$base$want" ] || ok=1
      if [ "$action" != check ]; then
        jq -e '.entries["sample-law"].needs_review == false' "$legacy_dir/.startup/law-registry.json" >/dev/null || ok=1
        [ "$(cat "$legacy_dir/.startup/laws/sample-law.txt")" = 'Verified replacement text.' ] || ok=1
      fi
      record "legacy $name / $action: fetches $want" "$ok" "exit=$legacy_rc url=$legacy_url; $legacy_msg"
    done
  done <<'CASES'
section qualifier recovered|§ 14 lõige 1¹|{"paragraph":"14","section":"1"}|paragraph=14&section=1%C2%B9
paragraph qualifier recovered|§ 14¹ lõige 2|{"paragraph":"14","section":"2"}|paragraph=14%C2%B9&section=2
point qualifier recovered|§ 53 lõige 4 punkt 7¹|{"paragraph":"53","section":"4","point":"7"}|paragraph=53&section=4&point=7%C2%B9
modern superscript entry|§ 14 lõige 1¹|{"paragraph":"14","paragraph_qualifier":"","section":"1","section_qualifier":"1","point":"","point_qualifier":""}|paragraph=14&section=1%C2%B9
legacy plain entry|§ 14 lõige 1|{"paragraph":"14","section":"1"}|paragraph=14&section=1
modern plain entry|§ 10 lõige 1 punkt 3|{"paragraph":"10","paragraph_qualifier":"","section":"1","section_qualifier":"","point":"3","point_qualifier":""}|paragraph=10&section=1&point=3
CASES

  while IFS='|' read -r name cit parts; do
    for action in ack ack-all check; do
      legacy_run "$action" "$cit" "$parts"
      ok=0
      [ "$legacy_rc" -ne 0 ] || ok=1
      [ -z "$legacy_url" ] || ok=1
      [ "$(jq -cS '.entries' "$legacy_dir/.startup/law-registry.json")" = "$legacy_before" ] || ok=1
      [ "$(cat "$legacy_dir/.startup/laws/sample-law.txt")" = 'OLD SNAPSHOT' ] || ok=1
      [[ "$legacy_msg" == *sample-law* && "$legacy_msg" == *re-register* ]] || ok=1
      [ "$action" != check ] || [[ "$legacy_msg" == *WARNING*incomplete* ]] || ok=1
      record "legacy $name / $action: refuses, no fetch, entry and snapshot kept" "$ok" "exit=$legacy_rc url=$legacy_url; $legacy_msg"
    done
  done <<'CASES'
explicit empty qualifier conflicts|§ 14 lõige 1¹|{"paragraph":"14","paragraph_qualifier":"","section":"1","section_qualifier":"","point":"","point_qualifier":""}
qualifier value conflicts|§ 14 lõige 1¹|{"paragraph":"14","section":"1","section_qualifier":"2"}
section base conflicts|§ 14 lõige 1¹|{"paragraph":"14","section":"2"}
section missing from parts|§ 14 lõige 1¹|{"paragraph":"14"}
unparseable citation|lõige 1¹|{"paragraph":"14","section":"1"}
CASES
  rm -rf "$legacy_dir"
}

test_legacy_citation
