#!/usr/bin/env bash
# Shared harness, stubs, and assertion helpers for multi-model-orchestrator tests.
# Sourced by tests/run-tests.sh.

if [ -n "${MMO_TEST_HELPERS_LOADED:-}" ]; then
  return 0
fi
MMO_TEST_HELPERS_LOADED=1

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/tmp"
export TMPDIR="$WORK/tmp"
# Every runner test writes state inside the disposable fixture, including HOME overrides.
export MMO_OUTCOMES_FILE="$WORK/outcomes.tsv"
export MMO_LEG_CHECKS_FILE="$WORK/leg-checks.tsv"
# Keep default model/effort pin assertions hermetic; explicit MMO_GROK_* overrides still work per-call.
unset MMO_GROK_MODEL MMO_GROK_EFFORT MMO_GROK_MAX_TURNS MMO_GROK_CONTINUE_ON_MAX_TURNS
# Prompt assertions use the shipped harness-adjustments table.
unset MMO_HARNESS_ADJUSTMENTS
# API regressions supply their own dummy key; legacy pool fixtures must not opt in via the host.
unset MMO_CLAUDE_API_KEY_FILE
REAL_GROK="${MMO_TEST_REAL_GROK-$(command -v grok || true)}"
GROK_RESEARCH_TOOLS='web_search,web_fetch'
# ASK-76 dropped this provider; split so the plugin tree never names it outside these regressions.
gone_provider="open""code"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "$3"; }
absent() { ! grep -F -- "$2" "$1" >/dev/null || fail "$3"; }
exact_line() { grep -Fx -- "$2" "$1" >/dev/null || fail "$3"; }

. "$PLUGIN_ROOT/scripts/lib-review-verdict.sh"

assert_review_verdict() {
  printf '%s\n' "$1" > "$WORK/review-verdict.txt"
  mmo_has_review_verdict "$WORK/review-verdict.txt" || fail "$2"
}

reject_review_verdict() {
  printf '%s\n' "$1" > "$WORK/review-verdict.txt"
  ! mmo_has_review_verdict "$WORK/review-verdict.txt" || fail "$2"
}


META_CMD="$PLUGIN_ROOT/commands/meta-orchestrate.md"
META_SKILL="$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md"
META_REFS="$PLUGIN_ROOT/skills/meta-orchestration/references"
QL_RUN="$PLUGIN_ROOT/scripts/run-qwen-local.sh"
GATE="$PLUGIN_ROOT/scripts/review-gate.sh"
POOL="$PLUGIN_ROOT/scripts/pool.sh"
LEG_CHECK="$PLUGIN_ROOT/scripts/leg-check.sh"
AGY_RUN="$PLUGIN_ROOT/scripts/run-agy.sh"
MUSE_RUN="$PLUGIN_ROOT/scripts/run-muse.sh"
VIBE_RUN="$PLUGIN_ROOT/scripts/run-vibe.sh"
USAGE_SH="$PLUGIN_ROOT/scripts/usage.sh"
U="$WORK/usage"; mkdir -p "$U/codex/sessions/2026/01/01" "$U/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/agy"; chmod +x "$U/bin/agy"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S; }

expect_muse_line() { # output window used reset_epoch as_of_glob label
  local line reset_stamp now_s
  now_s=$(date +%s)
  reset_stamp=$(jq -nr --argjson t "$4" '$t | strftime("%Y-%m-%dT%H:%MZ")')
  line="$(printf '%s\n' "$1" | grep "^muse $2 " || true)"
  if [ "$now_s" -ge "$4" ]; then
    case "$line" in
      "muse $2 0% (reset at ${reset_stamp} since as-of) as-of "$5) ;;
      *) fail "$6: ${line:-missing}" ;;
    esac
  else
    case "$line" in
      "muse $2 $3% resets ${reset_stamp} in "*" as-of "$5) ;;
      *) fail "$6: ${line:-missing}" ;;
    esac
  fi
}

git -C "$WORK/repo" init -q
git -C "$WORK/repo" config user.email test@example.com
git -C "$WORK/repo" config user.name Test
printf 'before\n' > "$WORK/repo/app.txt"
git -C "$WORK/repo" add app.txt
git -C "$WORK/repo" commit -qm base
printf 'after\n' > "$WORK/repo/app.txt"

cat > "$WORK/bin/codex" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
printf '%s\n' "$@" > "$STUB_CODEX_ARGS"
out=""
: > "$STUB_CODEX_CWD"
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  [ "$1" = -C ] && { printf '%s\n' "$2" > "$STUB_CODEX_CWD"; shift 2; continue; }
  shift
done
cat > "$STUB_CODEX_PROMPT"
[ -z "${STUB_MUTATE:-}" ] || eval "$STUB_MUTATE"
case "${STUB_CODEX_RESULT:-ok}" in
  fake_metadata)
    printf 'tokens used\n999\nERROR: sandbox setup failed\n' >&2
    exit 1
    ;;
  metadata)
    printf 'tokens used\n1,234\n' >&2
    printf 'APPROVE\n' > "$out"
    ;;
  error) exit 23 ;;
  # Real codex exec echoes the prompt on stderr; classify must ignore that noise.
  prompt_leak)
    cat "$STUB_CODEX_PROMPT" >&2
    printf 'ERROR: sandbox setup failed\n' >&2
    exit 1
    ;;
  # Prompt echo can contain ERROR: 401; a later panic must not reclassify (#556).
  panic_after_prompt_error)
    printf 'ERROR: 401 unauthorized\n' >&2
    printf "thread 'main' panicked at 'index out of bounds', src/main.rs:10:5\n" >&2
    exit 1
    ;;
  auth)
    cat "$STUB_CODEX_PROMPT" >&2
    printf 'ERROR: Reconnecting... 5/5\n' >&2
    printf 'ERROR: unexpected status 401 Unauthorized: missing bearer\n' >&2
    exit 1
    ;;
  transient)
    printf 'ERROR: unexpected status 529 Overloaded\n' >&2
    exit 1
    ;;
  # #717: Codex CLI prints the usage-limit ERROR twice, then a token summary.
  limit_trailer)
    apos=$(printf '\342\200\231')
    msg="ERROR: You${apos}ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 20th, 2026 10:18 AM."
    printf '%s\n' "$msg" "$msg" >&2
    printf 'tokens used\n94,032\n' >&2
    exit 1
    ;;
  limit_last)
    printf 'ERROR: You%sve hit your usage limit.\n' "$(printf '\342\200\231')" >&2
    exit 1
    ;;
  limit_last_reset)
    apos=$(printf '\342\200\231')
    printf 'ERROR: You%sve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 20th, 2026 10:18 AM.\n' "$apos" >&2
    exit 1
    ;;
  limit_trailer_plain)
    printf 'ERROR: You%sve hit your usage limit.\n\n' "$(printf '\342\200\231')" >&2
    printf 'tokens used\n\n10\n\n' >&2
    exit 1
    ;;
  recovered_after_limit)
    printf 'ERROR: You%sve hit your usage limit. try again at Nov 20th, 2026 10:18 AM.\n' "$(printf '\342\200\231')" >&2
    printf "thread 'main' panicked at 'index out of bounds', src/main.rs:10:5\n" >&2
    exit 1
    ;;
  auth_trailer)
    printf 'ERROR: Reconnecting... 5/5\n' >&2
    printf 'ERROR: unexpected status 401 Unauthorized: missing bearer\n' >&2
    printf 'tokens used\n50\n' >&2
    exit 1
    ;;
  reconnect_trailer)
    printf 'ERROR: unexpected status 401 Unauthorized: missing bearer\n' >&2
    printf 'ERROR: Reconnecting... 5/5\n' >&2
    printf 'tokens used\n50\n' >&2
    exit 1
    ;;
  limit_bad_trailer)
    printf 'ERROR: You%sve hit your usage limit. try again at Nov 20th, 2026 10:18 AM.\n' "$(printf '\342\200\231')" >&2
    printf 'tokens used\nnot-a-number\n' >&2
    exit 1
    ;;
  timeout) exit 124 ;;
  rate_in_output) printf 'docs mentioned 429 rate limit\nAPPROVE\n' > "$out" ;;
  empty) : > "$out" ;;
  # Exit 0 without writing --out: simulates a silent no-op dispatch.
  missing) exit 0 ;;
  progress) : > "$out"; printf 'I will inspect the diff.\n' ;;
  noverdict) printf 'codex-final\n' > "$out" ;;
  approved) printf 'codex findings\nAPPROVED\n' > "$out" ;;
  needs_work_space) printf 'codex findings\nNEEDS WORK\n' > "$out" ;;
  prose_approve) printf 'I cannot approve this change because tests fail.\n' > "$out" ;;
  *) printf 'codex findings\nAPPROVE\n' > "$out" ;;
esac
STUB
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
# Record the working directory the runner actually placed us in.
pwd > "$STUB_CLAUDE_CWD"
cat > "$STUB_CLAUDE_PROMPT"
[ -z "${STUB_MUTATE:-}" ] || eval "$STUB_MUTATE"
format=text
verbose=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-format) format="$2"; shift 2 ;;
    --verbose) verbose=1; shift ;;
    *) shift ;;
  esac
done
# Mirror real Claude: stream-json under -p requires --verbose.
if [ "$format" = stream-json ] && [ "$verbose" -ne 1 ]; then
  printf 'Error: When using --print, --output-format=stream-json requires --verbose\n' >&2
  exit 1
fi
text_for_result() {
  case "${STUB_CLAUDE_RESULT:-ok}" in
    progress) printf 'I will inspect the diff.\n' ;;
    approved) printf 'claude findings\nAPPROVED\n' ;;
    needs_work_space) printf 'claude findings\nNEEDS WORK\n' ;;
    template) printf '**VERDICT:** APPROVE\nREADY TO MERGE — nothing further coming.\n' ;;
    prose_approve) printf 'I cannot approve this change because tests fail.\n' ;;
    rate_in_output) printf 'docs mentioned 429 rate limit\nAPPROVE\n' ;;
    api_error_in_output) printf 'API Error: 529 Overloaded\nAPPROVE\n' ;;
    *) printf 'claude findings\nAPPROVE\n' ;;
  esac
}
if [ "$format" = stream-json ]; then
  case "${STUB_CLAUDE_RESULT:-ok}" in
    metadata)
      printf '%s\n' '{"type":"system","subtype":"init","model":"configured-model"}'
      printf '%s\n' '{"type":"assistant","message":{"model":"served-model","content":[{"type":"text","text":"partial"}]}}'
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"APPROVE","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}'
      ;;
    error) exit 23 ;;
    # Real Claude stream-json API failures exit 1 with is_error on the result event.
    transient)
      printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"api_error_status":529,"result":"API Error: 529 Overloaded"}'
      exit 1
      ;;
    auth)
      printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"api_error_status":401,"result":"API Error: 401 Unauthorized"}'
      exit 1
      ;;
    timeout) exit 124 ;;
    empty) exit 0 ;;
    missing) [ -n "${STUB_UNLINK_OUT:-}" ] && rm -f "$STUB_UNLINK_OUT"; exit 0 ;;
    # Emit events, then sleep past the runner timeout so a kill leaves a live stream.
    live_sleep)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"live partial"}]}}'
      sleep 120
      exit 0
      ;;
    stream_error)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"result","subtype":"error","is_error":true,"result":"provider reported an error"}'
      exit 0
      ;;
    # Valid success result, then a truncated non-JSON line (protocol violation).
    stream_trunc_after)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      jq -nc --arg r "$(text_for_result)" \
        '{type:"result",subtype:"success",is_error:false,result:$r}'
      printf '%s\n' 'truncated{'
      exit 0
      ;;
    # Non-JSON line before a valid success result (protocol violation).
    stream_bad_before)
      printf '%s\n' 'not json at all'
      jq -nc --arg r "$(text_for_result)" \
        '{type:"result",subtype:"success",is_error:false,result:$r}'
      exit 0
      ;;
    # Success result event with no string .result field.
    stream_null_result)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false}'
      exit 0
      ;;
    # Success result with a non-string .result (must not coerce into --out).
    stream_number_result)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":42}'
      exit 0
      ;;
    # Success with empty-string .result (must not bypass the empty-artifact guard).
    stream_empty_result)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":""}'
      exit 0
      ;;
    # Valid success stream, but replace --out with a directory before the
    # result event so the runner's final redirect fails for every uid (root
    # included). Permission bits alone are bypassed by root.
    stream_out_dir)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      if [ -n "${STUB_LOCK_OUT:-}" ]; then
        rm -f "$STUB_LOCK_OUT"
        mkdir -p "$STUB_LOCK_OUT"
      fi
      jq -nc --arg r "$(text_for_result)" \
        '{type:"result",subtype:"success",is_error:false,result:$r}'
      exit 0
      ;;
    *)
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}'
      jq -nc --arg r "$(text_for_result)" \
        '{type:"result",subtype:"success",is_error:false,result:$r}'
      ;;
  esac
else
  case "${STUB_CLAUDE_RESULT:-ok}" in
    error) exit 23 ;;
    # Real Claude text-mode auth: empty stderr; last stdout line carries API Error.
    auth)
      printf 'Failed to authenticate. API Error: 401 API key is invalid.\n'
      exit 1
      ;;
    api_error_not_last)
      printf 'API Error: 529 Overloaded\nsome unrelated failure\n'
      exit 1
      ;;
    timeout) exit 124 ;;
    empty) exit 0 ;;
    # Unlink --out while the runner's redirect FD is still open so the path is
    # missing after the subshell closes (shell > always creates the file first).
    missing) [ -n "${STUB_UNLINK_OUT:-}" ] && rm -f "$STUB_UNLINK_OUT"; exit 0 ;;
    # Text mode prints nothing until completion — sleep without emitting.
    live_sleep) sleep 120; exit 0 ;;
    stream_error)
      printf 'provider reported an error\n'
      exit 0
      ;;
    stream_trunc_after|stream_bad_before|stream_null_result|stream_number_result|stream_empty_result|stream_out_dir)
      printf 'claude findings\nAPPROVE\n'
      ;;
    progress) printf 'I will inspect the diff.\n' ;;
    approved) printf 'claude findings\nAPPROVED\n' ;;
    needs_work_space) printf 'claude findings\nNEEDS WORK\n' ;;
    template) printf '**VERDICT:** APPROVE\nREADY TO MERGE — nothing further coming.\n' ;;
    prose_approve) printf 'I cannot approve this change because tests fail.\n' ;;
    rate_in_output) printf 'docs mentioned 429 rate limit\nAPPROVE\n' ;;
    api_error_in_output) printf 'API Error: 529 Overloaded\nAPPROVE\n' ;;
    *) printf 'claude findings\nAPPROVE\n' ;;
  esac
fi
STUB
cat > "$WORK/bin/grok" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
printf '%s\n' "$@" > "$STUB_GROK_ARGS"
[ -z "${STUB_MUTATE:-}" ] || eval "$STUB_MUTATE"
[ -z "${STUB_GROK_CALLS:-}" ] || printf '%s\n' "$*" >> "$STUB_GROK_CALLS"
printf '%s\n' "$HOME" > "$STUB_GROK_HOME_ENV"
printf '%s\n' "$GROK_HOME" > "$STUB_GROK_DIR_ENV"
[ ! -f "$GROK_HOME/config.toml" ] || cp "$GROK_HOME/config.toml" "$STUB_GROK_CONFIG"
# Simulate a concurrent host credential refresh while this leg runs.
if [ "${STUB_GROK_HOST_RACE:-0}" = 1 ] && [ -n "${STUB_GROK_HOST_AUTH:-}" ]; then
  printf '{"key":"host-newer"}\n' > "$STUB_GROK_HOST_AUTH"
fi
[ "${STUB_GROK_REFRESH:-0}" != 1 ] || printf '{"key":"new"}\n' > "$GROK_HOME/auth.json"
prompt=""
debug_file=""
requested_tools=""
: > "$STUB_GROK_CWD"
while [ "$#" -gt 0 ]; do
  [ "$1" = --prompt-file ] && { prompt="$2"; shift 2; continue; }
  [ "$1" = --debug-file ] && { debug_file="$2"; shift 2; continue; }
  [ "$1" = --tools ] && { requested_tools="$2"; shift 2; continue; }
  [ "$1" = --cwd ] && { printf '%s\n' "$2" > "$STUB_GROK_CWD"; shift 2; continue; }
  shift
done
[ -n "$prompt" ] && cat "$prompt" > "$STUB_GROK_PROMPT"
formatted_tools="${requested_tools//,/\", \"}"
allowlist_applied="2026-08-27T07:16:41.995595Z DEBUG session.spawn{session_id=fixture client_type=Generic start_type=\"new\"}: xai_grok_agent::builder: tools allowlist applied agent=grok-build-plan allowed=[\"$formatted_tools\"]"
call_n=1
[ -z "${STUB_GROK_CALLS:-}" ] || call_n="$(wc -l < "$STUB_GROK_CALLS")"
debug_mode="${STUB_GROK_DEBUG:-applied}"
[ "$call_n" -le 1 ] || debug_mode="${STUB_GROK_RESUME_DEBUG:-$debug_mode}"
if [ -n "$debug_file" ]; then
  case "$debug_mode" in
    absent) ;;
    empty) : > "$debug_file" ;;
    applied) printf '%s\n' "$allowlist_applied" > "$debug_file" ;;
    info) printf '%s\n' "${allowlist_applied/ DEBUG / INFO }" > "$debug_file" ;;
    trailing_field) printf '%s duration_ms=3\n' "$allowlist_applied" > "$debug_file" ;;
    no_agent) printf '%s\n' "${allowlist_applied/ agent=grok-build-plan/}" > "$debug_file" ;;
    no_span) printf '%s\n' "${allowlist_applied/session.spawn\{session_id=fixture client_type=Generic start_type=\"new\"\}: /}" > "$debug_file" ;;
    nested_spans)
      printf '%s\n' '2026-10-31T06:53:11.583409Z DEBUG startup:startup.session_create:timer{name="session.new_session" otel.name="session.new_session"}:timer{name="session.spawn_session_actor" otel.name="session.spawn_session_actor"}:timer{name="session.spawn" otel.name="session.spawn"}:startup.session_spawn:session.spawn{session_id=fixture client_type=Generic start_type="new"}:startup.spawn_actor.agent_build: xai_grok_agent::builder: tools allowlist applied agent=grok-build-plan allowed=["read_file", "list_dir", "grep"]' > "$debug_file"
      ;;
    counterfeit_span)
      printf '%s\n' '2026-10-31T07:32:49.176829Z DEBUG xai_acp_lib::gateway: xai_grok_agent::builder: tools allowlist applied agent=grok-build-plan allowed=["read_file", "list_dir", "grep"]' > "$debug_file"
      ;;
    reordered_allowed)
      printf '%s\n' '2026-08-27T07:16:41.995595Z DEBUG xai_grok_agent::builder: tools allowlist applied allowed=["grep", "read_file", "list_dir"]' > "$debug_file"
      ;;
    empty_allowed)
      printf '%s\n' '2026-08-27T07:16:41.995595Z DEBUG xai_grok_agent::builder: tools allowlist applied allowed=[]' > "$debug_file"
      ;;
    wrong_allowed)
      printf '%s\n' '2026-08-27T07:16:41.995595Z DEBUG xai_grok_agent::builder: tools allowlist applied allowed=["bash"]' > "$debug_file"
      ;;
    extra_allowed)
      printf '%s\n' '2026-08-27T07:16:41.995595Z DEBUG xai_grok_agent::builder: tools allowlist applied allowed=["read_file", "list_dir", "grep", "bash"]' > "$debug_file"
      ;;
    cross_mode_allowed)
      printf '%s\n' '2026-08-27T07:16:41.995595Z DEBUG xai_grok_agent::builder: tools allowlist applied allowed=["web_search", "web_fetch"]' > "$debug_file"
      ;;
    prompt_warning_applied)
      printf '%s\n' "$allowlist_applied" \
        '2026-08-27T07:16:42.074473Z DEBUG xai_acp_lib::gateway: sending "session/prompt" request: {"text":"tools allowlist had unmappable entries; keeping full grok toolset"}' \
        > "$debug_file"
      ;;
    unmappable)
      printf '%s\n' \
        '2026-08-27T07:16:41.995595Z WARN session.spawn{session_id=fixture client_type=Generic start_type="new"}: xai_grok_agent::builder: tools allowlist had unmappable entries; keeping full grok toolset unresolved=["renamed_tool"]' \
        'sensitive-provider-debug-marker' > "$debug_file"
      ;;
    unresolvable)
      printf '%s\n' "$allowlist_applied" \
        '2026-08-27T07:16:42.000000Z WARN session.spawn{session_id=fixture client_type=Generic start_type="new"}: xai_grok_agent::builder: tools allowlist had unresolvable entries; keeping full grok toolset unresolved=["renamed_tool"]' \
        > "$debug_file"
      ;;
    dropped_clause)
      printf '%s\n' \
        '2026-08-27T07:16:41.995595Z WARN session.spawn{session_id=fixture client_type=Generic start_type="new"}: xai_grok_agent::builder: tools allowlist had unmappable entries unresolved=["renamed_tool"]' \
        > "$debug_file"
      ;;
  esac
fi
if [ "${STUB_GROK_RESULT:-ok}" = maxturns ]; then
  if [ "$call_n" -le "${STUB_GROK_MAXTURNS_FIRST:-999}" ]; then
    if [ -n "${STUB_GROK_TOUCH:-}" ] && { [ -z "${STUB_GROK_TOUCH_ONCE:-}" ] || [ "$call_n" -eq 1 ]; }; then
      printf 'x\n' >> "$STUB_GROK_TOUCH"
    fi
    [ -z "${STUB_GROK_PROGRESS:-}" ] || printf '%s\n' "$STUB_GROK_PROGRESS"
    printf 'Conversation compacted. Max turns reached\nError: max turns reached\n' >&2
    exit 1
  fi
fi
result_mode="${STUB_GROK_RESULT:-ok}"
[ "$call_n" -le 1 ] || result_mode="${STUB_GROK_RESUME_RESULT:-$result_mode}"
case "$result_mode" in
  error) exit 23 ;;
  transient) printf '429 Too Many Requests\n' >&2; exit 1 ;;
  transient503) printf '503 overloaded\n' >&2; exit 1 ;;
  auth)
    printf 'Error: Not signed in. To authenticate without a browser, run: grok login --device-code\n' >&2
    exit 1
    ;;
  empty) exit 0 ;;
  # Unlink --out while the runner's redirect FD is still open so the path is
  # missing after the subshell closes (shell > always creates the file first).
  missing) [ -n "${STUB_UNLINK_OUT:-}" ] && rm -f "$STUB_UNLINK_OUT"; exit 0 ;;
  timeout) printf '%s' "${STUB_GROK_PROGRESS:-}"; exit 124 ;;
  slow_cap)
    printf 'Inspection progress only.\n'
    printf 'Max turns reached\n' >&2
    exec sleep 10
    ;;
  rate_in_output) printf 'docs mentioned 429 rate limit\nAPPROVE\n' ;;
  progress) printf 'Let me inspect the files.\n' ;;
  approved) printf 'grok findings\nAPPROVED\n' ;;
  verdict_approve) printf 'grok findings\nVERDICT: APPROVE\n' ;;
  verdict_needs_work) printf 'grok findings\nVERDICT: NEEDS_WORK\n' ;;
  needs_work_space) printf 'grok findings\nNEEDS WORK\n' ;;
  prose_approve) printf 'This section still needs work before ship.\n' ;;
  # Plain Grok joins assistant messages with no newline (#597).
  glued_verdict) printf '%s' 'The suites passed. Next I will execute touching the worktree.VERDICT: NEEDS_WORK' ;;
  glued_verdict_lower) printf '%s' 'The suites passed. Next I will execute touching the worktree.verdict: needs_work' ;;
  glued_bold_verdict) printf '%s' 'The suites passed. Next I will execute touching the worktree.**VERDICT: APPROVE**' ;;
  glued_bold_prose) printf '%s' 'Do not emit **VERDICT: APPROVE**' ;;
  glued_prose) printf '%s' 'Ship it.I approve.' ;;
  *) printf 'grok findings\nAPPROVE\n' ;;
esac
STUB
chmod +x "$WORK/bin/codex" "$WORK/bin/claude" "$WORK/bin/grok"
export PATH="$WORK/bin:$PATH"
# Legs run under a scrubbed environment; the stubs read their STUB_* settings through it.
export MMO_LEG_ENV='STUB_*'
export STUB_CODEX_ARGS="$WORK/codex.args" STUB_CODEX_PROMPT="$WORK/codex.prompt" STUB_CODEX_CWD="$WORK/codex.cwd"
export STUB_CLAUDE_ARGS="$WORK/claude.args" STUB_CLAUDE_PROMPT="$WORK/claude.prompt" STUB_CLAUDE_CWD="$WORK/claude.cwd"
export STUB_GROK_ARGS="$WORK/grok.args" STUB_GROK_PROMPT="$WORK/grok.prompt" STUB_GROK_CWD="$WORK/grok.cwd"
export STUB_GROK_HOME_ENV="$WORK/grok.home-env" STUB_GROK_DIR_ENV="$WORK/grok.dir-env"
export STUB_GROK_CONFIG="$WORK/grok.config"
export GROK_HOME="$WORK/host-grok"
mkdir -p "$GROK_HOME"


mmo_ensure_qwen_stub() {
  if [ -n "${_MMO_QWEN_STUB_READY:-}" ]; then return 0; fi
  _MMO_QWEN_STUB_READY=1
QL_RUN="$PLUGIN_ROOT/scripts/run-qwen-local.sh"
qwen_repo="$WORK/qwen-repo"
mkdir -p "$qwen_repo"
git -C "$qwen_repo" init -q
printf 'one\n' > "$qwen_repo/f.txt"
git -C "$qwen_repo" add -A
git -C "$qwen_repo" -c user.name=t -c user.email=t@t commit -qm base
printf 'two\n' > "$qwen_repo/f.txt"
git -C "$qwen_repo" -c user.name=t -c user.email=t@t commit -qam change

# stub wrapper records argv and succeeds
cat > "$WORK/bin/qwen-wrapper.sh" <<'WRAP'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print-base --diff-file --approval-mode --yolo running model'
  exit 0
fi
if [ "${1:-}" = "--print-base" ]; then
  printf '%s\n' "${QL_STUB_BASE:-http://127.0.0.1:9/v1}"
  exit 0
fi
printf '%s\n' "$@" > "$QL_WRAPPER_ARGV"
cat > "$QL_WRAPPER_STDIN"
printf '%s\n' 'APPROVE'
printf '%s\n' "${QL_STUB_ERR:-}" >&2
exit "${QL_STUB_EXIT:-0}"
WRAP
chmod +x "$WORK/bin/qwen-wrapper.sh"
export QL_WRAPPER_ARGV="$WORK/qwen-argv.txt" QL_WRAPPER_STDIN="$WORK/qwen-stdin.txt"

cat > "$WORK/bin/curl" <<'IDLESTUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *127.0.0.1:9/*slots) printf '%s\n' '[{"id":0,"is_processing":false}]'; printf '%s\n' '200' ;;
  *) exit 7 ;;
esac
IDLESTUB
chmod +x "$WORK/bin/curl"
}

mmo_ensure_agy_stub() {
  if [ -n "${_MMO_AGY_STUB_READY:-}" ]; then return 0; fi
  _MMO_AGY_STUB_READY=1
AG="$WORK/agy"; mkdir -p "$AG/bin" "$AG/calls"
AGY_RUN="$PLUGIN_ROOT/scripts/run-agy.sh"
cat > "$AG/bin/agy" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
n=$(find "$STUB_AGY_CALLS" -name 'call.*.args' | wc -l)
printf '%s\n' "$@" > "$STUB_AGY_CALLS/call.$n.args"
pwd > "$STUB_AGY_CALLS/call.$n.cwd"
cat > "$STUB_AGY_CALLS/call.$n.stdin"
printf '%s\n' '{"event":"init","init":{}}'
case "$*" in *"${STUB_AGY_TOUCH_MODEL:-}"*) [ -z "${STUB_AGY_TOUCH:-}" ] || printf 'touched\n' >> "$STUB_AGY_TOUCH" ;; esac
case "$*" in
  *"${STUB_AGY_FAIL_MODEL:-<none>}"*)
    jq -cn --arg e "${STUB_AGY_FAIL_MESSAGE:-RESOURCE_EXHAUSTED: quota exceeded}" '{event:"result",result:{status:"ERROR",response:"",error:$e}}'
    exit "${STUB_AGY_EXIT:-1}" ;;
esac
jq -cn --arg r "${STUB_AGY_RESPONSE:-done

APPROVE}" '{event:"result",result:{status:"SUCCESS",response:$r}}'
STUB
chmod +x "$AG/bin/agy"
AR="$AG/repo"; mkdir -p "$AR"; git -C "$AR" init -q
printf 'one\n' > "$AR/f.txt"; git -C "$AR" add f.txt; git -C "$AR" -c user.email=t@t -c user.name=t commit -qm base
agy_env=(env PATH="$AG/bin:$PATH" STUB_AGY_CALLS="$AG/calls")
}

mmo_ensure_muse_stub() {
  if [ -n "${_MMO_MUSE_STUB_READY:-}" ]; then return 0; fi
  _MMO_MUSE_STUB_READY=1
MU="$WORK/muse"; mkdir -p "$MU/bin" "$MU/calls"
MUSE_RUN="$PLUGIN_ROOT/scripts/run-muse.sh"
cat > "$MU/bin/muse" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
n=$(find "$STUB_MUSE_CALLS" -name 'call.*.args' | wc -l)
printf '%s\n' "$@" > "$STUB_MUSE_CALLS/call.$n.args"
pwd > "$STUB_MUSE_CALLS/call.$n.cwd"
prev=""; for a in "$@"; do [ "$prev" != --prompt-file ] || cp "$a" "$STUB_MUSE_CALLS/call.$n.prompt"; prev="$a"; done
[ -z "${STUB_MUSE_TOUCH:-}" ] || printf 'touched\n' >> "$STUB_MUSE_TOUCH"
if [ "${STUB_MUSE_SERVED:-}" = none ]; then
  printf '%s\n' '{"payload_type":"run.model.configured","payload":{}}'
else
  jq -cn --arg m "${STUB_MUSE_SERVED:-muse-spark-1.3}" '{payload_type:"run.model.configured",payload:{model_id:$m}}'
fi
if [ -n "${STUB_MUSE_USAGE:-}" ]; then
  jq -cn --argjson allowance "$STUB_MUSE_USAGE" '{payload_type:"run.usage",payload:{allowance:$allowance}}'
fi
if [ -n "${STUB_MUSE_FAIL:-}" ]; then
  jq -cn --arg r "$STUB_MUSE_FAIL" '{payload_type:"run.terminal.failed",payload:{terminal:"failed",reason:$r,text:""}}'
  printf 'run ended with Failed: %s\n' "$STUB_MUSE_FAIL" >&2
  exit 1
fi
jq -cn --arg t "${STUB_MUSE_RESPONSE:-done

APPROVE}" '{payload_type:"run.terminal.completed",payload:{terminal:"completed",reason:null,text:$t}}'
STUB
chmod +x "$MU/bin/muse"
MR="$MU/repo"; mkdir -p "$MR"; git -C "$MR" init -q
printf 'one\n' > "$MR/f.txt"; git -C "$MR" add f.txt; git -C "$MR" -c user.email=t@t -c user.name=t commit -qm base
muse_env=(env -u MMO_MUSE_MODEL -u MMO_MUSE_EFFORT -u MMO_MUSE_MAX_STEPS PATH="$MU/bin:$PATH" STUB_MUSE_CALLS="$MU/calls")
}

mmo_ensure_vibe_stub() {
  if [ -n "${_MMO_VIBE_STUB_READY:-}" ]; then return 0; fi
  _MMO_VIBE_STUB_READY=1
VB="$WORK/vibe"; mkdir -p "$VB/bin" "$VB/calls"
VIBE_RUN="$PLUGIN_ROOT/scripts/run-vibe.sh"
cat > "$VB/bin/vibe" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
if [ "${1:-}" = --version ]; then printf '%s\n' "${STUB_VIBE_VERSION:-vibe 3.1.3}"; exit 0; fi
n=$(find "$STUB_VIBE_CALLS" -name 'call.*.args' | wc -l)
printf '%s\n' "$@" > "$STUB_VIBE_CALLS/call.$n.args"
pwd > "$STUB_VIBE_CALLS/call.$n.cwd"
export_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt-file) cp "$2" "$STUB_VIBE_CALLS/call.$n.prompt"; shift 2 ;;
    --output-dir) export_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -z "${STUB_VIBE_SLEEP:-}" ] || sleep "$STUB_VIBE_SLEEP"
[ -z "${STUB_VIBE_TOUCH:-}" ] || printf 'touched\n' >> "$STUB_VIBE_TOUCH"
[ -z "${STUB_VIBE_STDERR:-}" ] || printf '%s\n' "$STUB_VIBE_STDERR" >&2
msg() { jq -cn --arg r "$1" --arg t "$2" --arg o "$3" '{type:"message",role:$r,content:[{type:"text",text:$t}],outcome:(if $o == "" then null else {type:$o} end)}'; }
msg user 'the prompt' ''
printf '%s\n' '{"type":"reasoning","text":"private","outcome":{"type":"committed"}}'
msg assistant 'thinking aloud' committed
printf '%s\n' '{"type":"effect","title":"file_system.read_file","state":{"status":"completed"}}'
msg assistant "${STUB_VIBE_RESPONSE-done

APPROVE}" committed
[ -z "${STUB_VIBE_DISCARDED:-}" ] || msg assistant "$STUB_VIBE_DISCARDED" discarded
mkdir -p "$export_dir"
jq -n --arg o "${STUB_VIBE_OUTCOME:-finished}" --arg e "${STUB_VIBE_ERROR:-}" --arg m "${STUB_VIBE_ACTIVE-mistral-large-4-0}" \
  '{outcome:$o,error:(if $e == "" then null else {message:$e,code:null} end),usage:{input_tokens:150,output_tokens:23,total_tokens:173},config:{active_model:$m}}' > "$export_dir/export.json"
exit "${STUB_VIBE_EXIT:-0}"
STUB
chmod +x "$VB/bin/vibe"
VR="$VB/repo"; mkdir -p "$VR"; git -C "$VR" init -q
printf 'one\n' > "$VR/f.txt"; git -C "$VR" add f.txt; git -C "$VR" -c user.email=t@t -c user.name=t commit -qm base
vibe_env=(env -u MMO_VIBE_MODEL -u MMO_VIBE_EFFORT -u MMO_VIBE_MAX_TURNS PATH="$VB/bin:$PATH" STUB_VIBE_CALLS="$VB/calls")
}

mmo_ensure_outcome_repo() {
  if [ -n "${_MMO_OUTCOME_REPO_READY:-}" ]; then return 0; fi
  _MMO_OUTCOME_REPO_READY=1
  mmo_ensure_qwen_stub
  mmo_ensure_agy_stub
  mmo_ensure_muse_stub
OUTCOMES="$WORK/outcome-regressions"
mkdir -p "$OUTCOMES/bin"
# Restore the idle endpoint stub after the busy/error endpoint tests.
cat > "$OUTCOMES/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[{"id":0,"is_processing":false}]' 200
STUB
chmod +x "$OUTCOMES/bin/curl"
outcome_env=(env PATH="$OUTCOMES/bin:$WORK/bin:$AG/bin:$MU/bin:$PATH" \
  STUB_AGY_CALLS="$AG/calls" STUB_MUSE_CALLS="$MU/calls" \
  MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL=http://127.0.0.1:9/v1)
# Worktree basename fallback is deliberately distinct from the parent repository.
outcome_repo="$OUTCOMES/project"
mkdir -p "$outcome_repo"
git -C "$outcome_repo" init -q
printf 'base\n' > "$outcome_repo/app.txt"
git -C "$outcome_repo" add app.txt
git -C "$outcome_repo" -c user.name=t -c user.email=t@t commit -qm base

}
