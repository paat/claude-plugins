#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

# --- #520 slice 3: classify transient/auth provider failures as exit 75/77 ---
assert_provider_failure_class() {
  local runner="$1" stub_env="$2" stub_val="$3" want_rc="$4" want_failure="$5" label="$6"
  local stream_log="${7:-}"
  local err_file rc=0 stream_file=""
  err_file="$WORK/520-${runner}-${stub_val}${stream_log:+-stream}.err"
  set +e
  case "$runner" in
    claude)
      if [ -n "$stream_log" ]; then
        stream_file="$WORK/520-claude-${stub_val}.stream"
        printf 'handle the rate limit, 429, 503\n' | env "$stub_env=$stub_val" \
          "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
          --model claude-haiku-5-5 --timeout 5 --stream-log "$stream_file" \
          >/dev/null 2> "$err_file"
      else
        printf 'handle the rate limit, 429, 503\n' | env "$stub_env=$stub_val" \
          "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
          --model claude-haiku-5-5 --timeout 5 >/dev/null 2> "$err_file"
      fi
      rc=$?
      ;;
    grok)
      printf 'handle the rate limit, 429, 503\n' | env "$stub_env=$stub_val" \
        "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
        --timeout 5 >/dev/null 2> "$err_file"
      rc=$?
      ;;
    codex)
      printf 'handle the rate limit, 429, 503\n' | env "$stub_env=$stub_val" \
        "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" \
        --timeout 5 >/dev/null 2> "$err_file"
      rc=$?
      ;;
    *) fail "unknown runner $runner" ;;
  esac
  set -e
  [ "$rc" -eq "$want_rc" ] || fail "$label: rc=$rc want $want_rc"
  contains "$err_file" "exit=$want_rc" "$label: exit= line reports $want_rc"
  if [ -n "$want_failure" ]; then
    contains "$err_file" "failure=$want_failure" "$label: failure=$want_failure on exit line"
  else
    absent "$err_file" 'failure=' "$label: no failure= on unreclassified exit"
  fi
}

# Codex: prompt leak must not reclassify; last ERROR: line is authoritative.
assert_provider_failure_class codex STUB_CODEX_RESULT prompt_leak 1 '' \
  'Codex prompt mentioning 429/503 with ERROR: sandbox → stays 1'
assert_provider_failure_class codex STUB_CODEX_RESULT panic_after_prompt_error 1 '' \
  'Codex prompt ERROR: 401 then panic → stays 1'
assert_provider_failure_class codex STUB_CODEX_RESULT auth 77 auth \
  'Codex Reconnecting then 401 Unauthorized → 77'
assert_provider_failure_class codex STUB_CODEX_RESULT transient 75 transient \
  'Codex ERROR: unexpected status 529 Overloaded → 75'
assert_provider_failure_class codex STUB_CODEX_RESULT error 1 '' \
  'Codex unrelated failure normalizes to 1'
assert_provider_failure_class codex STUB_CODEX_RESULT timeout 124 '' \
  'Codex timeout stays 124'
assert_provider_failure_class codex STUB_CODEX_RESULT rate_in_output 0 '' \
  'Codex success with 429 rate limit in output stays 0'

# #717: a token-summary trailer does not hide the final ERROR:; any other trailer does.
assert_codex_reset() {
  local err_file="$1" label="$2" line
  line="$(grep '^run-codex: ' "$err_file")"
  case "$line" in
    *" resets=try again at Nov 20th, 2026 10:18 AM") ;;
    *) fail "$label: reset text missing or not verbatim: $line" ;;
  esac
}
assert_provider_failure_class codex STUB_CODEX_RESULT limit_trailer 75 limit \
  'Codex usage-limit ERROR then tokens-used trailer → 75'
assert_codex_reset "$WORK/520-codex-limit_trailer.err" 'limit trailer'
assert_provider_failure_class codex STUB_CODEX_RESULT limit_last 75 limit \
  'Codex last-line usage limit without reset text stays 75'
absent "$WORK/520-codex-limit_last.err" 'resets=' \
  'Codex usage limit without reset text adds no resets= field'
assert_provider_failure_class codex STUB_CODEX_RESULT limit_last_reset 75 limit \
  'Codex last-line usage limit with reset text stays 75'
assert_codex_reset "$WORK/520-codex-limit_last_reset.err" 'last-line limit'
assert_provider_failure_class codex STUB_CODEX_RESULT limit_trailer_plain 75 limit \
  'Codex usage limit, blank lines, and token trailer → 75'
absent "$WORK/520-codex-limit_trailer_plain.err" 'resets=' \
  'plain usage-limit trailer adds no resets= field'
assert_provider_failure_class codex STUB_CODEX_RESULT recovered_after_limit 1 '' \
  'Codex usage-limit ERROR followed by a later panic stays 1'
assert_provider_failure_class codex STUB_CODEX_RESULT auth_trailer 77 auth \
  'Codex 401 ERROR then token trailer → 77'
absent "$WORK/520-codex-auth_trailer.err" 'resets=' \
  'auth trailer does not carry a limit reset field'
assert_provider_failure_class codex STUB_CODEX_RESULT reconnect_trailer 1 '' \
  'Codex Reconnecting line then token trailer stays 1'
assert_provider_failure_class codex STUB_CODEX_RESULT limit_bad_trailer 1 '' \
  'Codex usage limit followed by tokens used and a non-number stays 1'
pass '#717: Codex final ERROR classifies through a token summary; other trailers do not'

# Claude stream-json: classify from api_error_status on non-zero provider exit.
assert_provider_failure_class claude STUB_CLAUDE_RESULT transient 75 transient \
  'Claude stream-json api_error_status 529 → 75' stream
assert_provider_failure_class claude STUB_CLAUDE_RESULT auth 77 auth \
  'Claude stream-json api_error_status 401 → 77' stream

# Claude text: last stdout line with API Error: NNN only.
assert_provider_failure_class claude STUB_CLAUDE_RESULT auth 77 auth \
  'Claude text API Error: 401 → 77'
assert_provider_failure_class claude STUB_CLAUDE_RESULT api_error_not_last 1 '' \
  'Claude text earlier API Error: 529 but last line unrelated → stays 1'
assert_provider_failure_class claude STUB_CLAUDE_RESULT api_error_in_output 0 '' \
  'Claude success with API Error: 529 in output stays 0'
assert_provider_failure_class claude STUB_CLAUDE_RESULT error 1 '' \
  'Claude unrelated failure normalizes to 1'
assert_provider_failure_class claude STUB_CLAUDE_RESULT timeout 124 '' \
  'Claude timeout stays 124'
assert_provider_failure_class claude STUB_CLAUDE_RESULT rate_in_output 0 '' \
  'Claude success with 429 rate limit in output stays 0'

# Grok: whole stderr; real not-signed-in + 429 forms.
assert_provider_failure_class grok STUB_GROK_RESULT auth 77 auth \
  'Grok Not signed in → 77'
assert_provider_failure_class grok STUB_GROK_RESULT transient 75 transient \
  'Grok 429 Too Many Requests → 75'
assert_provider_failure_class grok STUB_GROK_RESULT error 1 '' \
  'Grok unrelated failure normalizes to 1'
assert_provider_failure_class grok STUB_GROK_RESULT timeout 124 '' \
  'Grok timeout stays 124'
assert_provider_failure_class grok STUB_GROK_RESULT rate_in_output 0 '' \
  'Grok success with 429 rate limit in output stays 0'
pass '#520 slice 3: runners classify transient/auth failures as 75/77; never model output'

# run-qwen-local: one GPU slot, refuse instead of queue (exit 75 → route to Grok)
mmo_ensure_qwen_stub

# no wrapper installed → unavailable, not an error to debug
rc=0
MMO_QWEN_LOCAL_RUN="$WORK/does-not-exist" HOME="$WORK" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "missing local wrapper exits 75 (got $rc)"
pass 'run-qwen-local: missing wrapper exits 75'

# review mode requires a base (plan mode has no shell to run git)
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "review without --base exits 2 (got $rc)"
pass 'run-qwen-local: review without --base is a usage error'

# review mode forwards plan mode + the diff range to the wrapper
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD~1..HEAD' "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "review dispatch succeeded (got $rc)"
contains "$QL_WRAPPER_ARGV" '--approval-mode' 'review dispatch passes --approval-mode'
contains "$QL_WRAPPER_ARGV" 'plan' 'review dispatch pins plan mode'
contains "$QL_WRAPPER_ARGV" '--diff-file' 'review dispatch hands over the validated patch'
contains "$QL_WRAPPER_ARGV" '--max-wall-time' 'review dispatch passes a qwen wall-time limit'
contains "$QL_WRAPPER_ARGV" '840s' 'default timeout reserves 60 seconds outside qwen'
pass 'run-qwen-local: review dispatch is read-only with the diff'

PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" --timeout 3600 "task" >/dev/null 2>&1
contains "$QL_WRAPPER_ARGV" '--max-wall-time' 'dispatch passes a qwen wall-time limit'
contains "$QL_WRAPPER_ARGV" '3540s' 'large timeout reserves 60 seconds outside qwen'
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" --timeout 100 "task" >/dev/null 2>&1
contains "$QL_WRAPPER_ARGV" '50s' 'small timeout reserves half for qwen wall time'
pass 'run-qwen-local: timeout reserves a monotonic qwen wall-time margin'

# Every runner's implement leg gets the one shared preamble, Codex and local Qwen included.
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "QWEN_TASK_MARKER" >/dev/null 2>&1 || :
printf 'CODEX_TASK_MARKER\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" --timeout 5 >/dev/null 2>&1 || :
for preamble_file in "$WORK/qwen-stdin.txt" "$WORK/codex.prompt"; do
  exact_line "$preamble_file" 'You are one fresh, bounded implementation worker.' "shared preamble opens $preamble_file"
  exact_line "$preamble_file" 'Make reasonable assumptions, state them in your final message, and finish the task; do not stop to ask questions or propose next steps.' "no-questions line reaches $preamble_file"
  exact_line "$preamble_file" 'Never weaken, skip or special-case a test to make it pass; if a requirement cannot be met, say so in your final message.' "test-integrity line reaches $preamble_file"
  exact_line "$preamble_file" '## Task packet' "task packet heading in $preamble_file"
done
contains "$WORK/qwen-stdin.txt" 'QWEN_TASK_MARKER' 'Qwen packet follows the preamble'
contains "$WORK/codex.prompt" 'CODEX_TASK_MARKER' 'Codex packet follows the preamble'
[ "$(grep -l 'fresh, bounded implementation worker' "$PLUGIN_ROOT"/scripts/run-*.sh | wc -l)" -eq 0 ] || fail 'runners call mmo_implement_prompt instead of copying the preamble'
[ "$(grep -l 'mmo_implement_prompt' "$PLUGIN_ROOT"/scripts/run-*.sh | wc -l)" -eq 7 ] || fail 'all seven implement runners use mmo_implement_prompt'
pass 'shared implement preamble reaches Codex and local Qwen'

rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" QL_STUB_EXIT=55 \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>"$WORK/qwen-budget.err" || rc=$?
[ "$rc" -eq 55 ] || fail "qwen budget exit stays 55 (got $rc)"
contains "$WORK/qwen-budget.err" 'budget exceeded' 'qwen budget exit has a named diagnostic'
pass 'run-qwen-local: qwen run budget exit is reported and preserved'

rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" QL_STUB_EXIT=55 QL_STUB_ERR='503 Service Unavailable' \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 55 ] || fail "qwen budget exit with provider stderr stays 55 (got $rc)"
pass 'run-qwen-local: qwen budget exit ignores provider-like stderr'

rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" QL_STUB_EXIT=143 \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>"$WORK/qwen-term.err" || rc=$?
[ "$rc" -eq 124 ] || fail "qwen wrapper TERM normalizes to timeout (got $rc)"
contains "$WORK/qwen-term.err" 'exit=124' 'qwen wrapper TERM reports timeout'
pass 'run-qwen-local: wrapper exit 143 becomes timeout 124'

rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  QL_STUB_EXIT=75 QL_STUB_ERR='llama.cpp down or unreachable' \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "qwen wrapper unavailable exit stays 75 (got $rc)"
pass '#698: qwen wrapper unavailable exit stays 75'

# implement mode is write-capable
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1
contains "$QL_WRAPPER_ARGV" '--yolo' 'implement dispatch passes --yolo'
absent "$QL_WRAPPER_ARGV" '--model' 'the default route leaves the model to the served one'
pass 'run-qwen-local: implement dispatch is write-capable'

# A pinned id reaches the wrapper unchanged.
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" --model pinned-id "task" >/dev/null 2>&1
[ "$(grep -x -A1 -- '--model' "$QL_WRAPPER_ARGV" | tail -n1)" = pinned-id ] || fail 'a pinned model reaches the wrapper'
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" --model '' "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an empty --model is a usage error (got $rc)"
pass 'run-qwen-local: --model default|ID reaches the wrapper only as a pin'

# an endpoint that does not answer at all is unavailable, not a hard failure
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" \
  QL_STUB_BASE="http://127.0.0.1:9999/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "unreachable endpoint exits 75 (got $rc)"
pass 'run-qwen-local: an unreachable endpoint exits 75'

# a request already on the GPU (even one we did not start) means busy
cat > "$WORK/bin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *"/slots") printf '%s\n' '[{"id":0,"is_processing":true}]'; printf '%s\n' '200'; exit 0 ;;
  esac
done
exit 7
CURLSTUB
chmod +x "$WORK/bin/curl"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" \
  QL_STUB_BASE="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "in-flight request on /slots exits 75 (got $rc)"
pass 'run-qwen-local: a request already on the GPU exits 75'
# Restore an idle stub immediately: a later case must never run with no curl.
cat > "$WORK/bin/curl" <<'IDLEAGAIN'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *slots) printf '%s\n' '[{"id":0,"is_processing":false}]'; printf '%s\n' '200' ;;
  *) exit 7 ;;
esac
IDLEAGAIN
chmod +x "$WORK/bin/curl"

# a held lock means the slot is taken: refuse with 75 rather than queue
if command -v flock >/dev/null 2>&1; then
  lock_url="http://127.0.0.1:9/v1"
  # same normalization as the runner: strip a trailing slash and a /v1 suffix
  lock_norm="${lock_url%/}"; lock_norm="${lock_norm%/v1}"
  lock_key="$(printf '%s' "$lock_norm" | cksum | awk '{print $1 "-" $2}')"
  lock_path="${TMPDIR:-/tmp}/mmo-qwen-local-$(id -u)/${lock_key}.lock"
  mkdir -p "$(dirname "$lock_path")"
  exec 8>"$lock_path"
  flock -n 8 || fail 'test could not take the lock first'
  rc=0
  PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="$lock_url" \
    bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
  exec 8>&-
  [ "$rc" -eq 75 ] || fail "busy slot exits 75 (got $rc)"
  pass 'run-qwen-local: a taken slot exits 75 instead of queueing'
fi

# the wrapper must not inherit the slot lock: a process it leaves behind must not hold the slot
if command -v flock >/dev/null 2>&1; then
  cat > "$WORK/bin/qwen-sleeper.sh" <<WRAP
#!/usr/bin/env bash
case "\${1:-}" in --help|--print-base) exec "$WORK/bin/qwen-wrapper.sh" "\$@" ;; esac
setsid sleep 30 </dev/null >/dev/null 2>&1 &
printf '%s\n' "\$!" > "$WORK/qwen-sleeper.pid"
cat > /dev/null
printf '%s\n' 'done'
WRAP
  chmod +x "$WORK/bin/qwen-sleeper.sh"
  for attempt in 1 2; do
    rc=0
    PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-sleeper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
      bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>"$WORK/qwen-sleeper.err" || rc=$?
    kill "$(cat "$WORK/qwen-sleeper.pid" 2>/dev/null)" 2>/dev/null || true
    [ "$rc" -eq 0 ] || fail "dispatch $attempt after a wrapper that leaves a process behind exits 0 (got $rc)"
    absent "$WORK/qwen-sleeper.err" 'holds the slot' "dispatch $attempt does not see a slot held by a leftover process"
  done
  pass 'run-qwen-local: a process the wrapper leaves behind does not hold the slot'
fi
# --out /dev/stdout behaves like the sibling runners: body on stdout, exit 0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" --out /dev/stdout "task" 2>"$WORK/qwen-devout.err" | cat > "$WORK/qwen-devout.out"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "qwen --out /dev/stdout exits 0 (got ${PIPESTATUS[0]})"
[ "$(grep -c '^APPROVE$' "$WORK/qwen-devout.out")" -eq 1 ] || fail 'qwen --out /dev/stdout puts the body on stdout once'
pass 'run-qwen-local: --out /dev/stdout exits 0 with the body on stdout'

# Contract test: dispatch through the REAL wrapper (stubbed qwen + curl), so a
# flag-name mismatch between the two plugins fails here instead of at runtime.
real_wrapper=""
for candidate in "$PLUGIN_ROOT/../subagent-local-qwen3.8-27b/scripts/subagent-local-qwen3.8-27b-run.sh" \
  "${HOME}"/.claude/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh; do
  [ -x "$candidate" ] && real_wrapper="$candidate" && break
done
if [ -n "$real_wrapper" ]; then
  contract_bin="$WORK/contract-bin"
  mkdir -p "$contract_bin"
  cat > "$contract_bin/qwen" <<'QWENSTUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "Usage: qwen --yolo --approval-mode --output-style --exclude-tools --max-session-turns --max-wall-time --append-system-prompt --include-directories"
  exit 0
fi
printf '%s\n' "$@" > "$QL_CONTRACT_ARGV"
printf '%s\n' '[{"type":"result","result":"CONTRACT OK"}]'
exit 0
QWENSTUB
  cat > "$contract_bin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */models)
    printf '%s\n' '{"data":[{"id":"gpt-oss-120b","meta":{"n_ctx":32768}}]}'
    printf '%s\n' '200'
    ;;
  */slots)
    printf '%s\n' '[{"id":0,"is_processing":false}]'
    printf '%s\n' '200'
    ;;
  *) exit 7 ;;
esac
CURLSTUB
  chmod +x "$contract_bin/qwen" "$contract_bin/curl"
  export QL_CONTRACT_ARGV="$WORK/contract-argv.txt"
  rc=0
  PATH="$contract_bin:$PATH" MMO_QWEN_LOCAL_RUN="$real_wrapper" \
    OPENAI_BASE_URL="http://127.0.0.1:8000/v1" HOME="$WORK" \
    bash "$QL_RUN" --mode implement --repo "$qwen_repo" --timeout 30 "task" >/dev/null 2>"$WORK/contract.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "real-wrapper implement dispatch succeeds (got $rc)"
  contains "$QL_CONTRACT_ARGV" '--yolo' 'real wrapper received implement mode'
  pass 'run-qwen-local: real wrapper accepts the flags this runner sends'
  # Whatever the endpoint serves is the default, and the exit line names it.
  [ "$(grep -x -A1 -- '-m' "$QL_CONTRACT_ARGV" | tail -n1)" = gpt-oss-120b ] || fail 'the leg runs the served non-Qwen model'
  contains "$WORK/contract.err" 'run-qwen-local: exit=0 model=gpt-oss-120b' 'the exit line names the served model'
  # An explicit pin the endpoint does not serve still refuses, as unavailable.
  : > "$QL_CONTRACT_ARGV"
  rc=0
  PATH="$contract_bin:$PATH" MMO_QWEN_LOCAL_RUN="$real_wrapper" \
    OPENAI_BASE_URL="http://127.0.0.1:8000/v1" HOME="$WORK" \
    bash "$QL_RUN" --mode implement --repo "$qwen_repo" --timeout 30 --model Qwen3.8-27B-UD-Q6_K_XL-coding "task" \
    >/dev/null 2>"$WORK/contract.err" || rc=$?
  [ "$rc" -eq 75 ] || fail "a pinned model the endpoint does not serve exits 75 (got $rc)"
  contains "$WORK/contract.err" 'does not serve the requested model' 'a mismatched pin is named'
  contains "$WORK/contract.err" 'model=Qwen3.8-27B-UD-Q6_K_XL-coding' 'a refused leg names the requested model'
  [ ! -s "$QL_CONTRACT_ARGV" ] || fail 'a mismatched pin never runs qwen'
  pass 'run-qwen-local: the served model is the default; a mismatched pin refuses'
fi

# Restore an idle /slots stub (the busy case removed it).
cat > "$WORK/bin/curl" <<'IDLESTUB2'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *slots) printf '%s\n' '[{"id":0,"is_processing":false}]'; printf '%s\n' '200' ;;
  *) exit 7 ;;
esac
IDLESTUB2
chmod +x "$WORK/bin/curl"

# The documented heredoc form must work: nothing may consume the prompt on stdin.
cat > "$WORK/bin/qwen-wrapper-stdin.sh" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print-base --diff-file --approval-mode --yolo running model'
  exit 0
fi
if [ "${1:-}" = "--print-base" ]; then
  printf '%s\n' "${QL_STUB_BASE:-http://127.0.0.1:9/v1}"
  exit 0
fi
cat > "$QL_WRAPPER_STDIN"
printf '%s\n' 'APPROVE'
exit 0
WRAP
chmod +x "$WORK/bin/qwen-wrapper-stdin.sh"
export QL_WRAPPER_STDIN="$WORK/qwen-stdin.txt"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD~1..HEAD' >/dev/null 2>"$WORK/heredoc.err" <<'PROMPT' || rc=$?
review this heredoc prompt
PROMPT
[ "$rc" -eq 0 ] || fail "heredoc dispatch succeeded (got $rc): $(cat "$WORK/heredoc.err")"
contains "$QL_WRAPPER_STDIN" 'review this heredoc prompt' 'heredoc prompt reaches the wrapper'
contains "$QL_WRAPPER_STDIN" 'APPROVE or NEEDS_WORK' 'review dispatch asks for a terminal verdict'
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" -- "-dash leading prompt" >/dev/null 2>&1
contains "$QL_WRAPPER_STDIN" '-dash leading prompt' 'a dash-leading prompt survives as prompt text'
pass 'run-qwen-local: heredoc prompt, verdict line, and dash-leading prompts reach the wrapper'
# Local Qwen review takes matching harness-adjustment rows before its verdict line; none leaves it unchanged.
printf '%s\n' $'qwen\t*\treview\tQWEN_ADJ_LINE\tev\t2026-11-01' > "$WORK/qwen-adj.tsv"
for qwen_table in shipped "$WORK/qwen-adj.tsv"; do
  rc=0; qwen_table_env=()
  [ "$qwen_table" = shipped ] || qwen_table_env=(MMO_HARNESS_ADJUSTMENTS="$qwen_table")
  printf 'review this prompt\n' | env ${qwen_table_env[@]+"${qwen_table_env[@]}"} PATH="$WORK/bin:$PATH" \
    MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
    bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD~1..HEAD' >/dev/null 2>"$WORK/qwen-adj.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "qwen review with $qwen_table table: $(cat "$WORK/qwen-adj.err")"
  if [ "$qwen_table" = shipped ]; then
    printf 'review this prompt\n\nEnd with one terminal line: APPROVE or NEEDS_WORK.\n' > "$WORK/qwen-adj.want"
  else
    printf 'review this prompt\n\nQWEN_ADJ_LINE\nEnd with one terminal line: APPROVE or NEEDS_WORK.\n' > "$WORK/qwen-adj.want"
  fi
  cmp -s "$WORK/qwen-adj.want" "$QL_WRAPPER_STDIN" || fail "qwen review prompt with $qwen_table table: $(cat "$QL_WRAPPER_STDIN")"
done
pass 'run-qwen-local: review prompt takes harness adjustments and is unchanged without them'

# A review that returns prose without a verdict is not a passing review.
cat > "$WORK/bin/qwen-wrapper-noverdict.sh" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print-base --diff-file --approval-mode --yolo running model'
  exit 0
fi
if [ "${1:-}" = "--print-base" ]; then
  printf '%s\n' "${QL_STUB_BASE:-http://127.0.0.1:9/v1}"
  exit 0
fi
cat >/dev/null
printf '%s\n' 'looks fine to me'
exit 0
WRAP
chmod +x "$WORK/bin/qwen-wrapper-noverdict.sh"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-noverdict.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD~1..HEAD' "review" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 6 ] || fail "verdict-less review exits 6 (got $rc)"
pass 'run-qwen-local: a review without a verdict fails the leg'

# --out is the final message (what meta-orchestration resumes from), and the leg
# ends with the same exit footer as every sibling runner.
out_file="$WORK/qwen-final.txt"
err_file="$WORK/qwen-finish.err"
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD~1..HEAD' --out "$out_file" \
  "review" >/dev/null 2>"$err_file"
exact_line "$out_file" 'APPROVE' '--out holds the final message, not the raw stream'
contains "$err_file" 'run-qwen-local: exit=0' 'leg prints the shared exit footer'
pass 'run-qwen-local: --out and exit footer match the sibling runners'

# A server that reports saturation is busy even when it never sets is_processing.
cat > "$WORK/bin/curl" <<'BUSY503'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *slots) printf '%s\n' 'server busy'; printf '%s\n' '503' ;;
  *) exit 7 ;;
esac
BUSY503
chmod +x "$WORK/bin/curl"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "a 503 from /slots exits 75 (got $rc)"
pass 'run-qwen-local: a saturated server exits 75'

# A server with no /slots route is not evidence of a busy GPU: dispatch proceeds.
cat > "$WORK/bin/curl" <<'NOSLOTS'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *slots) printf '%s\n' 'not found'; printf '%s\n' '404' ;;
  *) exit 7 ;;
esac
NOSLOTS
chmod +x "$WORK/bin/curl"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "an endpoint without /slots still dispatches (got $rc)"
pass 'run-qwen-local: no /slots route still dispatches'

# A missing qwen CLI is the engine being unavailable, not a hard worker failure.
cat > "$WORK/bin/qwen-wrapper-127.sh" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print-base --diff-file --approval-mode --yolo running model'
  exit 0
fi
if [ "${1:-}" = "--print-base" ]; then
  printf '%s\n' "${QL_STUB_BASE:-http://127.0.0.1:9/v1}"
  exit 0
fi
printf '%s\n' 'qwen CLI not found on PATH' >&2
exit 127
WRAP
chmod +x "$WORK/bin/qwen-wrapper-127.sh"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-127.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>"$WORK/qwen-wrapper-127.err" || rc=$?
[ "$rc" -eq 75 ] || fail "a missing qwen CLI exits 75 (got $rc)"
contains "$WORK/qwen-wrapper-127.err" 'qwen CLI not found on PATH' 'a missing qwen CLI surfaces wrapper stderr'
pass 'run-qwen-local: a missing qwen CLI exits 75'

# An oversized review diff belongs on a bigger-context model, not a truncated local one.
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" MMO_REVIEW_DIFF_MAX_BYTES=10 \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD~1..HEAD' "review" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "an oversized review diff exits 4 like its siblings (got $rc)"
pass 'run-qwen-local: an oversized review diff exits 4'

# An invalid ref and an empty diff are usage problems, not slot unavailability.
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'no-such-ref' "review" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an invalid --base exits 2 (got $rc)"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD' "review" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "an empty diff exits 3 (got $rc)"
pass 'run-qwen-local: review target is gated before the slot is taken'

# Usage errors must not take the GPU slot first.
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "" >/dev/null 2>&1 </dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "an empty prompt is a usage error (got $rc)"
pass 'run-qwen-local: an empty prompt fails before the slot is taken'

# A wrapper too old for --diff-file is unavailable, not a usage error mid-dispatch.
cat > "$WORK/bin/qwen-wrapper-old.sh" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print-base --approval-mode --yolo'
  exit 0
fi
if [ "${1:-}" = "--print-base" ]; then
  printf '%s\n' 'http://127.0.0.1:9/v1'
  exit 0
fi
exit 0
WRAP
chmod +x "$WORK/bin/qwen-wrapper-old.sh"
rc=0
# Isolate cache discovery so an installed compatible wrapper cannot replace this old stub.
HOME="$WORK" PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-old.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || fail "a wrapper without --diff-file exits 75 (got $rc)"
pass 'run-qwen-local: a wrapper missing a required flag exits 75'

# A brand-new untracked file is part of the change under review.
printf 'brand new\n' > "$qwen_repo/untracked-new.txt"
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" QL_WRAPPER_STDIN="$WORK/untracked-stdin.txt" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base 'HEAD' --out "$WORK/untracked-out.txt" \
  "review" >/dev/null 2>&1
rc=$?
rm -f "$qwen_repo/untracked-new.txt"
[ "$rc" -eq 0 ] || fail "untracked-only review still has a diff to review (got $rc)"
pass 'run-qwen-local: untracked files join the review diff'

# A tracked --out is a leg output: clearing it adds nothing to review, so a clean tree has no diff.
qwen_tracked="$WORK/qwen-tracked"; mkdir -p "$qwen_tracked"; git -C "$qwen_tracked" init -q
printf 'QWEN_TRACKED_MARKER\n' > "$qwen_tracked/report.txt"; git -C "$qwen_tracked" add report.txt
git -C "$qwen_tracked" -c user.email=t@t -c user.name=t commit -qm base
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" QL_WRAPPER_STDIN="$WORK/tracked-stdin.txt" \
  bash "$QL_RUN" --mode review --repo "$qwen_tracked" --base 'HEAD' --out "$qwen_tracked/report.txt" \
  "review" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "a tracked --out on a clean tree leaves nothing to review (got $rc)"
[ ! -e "$WORK/tracked-stdin.txt" ] || fail 'the worker is not invoked when only the tracked --out differs'
pass 'run-qwen-local: a tracked --out stays out of the review diff'

# --repo resolves to the git toplevel, and a non-git path is a usage error.
mkdir -p "$qwen_repo/sub/dir"
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" QL_WRAPPER_ARGV="$WORK/toplevel-argv.txt" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo/sub/dir" "task" >/dev/null 2>&1
contains "$WORK/toplevel-argv.txt" "$qwen_repo" 'dispatch uses the repository root'
absent "$WORK/toplevel-argv.txt" 'sub/dir' 'dispatch does not scope the worker to a subdirectory'
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$WORK/not-a-repo-at-all" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a non-git --repo exits 2 (got $rc)"
pass 'run-qwen-local: --repo resolves to the git toplevel'

# A whitespace-only body is not a final message.
cat > "$WORK/bin/qwen-wrapper-blank.sh" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print-base --diff-file --approval-mode --yolo running model'
  exit 0
fi
if [ "${1:-}" = "--print-base" ]; then
  printf '%s\n' 'http://127.0.0.1:9/v1'
  exit 0
fi
cat >/dev/null
printf '\n'
exit 0
WRAP
chmod +x "$WORK/bin/qwen-wrapper-blank.sh"
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-blank.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 5 ] || fail "a whitespace-only final message exits 5 (got $rc)"
pass 'run-qwen-local: a whitespace-only final message exits 5'

# A --base that looks like a git option must be refused, not passed to git diff.
rc=0
PATH="$WORK/bin:$PATH" MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper-stdin.sh" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  bash "$QL_RUN" --mode review --repo "$qwen_repo" --base "--output=$WORK/injected.patch" \
  "review" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an option-shaped --base exits 2 (got $rc)"
[ ! -e "$WORK/injected.patch" ] || fail 'option-shaped --base must not reach git diff'
pass 'run-qwen-local: an option-shaped --base is refused'

# The host normalizes dots in the cached plugin dir name: discovery must find
# subagent-local-qwen3-8-27b as well as subagent-local-qwen3.8-27b.
for cache_name in 'subagent-local-qwen3.8-27b' 'subagent-local-qwen3-8-27b'; do
  cache_home="$WORK/fakehome-$cache_name"
  cache_dir="$cache_home/.claude/plugins/cache/mk/$cache_name/0.5.0/scripts"
  mkdir -p "$cache_dir"
  # Each cached stub records that IT ran, so the assertion cannot pass because some
  # other wrapper on PATH answered.
  marker="$WORK/discovered-$cache_name.txt"
  cat > "$cache_dir/subagent-local-qwen3.8-27b-run.sh" <<WRAP
#!/usr/bin/env bash
if [ "\${1:-}" = "--help" ]; then
  printf '%s\\n' '--print-base --diff-file --approval-mode --yolo running model'
  exit 0
fi
if [ "\${1:-}" = "--print-base" ]; then
  printf '%s\\n' 'http://127.0.0.1:9/v1'
  exit 0
fi
printf '%s\\n' "$cache_name" > "$marker"
cat >/dev/null
printf '%s\\n' 'APPROVE'
exit 0
WRAP
  chmod +x "$cache_dir/subagent-local-qwen3.8-27b-run.sh"
  rc=0
  # $WORK/bin supplies the stub curl (and keeps jq on PATH); the marker below is
  # what proves the cached wrapper ran, not merely that something answered.
  PATH="$WORK/bin:$PATH" HOME="$cache_home" \
    OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
    env -u MMO_QWEN_LOCAL_RUN \
    bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "discovery finds a wrapper cached as $cache_name (got $rc)"
  [ -f "$marker" ] || fail "the wrapper cached as $cache_name is the one that ran"
  exact_line "$marker" "$cache_name" "marker names the cache directory that was used"
done
pass 'run-qwen-local: discovery finds both cached plugin directory spellings'

# The host keeps old versions cached, and 0.4.6 sorts first: a wrapper that does not
# print the running-model line is skipped for the one that does.
cache_home="$WORK/fakehome-mixed"
for v in 0.4.6 0.5.0; do
  cache_dir="$cache_home/.claude/plugins/cache/mk/subagent-local-qwen3-8-27b/$v/scripts"
  mkdir -p "$cache_dir"
  help_text='--print-base --diff-file --approval-mode --yolo'
  [ "$v" = 0.4.6 ] || help_text="$help_text running model"
  cat > "$cache_dir/subagent-local-qwen3.8-27b-run.sh" <<WRAP
#!/usr/bin/env bash
if [ "\${1:-}" = "--help" ]; then printf '%s\\n' '$help_text'; exit 0; fi
if [ "\${1:-}" = "--print-base" ]; then printf '%s\\n' 'http://127.0.0.1:9/v1'; exit 0; fi
printf '%s\\n' '$v' > "$WORK/discovered-mixed.txt"
cat >/dev/null
printf '%s\\n' 'APPROVE'
WRAP
  chmod +x "$cache_dir/subagent-local-qwen3.8-27b-run.sh"
done
rc=0
PATH="$WORK/bin:$PATH" HOME="$cache_home" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  env -u MMO_QWEN_LOCAL_RUN \
  bash "$QL_RUN" --mode implement --repo "$qwen_repo" "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "a mixed-version cache still dispatches (got $rc)"
exact_line "$WORK/discovered-mixed.txt" '0.5.0' 'discovery skips a cached wrapper without the running-model line'
pass 'run-qwen-local: discovery skips stale cached wrapper versions'

# Doc contracts: deleting these silently disables the local route, so pin them.
contains "$PLUGIN_ROOT/skills/meta-orchestration/references/leg-liveness.md" \
  'run-qwen-local.sh' 'leg-liveness keeps the local-Qwen exit-75 exception'
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  'eligible runner (`run-*.sh`)' 'meta-orchestration dispatches the recorded runner (run-*.sh covers the local runner)'
[ -x "$PLUGIN_ROOT/scripts/run-qwen-local.sh" ] || fail 'run-qwen-local.sh matches the run-*.sh dispatch glob'
contains "$PLUGIN_ROOT/skills/route-model-task/references/routing.md" \
  '| Local Qwen | `default` |' 'routing catalog keeps the local engine'
contains "$PLUGIN_ROOT/skills/meta-orchestration/references/review-prompts.md" \
  'run-qwen-local.sh --mode review' 'review-leg rule keeps the local reviewer read-only'
contains "$PLUGIN_ROOT/skills/meta-orchestration/references/review-prompts.md" \
  'cannot run anything' 'review-leg rule says the local lens cannot execute probes'
contains "$PLUGIN_ROOT/skills/meta-orchestration/references/review-prompts.md" \
  'Runner mode per reviewer' 'reviewer runner modes live in one table'
pass 'run-qwen-local: skill and routing contracts are pinned'

