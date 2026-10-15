# Sourced by run-tests.sh: optional EST_DATALAKE_API_KEY and "lg" citation abbreviation.

echo -e "${CYAN}Suite KDL: keyless datalake requests${NC}"
kdl_root=$(mktemp -d)
mkdir -p "$kdl_root/bin" "$kdl_root/project"
cat > "$kdl_root/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_CURL_ARGS"
printf '{"status":"valid","in_force":true}\n200'
SH
chmod +x "$kdl_root/bin/curl"

kdl_fetch() {
  (cd "$kdl_root/project" && PATH="$kdl_root/bin:$PATH" DATALAKE_URL=https://datalake.example \
    FAKE_CURL_ARGS="$kdl_root/args" bash -c '
      set -uo pipefail
      source "$1/scripts/lawyer-common.sh"
      lawyer_fetch_citation https://datalake.example/x
      echo "lifecycle=$CITE_LIFECYCLE"' _ "$PLUGIN_ROOT" 2>&1)
}

kdl_out=$(env -u EST_DATALAKE_API_KEY bash -c "$(declare -f kdl_fetch); kdl_root='$kdl_root'; PLUGIN_ROOT='$PLUGIN_ROOT'; kdl_fetch")
assert_output_not_contains "KDL1: key unset does not hit an unbound variable" "$kdl_out" 'unbound variable'
assert_output_contains "KDL2: key unset still reaches curl and classifies" "$kdl_out" 'lifecycle=verified-valid'
assert_output_not_contains "KDL3: key unset sends no X-API-Key header" "$(cat "$kdl_root/args")" 'X-API-Key'

kdl_out=$(EST_DATALAKE_API_KEY=secret-kdl-key bash -c "$(declare -f kdl_fetch); kdl_root='$kdl_root'; PLUGIN_ROOT='$PLUGIN_ROOT'; kdl_fetch")
assert_output_contains "KDL4: key set sends the X-API-Key header" "$(cat "$kdl_root/args")" 'X-API-Key: secret-kdl-key'
assert_output_not_contains "KDL5: key never reaches script output" "$kdl_out" 'secret-kdl-key'

kdl_out=$(env -u EST_DATALAKE_API_KEY PATH="$kdl_root/bin:$PATH" FAKE_CURL_ARGS="$kdl_root/args" \
  bash -c "cd '$kdl_root/project' && mkdir -p .startup && echo '{\"version\":2,\"last_feed_check_at\":null,\"entries\":{\"a\":{\"rt_id\":\"1\"}}}' > .startup/law-registry.json && bash '$PLUGIN_ROOT/scripts/lawyer-check.sh'" 2>&1 || true)
assert_output_not_contains "KDL6: lawyer-check without key has no unbound variable" "$kdl_out" 'unbound variable'
assert_output_not_contains "KDL7: lawyer-check without key sends no X-API-Key header" "$(cat "$kdl_root/args")" 'X-API-Key'

kdl_cite=$(source "$PLUGIN_ROOT/scripts/lawyer-common.sh"; lawyer_parse_citation "§ 14 lg 2² punkt 3")
assert_equals "KDL8: 'lg' abbreviation with superscript qualifier is parsed" "$kdl_cite" "14||2|2|3|"
kdl_cite=$(source "$PLUGIN_ROOT/scripts/lawyer-common.sh"; lawyer_parse_citation "§ 14 lg 22")
assert_equals "KDL9: 'lg 22' stays distinct from 'lg 2²'" "$kdl_cite" "14||22|||"

rm -rf "$kdl_root"
