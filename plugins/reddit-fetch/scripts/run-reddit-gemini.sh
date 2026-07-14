#!/usr/bin/env bash
# Run bounded Gemini discovery without exposing provider stderr or retrying indefinitely.
set -euo pipefail
export LC_ALL=C

workflow=0
if [ "${1:-}" = "--workflow" ]; then
  workflow=1
  shift
fi

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

terminal_failure() {
  local code="$1" diagnostic="$2" status="unavailable" report
  [ "$code" -ne 4 ] || status="blocked"
  if [ "$workflow" -eq 1 ]; then
    report="## Reddit Research"$'\n\n'"No usable Gemini result."$'\n\n'"Diagnostic: $diagnostic"$'\n\n'"Gemini output was not used as evidence. No verification, artifact write, or issue filing was attempted."
    printf '{"status":"%s","terminal":true,"exit_code":%s,"diagnostic":"%s","final_response":"%s"}\n' \
      "$status" "$code" "$(json_escape "$diagnostic")" "$(json_escape "$report")"
    exit 0
  fi
  echo "$diagnostic" >&2
  exit "$code"
}

usage() {
  terminal_failure 2 "usage: run-reddit-gemini.sh [--workflow] --prompt <reddit research prompt>"
}

[ "$#" -eq 2 ] && [ "${1:-}" = "--prompt" ] && [ -n "${2:-}" ] || usage
prompt="$2"
[ "${#prompt}" -le 12000 ] || {
  terminal_failure 2 "reddit research unavailable: prompt exceeds 12000 bytes (0 calls)"
}

gemini_bin="$(command -v gemini 2>/dev/null || true)"
[ -n "$gemini_bin" ] || {
  terminal_failure 4 "reddit research blocked: Gemini CLI is not installed (0 calls)"
}
timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$timeout_bin" ] || {
  terminal_failure 4 "reddit research blocked: GNU-compatible timeout is not installed (0 calls)"
}

case "${OSTYPE:-}" in
  darwin*) system_policy_dir="/Library/Application Support/GeminiCli/policies" ;;
  cygwin*|msys*|win32*) system_policy_dir="C:/ProgramData/gemini-cli/policies" ;;
  *) system_policy_dir="/etc/gemini-cli/policies" ;;
esac
shopt -s nullglob
system_policy_files=("$system_policy_dir"/*.toml)
shopt -u nullglob
[ "${#system_policy_files[@]}" -eq 0 ] || {
  terminal_failure 4 "reddit research blocked: system Gemini policies prevent isolated tool enforcement (0 calls)"
}

tmp_dir=""
source_cli_home="${GEMINI_CLI_HOME:-${HOME:-}}"
tmp_base="${TMPDIR:-/tmp}"
case "$tmp_base" in /*) ;; *) tmp_base="/tmp" ;; esac
tmp_base="${tmp_base%/}"
[ -n "$tmp_base" ] || tmp_base="/"
umask 077
for attempt in 1 2 3 4 5; do
  candidate="$tmp_base/reddit-fetch.$$.$RANDOM.$attempt"
  if mkdir "$candidate" 2>/dev/null; then tmp_dir="$candidate"; break; fi
done
[ -n "$tmp_dir" ] || terminal_failure 3 "reddit research unavailable: could not create bounded-run workspace (0 calls)"
trap 'rm -rf "$tmp_dir" >/dev/null 2>&1 || true' EXIT
canonical_tmp="$(cd "$tmp_dir" 2>/dev/null && pwd -P)" || {
  terminal_failure 3 "reddit research unavailable: could not resolve bounded-run workspace (0 calls)"
}
tmp_dir="$canonical_tmp"
work_dir="$tmp_dir/work"
isolated_home="$tmp_dir/home"
isolated_gemini_dir="$isolated_home/.gemini"
if ! mkdir "$work_dir" 2>/dev/null || ! mkdir "$work_dir/.git" 2>/dev/null \
  || ! mkdir -p "$isolated_gemini_dir" 2>/dev/null; then
  terminal_failure 3 "reddit research unavailable: could not create bounded-run workspace (0 calls)"
fi
auth_type="gemini-api-key"
if [ -z "${GEMINI_API_KEY:-}" ]; then
  auth_type="oauth-personal"
  oauth_credential_staged=0
  source_gemini_dir="$source_cli_home/.gemini"
  for auth_file in gemini-credentials.json oauth_creds.json google_accounts.json; do
    [ -n "$source_cli_home" ] || continue
    source_auth_file="$source_gemini_dir/$auth_file"
    [ -f "$source_auth_file" ] && [ ! -L "$source_auth_file" ] || continue
    if ! cp "$source_auth_file" "$isolated_gemini_dir/$auth_file" 2>/dev/null \
      || ! chmod 600 "$isolated_gemini_dir/$auth_file" 2>/dev/null; then
      terminal_failure 4 "reddit research blocked: could not stage Gemini authentication (0 calls)"
    fi
    case "$auth_file" in gemini-credentials.json|oauth_creds.json) oauth_credential_staged=1 ;; esac
  done
  [ "$oauth_credential_staged" -eq 1 ] || {
    terminal_failure 4 "reddit research blocked: file-backed Gemini authentication is required (0 calls)"
  }
fi

scan_dir="$work_dir"
while :; do
  env_file="$scan_dir/.gemini/.env"
  if [ -e "$env_file" ] || [ -L "$env_file" ]; then
    terminal_failure 4 "reddit research blocked: ancestor Gemini environment file prevents isolation (0 calls)"
  fi
  [ "$scan_dir" = "/" ] && break
  scan_dir="${scan_dir%/*}"
  [ -n "$scan_dir" ] || scan_dir="/"
done
stdout_file="$tmp_dir/stdout"
stderr_file="$tmp_dir/stderr"
allowed_urls_file="$tmp_dir/allowed-urls"
admin_policy="$tmp_dir/admin-policy.toml"
system_settings="$tmp_dir/system-settings.json"
last_rc=0
reddit_url_pattern='https://(www|old)\.reddit\.com/r/[[:alnum:]_]+/comments/[[:alnum:]]+(/[[:alnum:]_%?=&./-]*)?'

bounded_prompt="${prompt}"$'\n\nReturn at most 5 threads and 800 words. Include a full https://www.reddit.com/r/.../comments/... URL for every thread.'
retry_prompt="${bounded_prompt}"$'\nNarrow the search to the highest-signal results.'

cat > "$admin_policy" <<'EOF'
[[rule]]
toolName = "*"
decision = "deny"
priority = 998
denyMessage = "Only bounded Google web search is enabled."

[[rule]]
toolName = "google_web_search"
decision = "allow"
priority = 999
EOF

printf '%s\n' "{\"general\":{\"previewFeatures\":true},\"admin\":{\"secureModeEnabled\":true,\"extensions\":{\"enabled\":false},\"mcp\":{\"enabled\":false},\"skills\":{\"enabled\":false}},\"hooksConfig\":{\"enabled\":false},\"security\":{\"auth\":{\"selectedType\":\"$auth_type\"},\"environmentVariableRedaction\":{\"enabled\":true,\"blocked\":[\"GEMINI_API_KEY\"]}},\"advanced\":{\"ignoreLocalEnv\":true}}" > "$system_settings"

clean_env=(
  env -i
  "HOME=$isolated_home"
  "PATH=$PATH"
  "TMPDIR=$tmp_dir"
  "LANG=C"
  "LC_ALL=C"
  "NO_COLOR=1"
  "TERM=dumb"
  "GEMINI_CLI_HOME=$isolated_home"
  "GEMINI_CLI_NO_RELAUNCH=true"
  "GEMINI_DEFAULT_AUTH_TYPE=$auth_type"
  "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$system_settings"
)
[ -z "${GEMINI_API_KEY:-}" ] || clean_env+=("GEMINI_API_KEY=$GEMINI_API_KEY")
if [ "$auth_type" = "oauth-personal" ]; then
  clean_env+=("GOOGLE_GENAI_USE_GCA=true" "NO_BROWSER=true")
  if [ -f "$isolated_gemini_dir/gemini-credentials.json" ]; then
    clean_env+=("GEMINI_FORCE_ENCRYPTED_FILE_STORAGE=true" "GEMINI_FORCE_FILE_STORAGE=true")
  fi
fi

run_call() {
  local model="$1" seconds="$2" query="$3" no_mcp
  no_mcp="__reddit_fetch_no_mcp_${$}_${RANDOM}_${RANDOM}__"
  : > "$stdout_file"
  : > "$stderr_file"
  set +e
  (
    cd "$work_dir" || exit 125
    "${clean_env[@]}" "$timeout_bin" -k 5 "$seconds" "$gemini_bin" \
      -m "$model" -p "$query" -o text --approval-mode plan --skip-trust \
      -e none --allowed-mcp-server-names "$no_mcp" --admin-policy "$admin_policy" </dev/null
  ) >"$stdout_file" 2>"$stderr_file"
  last_rc=$?
  set -e
}

usable_output() {
  local bytes words url_count
  grep -q '[^[:space:]]' "$stdout_file" || return 1
  bytes="$(wc -c < "$stdout_file")" || return 1
  words="$(wc -w < "$stdout_file")" || return 1
  [ "$bytes" -le 16000 ] && [ "$words" -le 800 ] || return 1
  awk -v pattern="$reddit_url_pattern" '{
      line = $0
      while (match(line, pattern)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }' "$stdout_file" \
    | sed -e 's/[.,;:]*$//' -e 's#^https://old\.reddit\.com/#https://www.reddit.com/#' \
    | sort -u > "$allowed_urls_file" || return 1
  url_count="$(wc -l < "$allowed_urls_file")" || return 1
  [ "$url_count" -ge 1 ] && [ "$url_count" -le 5 ]
}

auth_failure() {
  grep -Eqi 'unauthenticated|authentication (failed|required)|auth method|re-authenticate|no authentication|api key (is )?(missing|not valid)|api_key_invalid|invalid (api key|credentials)|oauth|log[ -]?in required|(^|[^0-9])401([^0-9]|$)' "$stderr_file"
}

quota_failure() {
  grep -Eqi 'quota|rate limit|resource exhausted|(^|[^0-9])429([^0-9]|$)' "$stderr_file"
}

retryable_failure() {
  grep -Eqi 'model[^[:cntrl:]]*(not found|does not exist|unsupported)|404[^[:cntrl:]]*model|service unavailable|(^|[^0-9])503([^0-9]|$)|(^|[^[:alnum:]_])unavailable([^[:alnum:]_]|$)' "$stderr_file"
}

emit_success() {
  if [ "$workflow" -eq 1 ]; then
    printf '{"status":"ready","terminal":false,"untrusted_body":true}\n'
    while IFS= read -r url; do
      printf 'allowed_reddit_url=%s\n' "$url"
      printf 'allowed_reddit_url=%s\n' "${url/https:\/\/www.reddit.com\//https:\/\/old.reddit.com\/}"
    done < "$allowed_urls_file"
    printf '%s\n' '---BEGIN UNTRUSTED GEMINI OUTPUT---'
    cat "$stdout_file"
  else
    cat "$stdout_file"
  fi
  exit 0
}

run_call "gemini-3-flash-preview" 90 "$bounded_prompt"
if [ "$last_rc" -eq 0 ] && usable_output; then
  emit_success
fi
if [ "$last_rc" -ne 0 ] && auth_failure; then
  terminal_failure 4 "reddit research blocked: Gemini authentication is required after 1 call"
fi
if [ "$last_rc" -ne 0 ] && quota_failure; then
  terminal_failure 3 "reddit research unavailable: Gemini quota or rate limit reached after 1 call"
fi

retry=0
if [ "$last_rc" -eq 0 ]; then
  retry=1
else
  case "$last_rc" in
    124|137|143) retry=1 ;;
    *)
      if retryable_failure; then retry=1; fi
      ;;
  esac
fi
[ "$retry" -eq 1 ] || {
  terminal_failure 3 "reddit research unavailable: Gemini failed before producing usable Reddit threads after 1 call"
}

run_call "gemini-2.5-flash" 45 "$retry_prompt"
if [ "$last_rc" -eq 0 ] && usable_output; then
  emit_success
fi
if [ "$last_rc" -ne 0 ] && auth_failure; then
  terminal_failure 4 "reddit research blocked: Gemini authentication is required after 2 calls"
fi
if [ "$last_rc" -ne 0 ] && quota_failure; then
  terminal_failure 3 "reddit research unavailable: Gemini quota or rate limit reached after 2 calls"
fi

terminal_failure 3 "reddit research unavailable: no usable Reddit thread result after 2 bounded calls"
