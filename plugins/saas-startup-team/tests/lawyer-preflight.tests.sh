# Sourced by run-tests.sh: deterministic lawyer prerequisite checks.

echo -e "${CYAN}Suite LPF: lawyer preflight${NC}"
lpf_script="$PLUGIN_ROOT/scripts/lawyer-preflight.sh"
lpf_root=$(mktemp -d)
lpf_project="$lpf_root/project"
lpf_bin="$lpf_root/bin"
lpf_log="$lpf_root/curl.log"
mkdir -p "$lpf_project/.startup" "$lpf_project/docs/business" "$lpf_bin"
printf '%s\n' '{"iteration":1,"status":"active","active_role":"lawyer"}' \
  > "$lpf_project/.startup/state.json"
printf '%s\n' '# Business brief' > "$lpf_project/docs/business/brief.md"

cat > "$lpf_bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
url=${!#}
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
case "$url" in
  */api/v1/health/ready) printf '200' ;;
  *) printf '%s' "${FAKE_AUTH_CODE:-200}" ;;
esac
SH
chmod +x "$lpf_bin/curl"

lpf_ec=0
lpf_out=$(cd "$lpf_project" && PATH="$lpf_bin:$PATH" \
  EST_DATALAKE_API_KEY=valid-test-key DATALAKE_URL=https://datalake.example \
  FAKE_AUTH_CODE=200 FAKE_CURL_LOG="$lpf_log" bash "$lpf_script" 2>&1) || lpf_ec=$?
assert_exit_code "LPF1: ready authenticated project passes" "$lpf_ec" 0
assert_output_contains "LPF2: successful preflight is explicit" "$lpf_out" 'lawyer preflight: ok'
assert_equals "LPF3: readiness and authentication are both checked" \
  "$(wc -l < "$lpf_log" | tr -d ' ')" "2"
assert_file_contains "LPF4: authenticated check sends the key header" "$lpf_script" 'X-API-Key:'

: > "$lpf_log"
lpf_ec=0
lpf_out=$(cd "$lpf_project" && PATH="$lpf_bin:$PATH" \
  EST_DATALAKE_API_KEY=revoked-test-key DATALAKE_URL=https://datalake.example \
  FAKE_AUTH_CODE=401 FAKE_CURL_LOG="$lpf_log" bash "$lpf_script" 2>&1) || lpf_ec=$?
assert_exit_code "LPF5: rejected API key fails preflight" "$lpf_ec" 2
assert_output_contains "LPF6: authentication failure is actionable" "$lpf_out" \
  'datalake authentication failed (HTTP 401)'
assert_output_not_contains "LPF7: authentication failure never echoes the key" "$lpf_out" \
  'revoked-test-key'

printf '%s\n' '{}' > "$lpf_project/.startup/state.json"
: > "$lpf_log"
lpf_ec=0
lpf_out=$(cd "$lpf_project" && PATH="$lpf_bin:$PATH" \
  EST_DATALAKE_API_KEY=valid-test-key DATALAKE_URL=https://datalake.example \
  FAKE_AUTH_CODE=200 FAKE_CURL_LOG="$lpf_log" bash "$lpf_script" 2>&1) || lpf_ec=$?
assert_exit_code "LPF8: malformed startup state fails preflight" "$lpf_ec" 2
assert_output_contains "LPF9: malformed state failure is explicit" "$lpf_out" \
  '.startup/state.json is invalid'
assert_equals "LPF10: invalid state makes no network request" \
  "$(wc -l < "$lpf_log" | tr -d ' ')" "0"

: > "$lpf_project/.startup/state.json"
lpf_ec=0
(cd "$lpf_project" && PATH="$lpf_bin:$PATH" \
  EST_DATALAKE_API_KEY=valid-test-key DATALAKE_URL=https://datalake.example \
  FAKE_AUTH_CODE=200 FAKE_CURL_LOG="$lpf_log" bash "$lpf_script" >/dev/null 2>&1) || lpf_ec=$?
assert_exit_code "LPF11: empty startup state fails preflight" "$lpf_ec" 2

rm -rf "$lpf_root"
