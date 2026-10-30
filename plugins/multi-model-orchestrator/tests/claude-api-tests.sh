#!/usr/bin/env bash
# Optional scripts directory permits running the same cases against an untouched baseline.
set -euo pipefail
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
scripts="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo" "$work/home" "$work/login" "$work/artifacts"
git -C "$work/repo" init -q
printf 'base\n' > "$work/repo/file"
git -C "$work/repo" add file
git -C "$work/repo" -c user.name=Test -c user.email=test@example.com commit -qm base
printf 'test-claude-api-%s-%s-[]^$.*+?(){}|&\n' "$$" "$RANDOM" > "$work/key"
: > "$work/empty-key"
printf '{"oauthAccount":{"accountUuid":"fixture"}}\n' > "$work/login/.claude.json"
printf 'claude 7d 95%% resets %s\n' "$(date -u -d '+2 days' +%Y-%m-%dT%H:%MZ)" > "$work/spent"
printf 'claude 7d 10%% resets %s\n' "$(date -u -d '+2 days' +%Y-%m-%dT%H:%MZ)" > "$work/available"
printf 'claude unknown\n' > "$work/unknown"
for tier in T2 T3 T4; do
  printf '%s\tclaude\tclaude-opus-5-5\thigh\n' "$tier"
  printf '%s\tclaude-api\tclaude-opus-5-5\thigh\n' "$tier"
  printf '%s\tcodex\tgpt-6-astra\thigh\n' "$tier"
done > "$work/tiers"

cat > "$work/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$STUB_ARTIFACTS/cli.argv"
cat "/proc/$$/environ" > "$STUB_ARTIFACTS/proc.environ"
env > "$STUB_ARTIFACTS/cli.environ"
pid=$$
for ancestor in 0 1 2 3 4 5 6 7 8; do
  cat "/proc/$pid/cmdline" >> "$STUB_ARTIFACTS/process.argv"
  pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status")"
  [ "$pid" -gt 0 ] || break
done
cat > "$STUB_ARTIFACTS/prompt"
format=text
bare=0
settings='{}'
sources=user,project,local
add_dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-format) format="$2"; shift 2 ;;
    --bare) bare=1; shift ;;
    --settings) settings="$2"; shift 2 ;;
    --setting-sources) sources="$2"; shift 2 ;;
    --add-dir) add_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$settings" > "$STUB_ARTIFACTS/settings.json"
printf '%s\n' "$sources" > "$STUB_ARTIFACTS/setting-sources"
printf '%s\n' "$add_dir" > "$STUB_ARTIFACTS/add-dir"
# Model documented settings discovery so env overrides are observable to tests.
helper=''
for source in user project local; do
  case ",$sources," in *",$source,"*) ;; *) continue ;; esac
  case "$source" in
    user) file="$HOME/.claude/settings.json" ;;
    project) file="$PWD/.claude/settings.json" ;;
    local) file="$PWD/.claude/settings.local.json" ;;
  esac
  [ -f "$file" ] || continue
  while IFS= read -r entry; do export "$entry"; done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' "$file")
  helper="$(jq -r '.apiKeyHelper // empty' "$file")"
done
explicit_helper="$(printf '%s' "$settings" | jq -r '.apiKeyHelper // empty')"
[ -z "$explicit_helper" ] || helper="$explicit_helper"
while IFS= read -r entry; do export "$entry"; done < <(printf '%s' "$settings" | jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"')
env > "$STUB_ARTIFACTS/effective.environ"
bash -c 'env' > "$STUB_ARTIFACTS/bash.environ"
if [ -n "$helper" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  if [ -n "$helper" ]; then
    api_key="$(sh -c "$helper")"
  else
    api_key="$ANTHROPIC_API_KEY"
  fi
  [ "$api_key" = "$(cat "$STUB_KEY_FILE")" ] || exit 91
  unset api_key
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 92
  [ "$bare" -eq 0 ] || exit 94
  [ "${CLAUDE_CONFIG_DIR:-}" != "$STUB_LOGIN" ] || exit 93
  printf 'api\n' >> "$STUB_ARTIFACTS/calls"
  result="${STUB_RESULT:-ok}"
else
  printf 'plan\n' >> "$STUB_ARTIFACTS/calls"
  result="${STUB_PLAN_RESULT:-ok}"
fi
if [ "$result" = background_stderr ]; then sleep 3 >/dev/null & fi
# Strings from installed Claude Code 2.1.314, inspected 2026-10-30.
case "$result" in
  credit) message='Credit balance is too low' ;;
  credit_stderr) message='Credit balance too low · Add funds: https://platform.claude.com/settings/billing' ;;
  billing) message='API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}' ;;
  stream_billing|stream_billing_zero) message='Credit balance is too low' ;;
  rate) message='API Error: 429 rate limit' ;;
  overloaded) message='API Error: 529 overloaded' ;;
  limit) message='API Error: 429 usage limit reached' ;;
  native) message="You've hit your 5-hour limit · resets 4pm (UTC)" ;;
  prose) message='Task failed while reviewing quota, 402, billing_error, and hit your usage limit handling' ;;
  generic) message='Unexpected task execution failure' ;;
  *) message='' ;;
esac
if [ -n "$message" ]; then
  if [ "$format" = stream-json ]; then
    jq -nc --arg r "$message" '{type:"assistant",error:"billing_error",message:{content:[{type:"text",text:$r}]}}'
    jq -nc --arg r "$message" '{type:"result",subtype:"error_during_execution",is_error:true,result:$r}'
  elif [ "$result" = credit_stderr ]; then
    printf '%s\n' "$message" >&2
  else
    printf '%s\n' "$message"
  fi
  [ "$result" != stream_billing_zero ] || exit 0
  exit 1
fi
if [ "$format" = stream-json ]; then
  if [ "$result" = echo_env ]; then
    jq -nc --arg result "$(bash -c 'env'); APPROVE" '{type:"result",subtype:"success",is_error:false,result:$result}'
  else
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"APPROVE"}'
  fi
else
  [ "$result" != echo_env ] || bash -c 'env'
  printf 'APPROVE\n'
fi
[ "$result" != echo_env ] || bash -c 'env' >&2
exit 0
STUB
cat > "$work/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex\n' >> "$STUB_ARTIFACTS/calls"
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
cat >/dev/null
printf 'APPROVE\n' > "$out"
STUB
chmod +x "$work/bin/claude" "$work/bin/codex"

passed=0
failed=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'PASS: claude-api: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL: claude-api: %s\n' "$label" >&2
    failed=$((failed + 1))
  fi
}
prepare() {
  artifacts="$work/artifacts/$1"
  mkdir -p "$artifacts/tmp"
  common=(env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work/home" TMPDIR="$artifacts/tmp"
    MMO_POOL_TIERS="$work/tiers" MMO_CLAUDE_API_KEY_FILE="$work/key"
    CLAUDE_CODE_OAUTH_TOKEN=fixture-oauth CLAUDE_CONFIG_DIR="$work/login"
    MMO_LEG_ENV='STUB_ARTIFACTS STUB_KEY_FILE STUB_LOGIN STUB_RESULT STUB_PLAN_RESULT'
    STUB_ARTIFACTS="$artifacts" STUB_KEY_FILE="$work/key" STUB_LOGIN="$work/login")
}
pick() {
  rc=0
  "${common[@]}" bash "$scripts/pool.sh" pick "$@" > "$artifacts/pick" 2> "$artifacts/stderr" || rc=$?
}
run_pool() {
  rc=0
  printf 'bounded task\n' | "${common[@]}" bash "$scripts/pool.sh" run --repo "$work/repo" --timeout 30 \
    --out "$artifacts/out" "$@" > "$artifacts/stdout" 2> "$artifacts/stderr" || rc=$?
}
run_api() {
  rc=0
  printf 'bounded task\n' | "${common[@]}" bash "$scripts/run-claude.sh" --api --mode implement \
    --repo "$work/repo" --timeout 30 --out "$artifacts/out" "$@" > "$artifacts/stdout" 2> "$artifacts/stderr" || rc=$?
}
run_api_with_outcome() {
  rc=0
  printf 'bounded task\n' | "${common[@]}" MMO_OUTCOMES_FILE="$artifacts/outcomes.tsv" \
    bash "$scripts/run-claude.sh" --api --mode implement --repo "$work/repo" --timeout 30 \
    --out "$artifacts/out" "$@" > "$artifacts/stdout" 2> "$artifacts/stderr" || rc=$?
}
has() { grep -Fq -- "$2" "$1"; }
no_api() { ! grep -q $'\tclaude-api\t' "$artifacts/pick"; }
limit() { [ "$rc" -eq 75 ] && has "$artifacts/stderr" 'failure=limit'; }
api_success() { [ "$rc" -eq 0 ] && [ "$(cat "$artifacts/calls" 2>/dev/null)" = api ]; }

check 'each shipped Claude row has an adjacent API row with matching tier/model/effort' \
  awk -F '\t' '
    pending { if ($1 != tier || $2 != "claude-api" || $3 != model || $4 != effort) exit 1; pending=0; pairs++ }
    $2 == "claude" { tier=$1; model=$3; effort=$4; pending=1 }
    END { if (pending || pairs != 4) exit 1 }
  ' "$scripts/pool-tiers.tsv"

for tier in T2 T3 T4; do
  prepare "spent-$tier"
  run_pool --tier "$tier" --allow claude --usage "$work/spent"
  check "$tier spent plan dispatches API through --allow claude" api_success
done

prepare available
pick --tier T3 --usage "$work/available"
check 'available plan removes API from candidates' no_api
run_pool --tier T3 --usage "$work/available"
check 'available plan runs with subscription and never API' \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2")" = plan ]' _ "$rc" "$artifacts/calls"
check 'plan retains default settings discovery and subscription environment' \
  bash -c '[ "$(cat "$1/settings.json")" = "{}" ] && [ "$(cat "$1/setting-sources")" = user,project,local ] && grep -q "^CLAUDE_CODE_OAUTH_TOKEN=fixture-oauth$" "$1/cli.environ"' _ "$artifacts"
prepare prefer-api
pick --tier T3 --usage "$work/available" --prefer claude-api
check 'preference cannot force API while plan is available' no_api
prepare plan-runtime-limit
common+=(STUB_PLAN_RESULT=limit)
run_pool --tier T3 --usage "$work/unknown"
check 'unknown usage and runtime plan limit run plan then API successfully' \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/calls")" = "$(printf "plan\napi")" ] && grep -q "^run-claude: exit=75 failure=limit " "$2/stderr"' _ "$rc" "$artifacts"
for error in native generic; do
  for key in present missing; do
    prepare "plan-$error-$key"
    common+=(STUB_PLAN_RESULT="$error")
    [ "$key" = present ] || common+=(MMO_CLAUDE_API_KEY_FILE="$work/absent-key")
    run_pool --tier T3 --allow claude --usage "$work/unknown"
    expected_rc=1; expected_calls=plan
    if [ "$error" = native ]; then
      expected_rc=75
      if [ "$key" = present ]; then expected_rc=0; expected_calls="$(printf 'plan\napi')"; fi
    fi
    check "$error plan failure with $key key: rc=$expected_rc and expected calls" \
      bash -c '[ "$1" -eq "$2" ] && [ "$(cat "$3/calls")" = "$4" ]' _ "$rc" "$expected_rc" "$artifacts" "$expected_calls"
    if [ "$error" = native ]; then
      check "native plan failure with $key key reports failure=limit" has "$artifacts/stderr" 'run-claude: exit=75 failure=limit'
    fi
  done
done
for error in native generic prose; do
  prepare "plan-stream-$error"
  common+=(STUB_PLAN_RESULT="$error")
  rc=0
  printf 'bounded task\n' | "${common[@]}" bash "$scripts/run-claude.sh" --mode implement \
    --repo "$work/repo" --timeout 30 --out "$artifacts/out" --stream-log "$artifacts/stream" \
    > "$artifacts/stdout" 2> "$artifacts/stderr" || rc=$?
  if [ "$error" = native ]; then
    check 'native failed stream result reports exit 75 failure=limit' limit
  else
    check "$error failed stream result retains exit 1 with no API call" \
      bash -c '[ "$1" -eq 1 ] && [ "$(cat "$2")" = plan ]' _ "$rc" "$artifacts/calls"
  fi
done
prepare plan-runtime-no-usage
common+=(STUB_PLAN_RESULT=limit)
run_pool --tier T3 --allow claude --prefer claude-api
check 'runtime plan limit enables matching API without --usage even with API preference' \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2")" = "$(printf "plan\napi")" ]' _ "$rc" "$artifacts/calls"
for error in rate overloaded; do
  prepare "plan-runtime-$error"
  common+=(STUB_PLAN_RESULT="$error")
  run_pool --tier T3 --usage "$work/unknown"
  check "unknown usage and transient $error never spend API credit" \
    bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/calls")" = "$(printf "plan\ncodex")" ] && grep -q "^run-claude: exit=75 failure=transient " "$2/stderr"' _ "$rc" "$artifacts"
done

for missing in unset missing empty; do
  prepare "key-$missing"
  case "$missing" in
    unset)
      filtered=()
      for entry in "${common[@]}"; do
        case "$entry" in MMO_CLAUDE_API_KEY_FILE=*) ;; *) filtered+=("$entry") ;; esac
      done
      common=("${filtered[@]}")
      ;;
    missing) common+=(MMO_CLAUDE_API_KEY_FILE="$work/absent-key") ;;
    empty) common+=(MMO_CLAUDE_API_KEY_FILE="$work/empty-key") ;;
  esac
  run_api
  check "$missing key returns named unavailable exit 75" \
    bash -c '[ "$1" -eq 75 ] && grep -Fq MMO_CLAUDE_API_KEY_FILE "$2" && [ ! -e "$3" ]' \
      _ "$rc" "$artifacts/stderr" "$artifacts/calls"
done
for invalid in newline multiline carriage-return; do
  prepare "key-$invalid"
  case "$invalid" in
    newline) printf '\n' > "$work/invalid-key" ;;
    multiline) printf 'first\nsecond\n' > "$work/invalid-key" ;;
    carriage-return) printf 'key\r\n' > "$work/invalid-key" ;;
  esac
  common+=(MMO_CLAUDE_API_KEY_FILE="$work/invalid-key")
  run_api
  check "$invalid key fails before launching Claude" \
    bash -c '[ "$1" -eq 75 ] && grep -Fq MMO_CLAUDE_API_KEY_FILE "$2/out.stderr" && [ ! -e "$2/calls" ]' _ "$rc" "$artifacts"
done

prepare missing-key-pick
common+=(MMO_CLAUDE_API_KEY_FILE="$work/absent-key")
pick --tier T3 --usage "$work/spent"
check 'pool availability removes API without a readable key file' no_api

for error in credit credit_stderr billing stream_billing stream_billing_zero; do
  prepare "$error"
  common+=(STUB_RESULT="$error")
  case "$error" in stream_*) run_api --stream-log "$artifacts/stream" ;; *) run_api ;; esac
  check "$error reports failure=limit and exit 75" limit
done
prepare credit-fallthrough
common+=(STUB_RESULT=credit)
run_pool --tier T3 --usage "$work/spent"
check 'credit exhaustion falls through to the next independent provider' \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2")" = "$(printf "api\ncodex")" ] && grep -Fq "claude-api unavailable (exit 75)" "$3"' \
    _ "$rc" "$artifacts/calls" "$artifacts/stderr"

prepare denied
pick --tier T3 --usage "$work/spent" --deny claude
check '--deny claude excludes API for reviewer independence' no_api
prepare api-denied
pick --tier T3 --usage "$work/available" --deny claude-api
check '--deny claude-api excludes plan Claude rows' \
  bash -c '! grep -Fq "$2" "$1"' _ "$artifacts/pick" $'\tclaude\t'
prepare api-denied-spent
pick --tier T3 --usage "$work/spent" --deny claude-api
check '--deny claude-api removes API rows' no_api
prepare api-only
pick --tier T3 --usage "$work/spent" --allow claude-api
check '--allow claude-api admits API rows when plan is spent' \
  bash -c '[ "$(wc -l < "$1")" -eq 1 ] && grep -q "claude-api" "$1"' _ "$artifacts/pick"
prepare api-only-available
pick --tier T3 --usage "$work/available" --allow claude-api
check '--allow claude-api admits plan Claude rows' \
  has "$artifacts/pick" $'\tclaude\t'
prepare review-api-denied
pick --tier T3 --mode review --usage "$work/available" --deny claude-api
check 'review --deny claude-api excludes plan Claude rows' \
  bash -c '! grep -Fq "$2" "$1"' _ "$artifacts/pick" $'\tclaude\t'
prepare review-api
printf 'changed\n' > "$work/repo/file"
run_pool --tier T3 --mode review --base HEAD --allow claude --usage "$work/spent"
check 'API review uses Claude identity and returns a valid verdict' api_success
git -C "$work/repo" checkout -q -- file

prepare background-child
rc=0
timeout 3s bash "$scripts/claude-api-exec.sh" "$work/key" \
  bash -c 'sleep 30 >/dev/null 2>&1 & exit 0' \
  > "$artifacts/stdout" 2> "$artifacts/stderr" || rc=$?
check 'helper exits 0 within three seconds when CLI leaves a background child' test "$rc" -eq 0

prepare inherited-stderr
common+=(STUB_RESULT=background_stderr)
started="$(date +%s%N)"
run_api --timeout 1
elapsed=$(( $(date +%s%N) - started ))
check 'exited CLI descendant holding stderr cannot delay the helper past the leg timeout' \
  bash -c '[ "$1" -eq 0 ] && [ "$2" -lt 2000000000 ]' _ "$rc" "$elapsed"

prepare delayed-helper
cat > "$work/bin/bash" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == */claude-api-exec.sh ]]; then
  touch "$STUB_ARTIFACTS/helper-started"
  sleep 3
fi
exec /bin/bash "$@"
STUB
chmod +x "$work/bin/bash"
started="$(date +%s%N)"
run_api --timeout 1
elapsed=$(( $(date +%s%N) - started ))
rm "$work/bin/bash"
check 'leg timeout covers helper preparation before Claude starts' \
  bash -c '[ "$1" -eq 124 ] && [ "$2" -lt 2000000000 ] && [ -f "$3/helper-started" ] && [ ! -e "$3/calls" ]' _ "$rc" "$elapsed" "$artifacts"

prepare no-newline
bash "$scripts/claude-api-exec.sh" "$work/key" bash -c 'printf x; printf y >&2' \
  > "$artifacts/stdout" 2> "$artifacts/stderr"
check 'helper preserves unterminated stdout and stderr as exactly one byte each' \
  bash -c '[ "$(wc -c < "$1/stdout")" -eq 1 ] && [ "$(cat "$1/stdout")" = x ] && [ "$(wc -c < "$1/stderr")" -eq 1 ] && [ "$(cat "$1/stderr")" = y ]' _ "$artifacts"

for source in user project local; do
  prepare "settings-$source"
  case "$source" in
    user) settings_file="$work/home/.claude/settings.json" ;;
    project) settings_file="$work/repo/.claude/settings.json" ;;
    local) settings_file="$work/repo/.claude/settings.local.json" ;;
  esac
  mkdir -p "$(dirname "$settings_file")"
  printf '%s\n' '{"env":{"ANTHROPIC_AUTH_TOKEN":"settings-token","ANTHROPIC_BASE_URL":"https://settings.invalid"},"apiKeyHelper":"printf wrong-settings-key"}' > "$settings_file"
  run_api
  check "$source credentials and endpoint cannot override the designated file key" \
    bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/calls")" = api ] && ! grep -Eq "^ANTHROPIC_(AUTH_TOKEN|BASE_URL)=" "$2/effective.environ" "$2/bash.environ"' _ "$rc" "$artifacts"
  rm "$settings_file"
done

prepare quoted-key-path
quoted_key="$work/key with '\" \$ metacharacters"
cp "$work/key" "$quoted_key"
common+=(MMO_CLAUDE_API_KEY_FILE="$quoted_key" STUB_KEY_FILE="$quoted_key")
run_api
check 'key file path with spaces and shell metacharacters is read literally' api_success

for format in text stream; do
  prepare "canary-$format"
  common+=(ANTHROPIC_API_KEY=wrong-inherited-key ANTHROPIC_AUTH_TOKEN=wrong-inherited-token
    ANTHROPIC_BASE_URL=https://inherited.invalid
    MMO_LEG_ENV='STUB_ARTIFACTS STUB_KEY_FILE STUB_LOGIN MMO_CLAUDE_API_KEY_FILE CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR ANTHROPIC_*')
  if [ "$format" = stream ]; then run_api --stream-log "$artifacts/stream"; else run_api; fi
  check "$format API authenticates with file key and isolates OAuth/login" api_success
  check "$format API key and inherited auth/endpoint are absent from CLI and Bash environments" \
    bash -c '! grep -zEq "^(MMO_CLAUDE_API_KEY_FILE|ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL))=" "$1/proc.environ" && ! grep -Eq "^(MMO_CLAUDE_API_KEY_FILE|ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL))=" "$1/cli.environ" "$1/effective.environ" "$1/bash.environ"' _ "$artifacts"
  check "$format API uses explicit apiKeyHelper and no discovered settings" \
    bash -c 'jq -e '\''.apiKeyHelper | type == "string" and length > 0'\'' "$1/settings.json" >/dev/null && [ -z "$(cat "$1/setting-sources")" ]' _ "$artifacts"
  check "$format API explicitly loads project instructions with normal tools" \
    bash -c '[ "$(cat "$1/add-dir")" = "$2" ] && jq -e '\''.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD == "1"'\'' "$1/settings.json" >/dev/null && grep -qx "Read,Glob,Grep,Bash,Write,Edit" "$1/cli.argv" && ! grep -qx -- --bare "$1/cli.argv"' _ "$artifacts" "$work/repo"
  check "$format key value is absent from CLI environments and CLI/ancestor argv" \
    bash -c '[ -s "$1/process.argv" ] && ! grep -a -F -q -f "$2" "$1/cli.argv" "$1/process.argv" "$1/proc.environ" "$1/cli.environ" "$1/effective.environ" "$1/bash.environ"' _ "$artifacts" "$work/key"
done
for format in text stream; do
  prepare "echo-env-$format"
  common+=(STUB_RESULT=echo_env)
  if [ "$format" = stream ]; then run_api --stream-log "$artifacts/stream"; else run_api; fi
  check "$format shell env output cannot leak the file key into artifacts" \
    bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/calls")" = api ] && ! grep -r -a -F -q -f "$3" "$2"' \
      _ "$rc" "$artifacts" "$work/key"
done
prepare parent-env
parent_key="${ANTHROPIC_API_KEY-unset}"
parent_oauth="${CLAUDE_CODE_OAUTH_TOKEN-unset}"
run_api
check 'successful API leg leaves parent key and OAuth environment unchanged' \
  test "$rc:${ANTHROPIC_API_KEY-unset}:${CLAUDE_CODE_OAUTH_TOKEN-unset}" = "0:$parent_key:$parent_oauth"
prepare outcome-row
run_api_with_outcome
check 'successful --api leg records exactly one Claude API outcome row' \
  bash -c '[ "$(cat "$1/calls")" = api ] && awk -F '\''\t'\'' '\''NR == 1 {if (NF != 13 || $1 != "utc_time") exit 1} NR == 2 {if (NF != 13 || $5 != "claude" || $9 != 0) exit 1} END {if (NR != 2) exit 1}'\'' "$1/outcomes.tsv"' \
    _ "$artifacts"
check 'canary absent from every leg artifact across all cases' \
  bash -c '! grep -r -a -F -q -f "$1" "$2/artifacts" "$2/home" "$2/repo"' _ "$work/key" "$work"

printf 'Claude API regression tests: %s passed, %s failed, %s total.\n' "$passed" "$failed" "$((passed + failed))"
[ "$failed" -eq 0 ]
