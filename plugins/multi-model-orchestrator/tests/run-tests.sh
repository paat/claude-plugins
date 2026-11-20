#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/tmp"
export TMPDIR="$WORK/tmp"
# Every runner test writes state inside the disposable fixture, including HOME overrides.
export MMO_OUTCOMES_FILE="$WORK/outcomes.tsv"
export MMO_LEG_CHECKS_FILE="$WORK/leg-checks.tsv"
# Keep default model/effort pin assertions hermetic; explicit MMO_GROK_* overrides still work per-call.
unset MMO_GROK_MODEL MMO_GROK_EFFORT MMO_GROK_MAX_TURNS MMO_GROK_CONTINUE_ON_MAX_TURNS
# API regressions supply their own dummy key; legacy pool fixtures must not opt in via the host.
unset MMO_CLAUDE_API_KEY_FILE
REAL_GROK="${MMO_TEST_REAL_GROK-$(command -v grok || true)}"
GROK_RESEARCH_TOOLS='web_search,web_fetch'

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

# Prefixed and bare terminal verdicts are accepted; prose remains rejected.
assert_review_verdict 'VERDICT: APPROVE' 'VERDICT: APPROVE accepted'
assert_review_verdict 'VERDICT: NEEDS_WORK' 'VERDICT: NEEDS_WORK accepted'
assert_review_verdict ' VERDICT : approved ' 'VERDICT: APPROVED variant accepted'
assert_review_verdict 'VERDICT: NEEDS WORK' 'VERDICT: NEEDS WORK variant accepted'
assert_review_verdict '**VERDICT:** APPROVE' 'Bold VERDICT prefix accepted'
assert_review_verdict '**NEEDS_WORK**' 'Bold bare NEEDS_WORK accepted'
assert_review_verdict 'APPROVE' 'Bare APPROVE remains accepted'
assert_review_verdict 'NEEDS_WORK' 'Bare NEEDS_WORK remains accepted'
reject_review_verdict 'VERDICT: APPROVE | NEEDS_WORK' 'Multiple verdict alternatives rejected'
reject_review_verdict '**VERDICT:** APPROVE | NEEDS_WORK' 'Bold multiple verdict alternatives rejected'
reject_review_verdict 'VERDICT:' 'Incomplete VERDICT prefix rejected'
reject_review_verdict '## VERDICT' 'Heading without verdict token rejected'
reject_review_verdict 'FINAL VERDICT: APPROVE' 'Final verdict prose rejected'
reject_review_verdict 'DO NOT APPROVE' 'Negative approval prose rejected'
reject_review_verdict 'NEEDSWORK' 'Unseparated NEEDSWORK rejected'
reject_review_verdict '- VERDICT: APPROVE' 'List-item verdict rejected'
reject_review_verdict '* VERDICT: APPROVE' 'Asterisk list-item verdict rejected'
reject_review_verdict '* APPROVE' 'Asterisk list-item bare verdict rejected'
reject_review_verdict '> VERDICT: APPROVE' 'Blockquote verdict rejected'
reject_review_verdict '| VERDICT | APPROVE |' 'Table verdict rejected'
reject_review_verdict 'VERDICT: NEEDS_WORK — two issues remain.' 'Verdict with trailing prose rejected'
assert_review_verdict '**VERDICT: APPROVE.**' 'Bold VERDICT with one trailing period accepted'
assert_review_verdict 'VERDICT: NEEDS_WORK.' 'VERDICT: NEEDS_WORK with one trailing period accepted'
printf '%s\n' '**VERDICT: APPROVE.**' > "$WORK/review-verdict.txt"
[ "$(mmo_terminal_verdict "$WORK/review-verdict.txt")" = APPROVE ] || fail 'trailing period classifies as APPROVE'
printf '%s\n' 'VERDICT: NEEDS_WORK.' > "$WORK/review-verdict.txt"
[ "$(mmo_terminal_verdict "$WORK/review-verdict.txt")" = NEEDS_WORK ] || fail 'trailing period classifies as NEEDS_WORK'
reject_review_verdict 'I approve.' 'Prose ending in approve. rejected'
reject_review_verdict 'VERDICT: APPROVE..' 'Two trailing periods rejected'
reject_review_verdict '' 'Empty verdict rejected'
reject_review_verdict 'I would approve this if the tests passed' 'Conditional approval prose rejected'
reject_review_verdict 'This needs work before merge' 'NEEDS WORK prose rejected'
reject_review_verdict 'The verdict depends on whether you approve the tradeoff' 'Verdict discussion prose rejected'
pass 'Verdict gate accepts only template-shaped or bare verdict lines'

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
  timeout) exit 124 ;;
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

printf 'external fact\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode research --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/claude-research.err"
exact_line "$WORK/claude.args" 'WebSearch,WebFetch' 'Claude research grants only web tools'
contains "$WORK/claude.args" 'Bash,Write,Edit,NotebookEdit,Task' 'Claude research denies mutation tools'
contains "$WORK/claude.prompt" 'sources OUTSIDE this repository' 'Claude research prompt carries the external-source contract'
contains "$WORK/claude.prompt" 'evidence tier' 'Claude research prompt carries evidence tiers'
pass 'Claude research has web-only access and an evidence contract'

printf 'external fact\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode research --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-research.err"
absent "$WORK/grok.args" '--disable-web-search' 'Grok research keeps web search enabled'
exact_line "$WORK/grok.args" "$GROK_RESEARCH_TOOLS" 'Grok research grants only web tools'
contains "$WORK/grok.prompt" 'sources OUTSIDE this repository' 'Grok research prompt carries the external-source contract'
[ "$(cat "$WORK/grok.home-env")" != "$HOME" ] || fail 'Grok research HOME isolation'
printf 'repo advice\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-advice-web.err"
contains "$WORK/grok.args" '--disable-web-search' 'Grok non-research mode keeps web search disabled'
pass 'Grok research alone enables web-only tools under the read-only contract'

for debug_case in absent empty; do
  debug_rc=0
  printf 'repo advice\n' | STUB_GROK_DEBUG="$debug_case" "$PLUGIN_ROOT/scripts/run-grok.sh" \
    --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-$debug_case.err" \
    || debug_rc=$?
  [ "$debug_rc" -eq 7 ] || fail "Grok $debug_case allowlist debug file exits $debug_rc instead of 7"
  contains "$WORK/grok-allowlist-$debug_case.err" 'produced no allowlist debug evidence' \
    "Grok $debug_case debug file does not name missing debug evidence"
  absent "$WORK/grok-allowlist-$debug_case.err" 'tool allowlist not enforced' \
    "Grok $debug_case debug file shares the unenforced-allowlist diagnostic"
done

for drift_case in info trailing_field no_agent no_span nested_spans reordered_allowed; do
  drift_rc=0
  printf 'repo advice\n' | STUB_GROK_DEBUG="$drift_case" "$PLUGIN_ROOT/scripts/run-grok.sh" \
    --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-$drift_case.err" \
    || drift_rc=$?
  [ "$drift_rc" -eq 0 ] || fail "Grok rejects applied allowlist variant $drift_case with exit $drift_rc"
done

counterfeit_rc=0
printf 'repo advice\n' | STUB_GROK_DEBUG=counterfeit_span "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-counterfeit.err" \
  || counterfeit_rc=$?
[ "$counterfeit_rc" -eq 7 ] || fail "Grok accepts a non-builder gateway allowlist line with exit $counterfeit_rc"
contains "$WORK/grok-allowlist-counterfeit.err" 'allowlist not enforced by the installed grok CLI' \
  'Grok counterfeit allowlist line does not name allowlist enforcement failure'

for invalid_case in empty_allowed wrong_allowed extra_allowed cross_mode_allowed; do
  invalid_rc=0
  printf 'repo advice\n' | STUB_GROK_DEBUG="$invalid_case" "$PLUGIN_ROOT/scripts/run-grok.sh" \
    --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-$invalid_case.err" \
    || invalid_rc=$?
  [ "$invalid_rc" -eq 7 ] || fail "Grok accepts mismatched allowlist case $invalid_case with exit $invalid_rc"
done

printf 'repo advice\n' | STUB_GROK_DEBUG=prompt_warning_applied "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-prompt.err" \
  || fail 'Grok rejects an applied allowlist because prompt content quotes warning vocabulary'

research_rc=0
printf 'external fact\n' | STUB_GROK_DEBUG=unmappable "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode research --repo "$WORK/repo" --timeout 5 > "$WORK/grok-allowlist-research.out" 2> "$WORK/grok-allowlist-research.err" \
  || research_rc=$?
[ "$research_rc" -ne 0 ] || fail 'Grok research accepts an unenforced tool allowlist'
contains "$WORK/grok-allowlist-research.err" 'allowlist not enforced by the installed grok CLI' \
  'Grok research does not name allowlist enforcement failure'
absent "$WORK/grok-allowlist-research.err" 'sensitive-provider-debug-marker' \
  'Grok research exposes provider debug output'
for debug_fragment in unmappable 'keeping full grok toolset'; do
  absent "$WORK/grok-allowlist-research.err" "$debug_fragment" \
    'Grok research exposes provider debug vocabulary'
done
[ ! -s "$WORK/grok-allowlist-research.out" ] || fail 'Grok research exposes rejected leg output'
research_debug="$(awk 'previous == "--debug-file" { print; exit } { previous = $0 }' "$WORK/grok.args")"
[ -n "$research_debug" ] || fail 'Grok research omits --debug-file'
case "$research_debug" in "$WORK/repo"/*) fail 'Grok debug file is inside the repository' ;; esac
[ ! -e "$research_debug" ] || fail 'Grok debug file survives runner cleanup'

advice_rc=0
printf 'repo advice\n' | STUB_GROK_DEBUG=unresolvable "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-advice.err" \
  || advice_rc=$?
[ "$advice_rc" -ne 0 ] || fail 'Grok advice accepts an unresolvable tool allowlist warning after an applied record'
contains "$WORK/grok-allowlist-advice.err" 'allowlist not enforced by the installed grok CLI' \
  'Grok advice does not name allowlist enforcement failure'

dropped_rc=0
printf 'repo advice\n' | STUB_GROK_DEBUG=dropped_clause "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-dropped.err" \
  || dropped_rc=$?
[ "$dropped_rc" -ne 0 ] || fail 'Grok accepts a warning after the full-toolset clause is dropped'

printf 'repo advice\n' | STUB_GROK_DEBUG=applied "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-applied.err" \
  || fail 'Grok rejects a clean applied allowlist record'

timeout_rc=0
printf 'repo advice\n' | STUB_GROK_DEBUG=unmappable STUB_GROK_RESULT=timeout "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-timeout.err" \
  || timeout_rc=$?
[ "$timeout_rc" -eq 124 ] || fail "Grok allowlist warning changed provider exit 124 to $timeout_rc"
pass 'Grok tool allowlists fail closed without exposing provider diagnostics'

printf 'external fact\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode research --dir "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/codex-research.err"
contains "$WORK/codex.args" 'tools.web_search=true' 'Codex research enables web search'
contains "$WORK/codex.prompt" 'sources OUTSIDE this repository' 'Codex research prompt carries the external-source contract'
contains "$WORK/codex.prompt" 'evidence tier' 'Codex research prompt carries evidence tiers'
codex_research_root="$(awk 'previous == "-C" { print; exit } { previous = $0 }' "$WORK/codex.args")"
[ -n "$codex_research_root" ] || fail 'Codex research passes a working root'
[ "$codex_research_root" != "$WORK/repo" ] || fail 'Codex research working root is outside the repo'
[ ! -e "$codex_research_root" ] || fail 'Codex research working root is removed on exit'
printf 'implementation task\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/codex-implement-web.err"
absent "$WORK/codex.args" 'tools.web_search=true' 'Codex non-research mode keeps web search disabled'
codex_implement_root="$(awk 'previous == "-C" { print; exit } { previous = $0 }' "$WORK/codex.args")"
[ "$codex_implement_root" = "$WORK/repo" ] || fail 'Codex implement uses the repo working root'
pass 'Codex research uses a cleaned scratch root; implement uses the repo root'

if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode unknown --repo "$WORK/repo" >/dev/null 2>&1; then
  fail 'unknown Claude mode rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode unknown --repo "$WORK/repo" >/dev/null 2>&1; then
  fail 'unknown Grok mode rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode unknown --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'unknown Codex mode rejected'
fi
pass 'All runners reject unknown modes'
for r in claude grok; do
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode unknown --repo "$WORK/repo" >/dev/null 2>"$WORK/$r-unk.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "run-$r unknown mode exits 2 (got $rc)"
  contains "$WORK/$r-unk.err" 'probe' "run-$r unknown-mode error lists probe"
done

# --- --mode probe: Claude and Grok keep the shell, enforce a verdict, and forbid repository writes ---
probe_app="$(cat "$WORK/repo/app.txt")"
for r in claude grok; do
  rc=0; printf 'probe it\n' | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>"$WORK/$r-probe.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "run-$r probe with APPROVE exits 0 (got $rc): $(cat "$WORK/$r-probe.err")"
  contains "$WORK/$r.prompt" 'verifies by execution' "$r probe prompt carries the execute-probe contract"
  rc=0; printf 'probe it\n' | env "STUB_${r^^}_RESULT=progress" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>"$WORK/$r-probe.err" || rc=$?
  [ "$rc" -eq 6 ] || fail "run-$r probe without a verdict exits 6 (got $rc)"
  contains "$WORK/$r-probe.err" 'probe completed without APPROVE or NEEDS_WORK' "run-$r names the missing probe verdict"
done
rc=0; printf 'probe it\n' | STUB_MUTATE="printf changed >> '$WORK/repo/app.txt'" "$PLUGIN_ROOT/scripts/run-claude.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>"$WORK/claude-probe.err" || rc=$?
printf '%s\n' "$probe_app" > "$WORK/repo/app.txt"
[ "$rc" -eq 7 ] || fail "claude probe that changed the repo exits 7 (got $rc)"
probe_branch="$(git -C "$WORK/repo" symbolic-ref -q --short HEAD)"
rc=0; printf 'probe it\n' | STUB_MUTATE="git -C '$WORK/repo' switch -qc probe-made-branch" "$PLUGIN_ROOT/scripts/run-claude.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>"$WORK/claude-probe.err" || rc=$?
git -C "$WORK/repo" switch -q "$probe_branch"; git -C "$WORK/repo" branch -qD probe-made-branch
[ "$rc" -eq 7 ] || fail "claude probe that switched branch at the same commit exits 7 (got $rc)"
rc=0; printf 'probe it\n' | STUB_MUTATE="printf changed >> '$WORK/repo/app.txt'" "$PLUGIN_ROOT/scripts/run-grok.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>"$WORK/grok-probe.err" || rc=$?
printf '%s\n' "$probe_app" > "$WORK/repo/app.txt"
[ "$rc" -eq 7 ] || fail "grok probe that changed the repo exits 7 (got $rc)"
# Claude probe: shell allowed, writes denied.
printf 'probe it\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>&1 || fail 'claude probe reruns'
claude_allowed="$(awk 'p { print; exit } $0 == "--allowedTools" { p = 1 }' "$WORK/claude.args")"
claude_denied="$(awk 'p { print; exit } $0 == "--disallowedTools" { p = 1 }' "$WORK/claude.args")"
case ",$claude_allowed," in *,Bash,*) ;; *) fail "claude probe allows Bash (got $claude_allowed)" ;; esac
case ",$claude_allowed," in *,Write,*|*,Edit,*) fail "claude probe must not allow Write or Edit (got $claude_allowed)" ;; esac
case ",$claude_denied," in *,Write,*) ;; *) fail "claude probe denies Write (got $claude_denied)" ;; esac
case ",$claude_denied," in *,Edit,*) ;; *) fail "claude probe denies Edit (got $claude_denied)" ;; esac
# Grok probe: no tool allowlist, and the allowlist-debug-evidence check does not apply.
rc=0; printf 'probe it\n' | STUB_GROK_DEBUG=absent "$PLUGIN_ROOT/scripts/run-grok.sh" --mode probe --repo "$WORK/repo" --timeout 10 >/dev/null 2>"$WORK/grok-probe.err" || rc=$?
[ "$rc" -eq 0 ] || fail "grok probe needs no allowlist debug evidence (got $rc): $(cat "$WORK/grok-probe.err")"
absent "$WORK/grok.args" '--tools' 'Grok probe passes no --tools allowlist'
pass 'run-claude and run-grok --mode probe: verdict enforced, repo writes exit 7, shell kept, writes denied'

out="$(printf 'bounded review\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" --effort ultra --timeout 5 2> "$WORK/codex.err")"
[ "$out" = $'codex findings\nAPPROVE' ] || fail 'Codex final output'
contains "$WORK/codex.args" 'gpt-6.2-astra' 'Codex model pin'
contains "$WORK/codex.args" 'model_reasoning_effort="ultra"' 'Codex Ultra pin'
contains "$WORK/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'Codex unrestricted posture'
contains "$WORK/codex.prompt" 'bounded review' 'Codex stdin prompt'
contains "$WORK/codex.prompt" 'semantically read-only reviewer' 'Codex review mode prepends the no-write contract'
codex_review_root="$(awk 'previous == "-C" { print; exit } { previous = $0 }' "$WORK/codex.args")"
[ "$codex_review_root" = "$WORK/repo" ] || fail 'Codex review uses the repo working root'
pass 'Codex runner pins Astra Ultra and stdin prompt'

if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --effort extreme >/dev/null 2>&1; then
  fail 'invalid Codex effort rejected'
fi
pass 'Codex runner rejects unknown effort'

if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-5.5 >/dev/null 2>&1; then
  fail 'earlier Codex model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-6.1-sol --effort ultra >/dev/null 2>&1; then
  fail 'Ultra on non-Astra model rejected'
fi
printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-6.2-sol --effort high --timeout 5 >/dev/null 2>&1 || fail 'gpt-6.2-sol accepted'
contains "$WORK/codex.args" 'gpt-6.2-sol' 'current Sol pin forwarded'
printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-6.1-sol --effort high --timeout 5 >/dev/null 2>&1 || fail 'prior-generation gpt-6.1-sol stays routable'
printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-6-astra --effort ultra --timeout 5 >/dev/null 2>&1 || fail 'prior-generation gpt-6-astra keeps Ultra'
printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-6-sol --effort high --timeout 5 >/dev/null 2>&1 || fail 'prior-generation gpt-6-sol stays routable'
printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-6.1-terra --effort high --timeout 5 >/dev/null 2>&1 || fail 'gpt-6.1-terra accepted'
contains "$WORK/codex.args" 'gpt-6.1-terra' 'current Terra pin forwarded'
pass 'Codex runner enforces the GPT-5.6/GPT-6 catalog and Astra-only Ultra'

if printf x | STUB_CODEX_RESULT=empty "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'Codex empty success rejected'
fi
if printf x | STUB_CODEX_RESULT=progress "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'Codex progress-only review rejected'
fi
if printf x | STUB_CODEX_RESULT=noverdict "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'Codex verdict-free review rejected'
fi
pass 'Codex rejects empty or verdict-free success'

# Accepted terminal verdict variants (case / APPROVED / NEEDS WORK)
out="$(printf x | STUB_CODEX_RESULT=approved "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" 2> "$WORK/codex-approved.err")" || fail 'Codex APPROVED variant accepted'
printf '%s\n' "$out" | grep -Eq 'APPROVED' || fail 'Codex APPROVED body on stdout'
out="$(printf x | STUB_CODEX_RESULT=needs_work_space "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" 2> "$WORK/codex-nw.err")" || fail 'Codex NEEDS WORK variant accepted'
printf '%s\n' "$out" | grep -Eq 'NEEDS WORK' || fail 'Codex NEEDS WORK body on stdout'
out="$(printf x | STUB_CLAUDE_RESULT=approved "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD 2> "$WORK/claude-approved.err")" || fail 'Claude APPROVED variant accepted'
printf '%s\n' "$out" | grep -Eq 'APPROVED' || fail 'Claude APPROVED body on stdout'
out="$(printf x | STUB_CLAUDE_RESULT=template "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD 2> "$WORK/claude-template.err")" || fail 'Claude template verdict accepted'
printf '%s\n' "$out" | grep -Fx '**VERDICT:** APPROVE' >/dev/null || fail 'Claude template verdict body on stdout'
out="$(printf x | STUB_GROK_RESULT=needs_work_space "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD 2> "$WORK/grok-nw.err")" || fail 'Grok NEEDS WORK variant accepted'
printf '%s\n' "$out" | grep -Eq 'NEEDS WORK' || fail 'Grok NEEDS WORK body on stdout'
pass 'Accepted verdict variants APPROVED and NEEDS WORK across runners'

# Format rejection still fails (rc=6) but preserves body in --out and stdout
set +e
out="$(printf x | STUB_CODEX_RESULT=noverdict "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --out "$WORK/codex-format-out.txt" 2> "$WORK/codex-format.err")"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Codex format-reject exit was $rc want 6"
[ "$(cat "$WORK/codex-format-out.txt")" = 'codex-final' ] || fail 'Codex format-reject --out keeps body'
[ "$out" = 'codex-final' ] || fail 'Codex format-reject stdout exposes body'
set +e
out="$(printf x | STUB_CLAUDE_RESULT=progress "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/claude-format-out.txt" 2> "$WORK/claude-format.err")"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Claude format-reject exit was $rc want 6"
[ "$(cat "$WORK/claude-format-out.txt")" = 'I will inspect the diff.' ] || fail 'Claude format-reject --out keeps body'
[ "$out" = 'I will inspect the diff.' ] || fail 'Claude format-reject stdout exposes body'
set +e
out="$(printf x | STUB_GROK_RESULT=progress "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-format-out.txt" 2> "$WORK/grok-format.err")"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Grok format-reject exit was $rc want 6"
[ "$(cat "$WORK/grok-format-out.txt")" = 'Let me inspect the files.' ] || fail 'Grok format-reject --out keeps body'
[ "$out" = 'Let me inspect the files.' ] || fail 'Grok format-reject stdout exposes body'
# Prose containing approve/needs work mid-sentence must still fail (rc=6)
set +e
printf x | STUB_CODEX_RESULT=prose_approve "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --out "$WORK/codex-prose-out.txt" >/dev/null 2> "$WORK/codex-prose.err"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Codex prose-approve exit was $rc want 6"
contains "$WORK/codex-prose-out.txt" 'cannot approve' 'Codex prose body preserved on format reject'
set +e
printf x | STUB_CLAUDE_RESULT=prose_approve "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/claude-prose-out.txt" >/dev/null 2> "$WORK/claude-prose.err"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Claude prose-approve exit was $rc want 6"
set +e
printf x | STUB_GROK_RESULT=prose_approve "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-prose-out.txt" >/dev/null 2> "$WORK/grok-prose.err"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Grok prose needs-work exit was $rc want 6"
set +e
out="$(printf x | STUB_GROK_RESULT=glued_verdict "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-glued.txt" 2> "$WORK/grok-glued.err")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Grok glued VERDICT exit was $rc want 0 ($(cat "$WORK/grok-glued.err"))"
grep -qx 'VERDICT: NEEDS_WORK' "$WORK/grok-glued.txt" || fail 'Grok final output puts a glued verdict on its own line'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/grok-glued.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$gout" = NEEDS_WORK ] || fail "gate reads a glued Grok verdict (got $rc/$gout)"
set +e
out="$(printf x | STUB_GROK_RESULT=glued_verdict_lower "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-glued-lower.txt" 2> "$WORK/grok-glued-lower.err")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Grok lowercase glued verdict exit was $rc want 0 ($(cat "$WORK/grok-glued-lower.err"))"
grep -qx 'verdict: needs_work' "$WORK/grok-glued-lower.txt" || fail 'Grok final output puts a lowercase glued verdict on its own line'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/grok-glued-lower.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$gout" = NEEDS_WORK ] || fail "gate reads a lowercase glued Grok verdict (got $rc/$gout)"
set +e
out="$(printf x | STUB_GROK_RESULT=glued_bold_verdict "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-glued-bold.txt" 2> "$WORK/grok-glued-bold.err")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Grok bold-glued verdict exit was $rc want 0 ($(cat "$WORK/grok-glued-bold.err"))"
exact_line "$WORK/grok-glued-bold.txt" '**VERDICT: APPROVE**' 'Grok final output puts a bold-glued verdict on its own line'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/grok-glued-bold.txt")" || rc=$?
[ "$rc" -eq 0 ] && [ "$gout" = APPROVE ] || fail "gate reads a bold-glued Grok verdict (got $rc/$gout)"
set +e
printf x | STUB_GROK_RESULT=glued_prose "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-glued-prose.txt" >/dev/null 2> "$WORK/grok-glued-prose.err"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Grok glued 'I approve.' exit was $rc want 6"
set +e
printf x | STUB_GROK_RESULT=glued_bold_prose "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/grok-bold-prose.txt" >/dev/null 2> "$WORK/grok-bold-prose.err"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "Grok bold-prose VERDICT exit was $rc want 6"
[ "$(cat "$WORK/grok-bold-prose.txt")" = 'Do not emit **VERDICT: APPROVE**' ] || fail 'Bold prose mentioning VERDICT stays unchanged'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/grok-bold-prose.txt" 2>"$WORK/grok-bold-prose.gate")" || rc=$?
[ "$rc" -eq 2 ] || fail "gate finds no verdict in bold VERDICT prose (got $rc/$gout)"
# Implement and research legs are probe reviews too: the same glued line must reach the gate (#597).
set +e
out="$(printf x | STUB_GROK_RESULT=glued_verdict "$PLUGIN_ROOT/scripts/run-grok.sh" --mode implement --repo "$WORK/repo" \
  --out "$WORK/grok-glued-impl.txt" 2> "$WORK/grok-glued-impl.err")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Grok implement glued VERDICT exit was $rc want 0 ($(cat "$WORK/grok-glued-impl.err"))"
grep -qx 'VERDICT: NEEDS_WORK' "$WORK/grok-glued-impl.txt" || fail 'implement-mode Grok output puts a glued verdict on its own line'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/grok-glued-impl.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$gout" = NEEDS_WORK ] || fail "gate reads an implement-mode glued Grok verdict (got $rc/$gout)"
pass 'Verdict-format rejection preserves body in --out and stdout'
pass 'Prose containing approve/needs work mid-sentence still rejected'
pass 'Grok plain output separates a glued trailing verdict before the gate reads it'
pass 'Grok plain output separates a lowercase glued verdict before the gate reads it'
pass 'Grok plain output separates a bold-glued trailing verdict before the gate reads it'
pass 'Bold prose mentioning a verdict token stays unchanged and is not a verdict'
pass 'Implement-mode Grok output separates a glued trailing verdict before the gate reads it'

mkdir -p "$WORK/out-dest"
printf 'codex out dest\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --out "$WORK/out-dest/codex-final.txt" --timeout 5 \
  > "$WORK/out-dest/codex-stdout.txt" 2> "$WORK/out-dest/codex.err"
[ "$(cat "$WORK/out-dest/codex-final.txt")" = $'codex findings\nAPPROVE' ] || fail 'Codex --out holds final result'
[ "$(cat "$WORK/out-dest/codex-stdout.txt")" = $'codex findings\nAPPROVE' ] || fail 'Codex stdout mirrors final'
[ -f "$WORK/out-dest/codex-final.txt.stream" ] || fail 'Codex default stream beside --out'
contains "$WORK/out-dest/codex.err" "log=$WORK/out-dest/codex-final.txt.stream" 'Codex log= points at stream'
printf 'codex stream-log dest\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --out "$WORK/out-dest/codex-final2.txt" --stream-log "$WORK/out-dest/codex.stream" --timeout 5 \
  >/dev/null 2> "$WORK/out-dest/codex2.err"
[ "$(cat "$WORK/out-dest/codex-final2.txt")" = $'codex findings\nAPPROVE' ] || fail 'Codex --out with --stream-log holds final'
[ -f "$WORK/out-dest/codex.stream" ] || fail 'Codex --stream-log path used'
contains "$WORK/out-dest/codex2.err" "log=$WORK/out-dest/codex.stream" 'Codex log= honors --stream-log'
printf 'claude out dest\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/out-dest/claude-final.txt" --timeout 5 \
  > "$WORK/out-dest/claude-stdout.txt" 2> "$WORK/out-dest/claude.err"
[ "$(cat "$WORK/out-dest/claude-final.txt")" = $'claude findings\nAPPROVE' ] || fail 'Claude --out holds final result'
[ "$(cat "$WORK/out-dest/claude-stdout.txt")" = $'claude findings\nAPPROVE' ] || fail 'Claude stdout mirrors final'
contains "$WORK/out-dest/claude.err" "log=$WORK/out-dest/claude-final.txt" 'Claude log= is --out path'
printf 'grok out dest\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/out-dest/grok-final.txt" --timeout 5 \
  > "$WORK/out-dest/grok-stdout.txt" 2> "$WORK/out-dest/grok.err"
[ "$(cat "$WORK/out-dest/grok-final.txt")" = $'grok findings\nAPPROVE' ] || fail 'Grok --out holds final result'
[ "$(cat "$WORK/out-dest/grok-stdout.txt")" = $'grok findings\nAPPROVE' ] || fail 'Grok stdout mirrors final'
contains "$WORK/out-dest/grok.err" "log=$WORK/out-dest/grok-final.txt" 'Grok log= is --out path'
pass 'Explicit --out destinations hold final results across runners'

if ! (
  cd "$WORK/out-dest"
  printf 'relative claude out\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
    --model claude-haiku-5-5 --out claude-relative.txt --timeout 5 \
    > claude-relative.stdout 2> claude-relative.err
  printf 'relative codex out\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
    --out codex-relative.txt --timeout 5 \
    > codex-relative.stdout 2> codex-relative.err
  printf 'relative grok out\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
    --out grok-relative.txt --timeout 5 \
    > grok-relative.stdout 2> grok-relative.err
); then
  fail 'Relative --out invocation succeeds from caller cwd across runners'
fi
[ -f "$WORK/out-dest/claude-relative.txt" ] || fail 'Claude relative --out resolves at caller cwd'
[ -f "$WORK/out-dest/claude-relative.txt.stderr" ] || fail 'Claude relative --out stderr resolves at caller cwd'
[ ! -e "$WORK/repo/claude-relative.txt" ] || fail 'Claude relative --out stays outside reviewed repo'
[ ! -e "$WORK/repo/claude-relative.txt.stderr" ] || fail 'Claude relative --out stderr stays outside reviewed repo'
[ -f "$WORK/out-dest/codex-relative.txt" ] || fail 'Codex relative --out resolves at caller cwd'
[ -f "$WORK/out-dest/codex-relative.txt.stream" ] || fail 'Codex relative stream resolves at caller cwd'
[ ! -e "$WORK/repo/codex-relative.txt" ] || fail 'Codex relative --out stays outside reviewed repo'
[ ! -e "$WORK/repo/codex-relative.txt.stream" ] || fail 'Codex relative stream stays outside reviewed repo'
[ -f "$WORK/out-dest/grok-relative.txt" ] || fail 'Grok relative --out resolves at caller cwd'
[ -f "$WORK/out-dest/grok-relative.txt.stderr" ] || fail 'Grok relative --out stderr resolves at caller cwd'
[ ! -e "$WORK/repo/grok-relative.txt" ] || fail 'Grok relative --out stays outside reviewed repo'
[ ! -e "$WORK/repo/grok-relative.txt.stderr" ] || fail 'Grok relative --out stderr stays outside reviewed repo'

printf 'dev claude out\n' | STUB_CLAUDE_RESULT=error "$PLUGIN_ROOT/scripts/run-claude.sh" \
  --mode advise --repo "$WORK/repo" --model claude-haiku-5-5 --out /dev/stdout --timeout 5 \
  > "$WORK/out-dest/claude-dev.stdout" 2> "$WORK/out-dest/claude-dev.err" || true
contains "$WORK/out-dest/claude-dev.err" 'log=/dev/stdout' 'Claude preserves /dev/stdout output path'
printf 'dev codex out\n' | STUB_CODEX_RESULT=error "$PLUGIN_ROOT/scripts/run-codex.sh" \
  --mode review --dir "$WORK/repo" --out /dev/stdout \
  --stream-log "$WORK/out-dest/codex-dev.stream" --timeout 5 \
  > "$WORK/out-dest/codex-dev.stdout" 2> "$WORK/out-dest/codex-dev.err" || true
absent "$WORK/codex.args" '/dev/stdout' 'Codex hands the provider a temp file, not the device (#625)'
printf 'dev codex stream\n' | STUB_CODEX_RESULT=error "$PLUGIN_ROOT/scripts/run-codex.sh" \
  --mode review --dir "$WORK/repo" --out "$WORK/out-dest/codex-dev-final.txt" \
  --stream-log /dev/stderr --timeout 5 \
  > "$WORK/out-dest/codex-dev-stream.stdout" 2> "$WORK/out-dest/codex-dev-stream.err" || true
contains "$WORK/out-dest/codex-dev-stream.err" 'log=/dev/stderr' 'Codex preserves /dev/stderr stream path'
printf 'dev grok out\n' | STUB_GROK_RESULT=error "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --out /dev/stdout --timeout 5 \
  > "$WORK/out-dest/grok-dev.stdout" 2> "$WORK/out-dest/grok-dev.err" || true
contains "$WORK/out-dest/grok-dev.err" 'log=/dev/stdout' 'Grok preserves /dev/stdout output path'
pass 'Relative --out stays at caller cwd and device paths remain lexical across runners'

out="$(printf 'acceptance criterion\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD --model claude-opus-5 --effort xhigh --timeout 5 2> "$WORK/claude.err")"
[ "$out" = $'claude findings\nAPPROVE' ] || fail 'Claude final output'
exact_line "$WORK/claude.args" 'claude-opus-5' 'explicit prior-generation pin'
contains "$WORK/claude.args" 'xhigh' 'Opus effort pin'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude YOLO posture'
contains "$WORK/claude.args" 'Bash,Write,Edit,NotebookEdit,Task,WebFetch,WebSearch' 'Opus mutation tools disabled'
exact_line "$WORK/claude.args" '--strict-mcp-config' 'Claude keeps strict MCP config'
exact_line "$WORK/claude.args" '{"mcpServers":{}}' 'Claude default MCP config stays empty'
absent "$WORK/claude.args" 'mcp__' 'Claude default allowed tools omit MCP servers'
contains "$WORK/claude.prompt" 'acceptance criterion' 'Opus review task'
contains "$WORK/claude.prompt" '+after' 'Opus receives diff'
pass 'Claude review is current-model pinned, bounded, and diff-aware'

printf 'new file\n' > "$WORK/repo/new.txt"
printf 'review new file\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode review --repo "$WORK/repo" --base HEAD --timeout 5 >/dev/null 2> "$WORK/opus-untracked.err"
contains "$WORK/claude.prompt" 'new.txt' 'Opus receives untracked file diff'
exact_line "$WORK/claude.args" 'claude-opus-5-5' 'Compatibility wrapper pins Opus 5.5'
pass 'Opus compatibility wrapper uses Opus 5.5 and includes untracked files'

printf 'architecture question\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-advice.err"
contains "$WORK/claude.prompt" 'architecture question' 'Opus advice prompt'
contains "$WORK/claude.prompt" 'Do not implement' 'Opus advice no-write contract'
pass 'Claude advice stays bounded and read-only'

printf 'implementation task\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-implement.err"
contains "$WORK/claude.args" 'Read,Glob,Grep,Bash,Write,Edit' 'Claude implementation tools enabled'
contains "$WORK/claude.args" 'Task,WebFetch,WebSearch,NotebookEdit' 'Claude implementation fan-out and network tools disabled'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude implementation YOLO posture'
contains "$WORK/claude.prompt" 'implementation task' 'Claude implementation task packet'
pass 'Claude implementation is writable, single-agent, and unrestricted'

printf 'quick file map\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-5-5 --timeout 5 >/dev/null 2> "$WORK/haiku.err"
contains "$WORK/claude.args" 'claude-haiku-5-5' 'Haiku current model pin'
absent "$WORK/claude.args" '--effort' 'Haiku must omit unsupported effort flag'
printf 'quick file map\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --timeout 5 >/dev/null 2>&1 || fail 'prior-generation Haiku stays routable'
exact_line "$WORK/claude.args" 'claude-haiku-4-5' 'prior-generation Haiku pin'
absent "$WORK/claude.args" '--effort' 'prior-generation Haiku omits the effort flag'
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-5-5 --effort low >/dev/null 2>&1; then
  fail 'explicit Haiku effort rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus-4-8 >/dev/null 2>"$WORK/claude-unknown-model.err"; then
  fail 'earlier Claude model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus >/dev/null 2>"$WORK/claude-partial-model.err"; then
  fail 'partial Claude model id rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model 'claude-fable-5-1|claude-opus-5-5' >/dev/null 2>"$WORK/claude-pipe-model.err"; then
  fail 'pipe-joined Claude model ids rejected'
fi
contains "$WORK/claude-unknown-model.err" 'claude-fable-5-2|claude-fable-5-1|claude-opus-5-5|claude-sonnet-5-5|claude-fable-5|claude-opus-5|claude-sonnet-5|claude-haiku-5-5|claude-haiku-4-5' 'unsupported model lists the full catalog'
printf 'pin opus 5.5\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus-5-5 --effort high --timeout 5 >/dev/null 2>"$WORK/claude-opus55.err" \
  || fail 'claude-opus-5-5 accepted'
exact_line "$WORK/claude.args" 'claude-opus-5-5' 'claude-opus-5-5 pinned in args'
printf 'pin fable 5.1\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-fable-5-1 --effort max --timeout 5 >/dev/null 2>"$WORK/claude-fable51.err" \
  || fail 'claude-fable-5-1 accepted'
exact_line "$WORK/claude.args" 'claude-fable-5-1' 'claude-fable-5-1 pinned in args'
pass 'Claude runner enforces the current catalog and Haiku effort compatibility'

printf 'one mcp\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 \
  --mcp 'browseros=http://127.0.0.1:9200/mcp' >/dev/null 2>"$WORK/claude-mcp1.err" || fail 'one --mcp accepted'
exact_line "$WORK/claude.args" '--strict-mcp-config' 'one --mcp keeps strict MCP config'
exact_line "$WORK/claude.args" '{"mcpServers":{"browseros":{"type":"http","url":"http://127.0.0.1:9200/mcp"}}}' 'one --mcp config'
exact_line "$WORK/claude.args" 'Read,Glob,Grep,mcp__browseros' 'one --mcp advise allowedTools'
printf 'research mcp\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode research --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 \
  --mcp 'browseros=http://127.0.0.1:9200/mcp' >/dev/null 2>"$WORK/claude-mcp-research.err" || fail 'research --mcp accepted'
exact_line "$WORK/claude.args" 'WebSearch,WebFetch,mcp__browseros' 'research --mcp allowedTools'
printf 'two mcp\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 \
  --mcp 'browseros=http://127.0.0.1:9200/mcp' \
  --mcp 'docs=http://127.0.0.1:9/mcp?q="a\b"' >/dev/null 2>"$WORK/claude-mcp2.err" || fail 'two --mcp accepted'
exact_line "$WORK/claude.args" '{"mcpServers":{"browseros":{"type":"http","url":"http://127.0.0.1:9200/mcp"},"docs":{"type":"http","url":"http://127.0.0.1:9/mcp?q=\"a\\b\""}}}' 'two --mcp config escapes URL'
exact_line "$WORK/claude.args" 'Read,Glob,Grep,Bash,Write,Edit,mcp__browseros,mcp__docs' 'two --mcp implement allowedTools'
reject_mcp() {
  rm -f "$WORK/claude.args"
  set +e
  printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5-5 --mcp "$1" >/dev/null 2>"$WORK/claude-mcp-bad.err"
  local mcp_rc=$?
  set -e
  [ "$mcp_rc" -eq 2 ] || fail "$2 rc=$mcp_rc want 2"
  [ ! -f "$WORK/claude.args" ] || fail "$2 must not invoke claude"
  contains "$WORK/claude-mcp-bad.err" '--mcp' "$2 explains --mcp"
}
reject_mcp 'browseros' 'mcp missing equals'
reject_mcp '=http://127.0.0.1:9200/mcp' 'mcp empty name'
reject_mcp 'browseros=' 'mcp empty url'
reject_mcp 'bad name=http://127.0.0.1:9200/mcp' 'mcp invalid name'
pass 'Claude --mcp attaches named HTTP servers and rejects malformed values'

out="$(printf 'bounded implementation\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode implement --repo "$WORK/repo" --effort medium --timeout 5 2> "$WORK/grok.err")"
[ "$out" = $'grok findings\nAPPROVE' ] || fail 'Grok final output'
contains "$WORK/grok.args" 'grok-4.7' 'Grok default model pin'
contains "$WORK/grok.args" '--reasoning-effort' 'Grok effort flag'
contains "$WORK/grok.args" 'medium' 'Grok medium effort pin'
contains "$WORK/grok.args" '--no-subagents' 'Grok worker fan-out disabled'
contains "$WORK/grok.args" '--max-turns' 'Grok turn cap flag'
contains "$WORK/grok.args" '150' 'Grok implement default turn cap'
contains "$WORK/grok.args" '--sandbox' 'Grok sandbox flag'
contains "$WORK/grok.args" 'none' 'Grok unrestricted sandbox'
contains "$WORK/grok.args" '--permission-mode' 'Grok permission mode flag'
contains "$WORK/grok.args" 'bypassPermissions' 'Grok YOLO permission mode'
contains "$WORK/grok.prompt" 'bounded implementation' 'Grok receives task packet'
contains "$WORK/grok.config" '[compat.claude]' 'Grok isolated config disables Claude compatibility'
contains "$WORK/grok.config" 'skills = false' 'Grok isolated config disables inherited skills'
absent "$WORK/grok.args" '--tools' 'Grok implementation unexpectedly restricts tools'
absent "$WORK/grok.args" '--debug-file' 'Grok implementation unexpectedly requests allowlist debug evidence'
[ "$(cat "$WORK/grok.home-env")" = "$HOME" ] || fail 'Grok implementation preserves toolchain HOME'
[ "$(cat "$WORK/grok.dir-env")" != "$GROK_HOME" ] || fail 'Grok config isolation'
printf 'explicit 4.7\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-47.err" \
  || fail 'grok-4.7 accepted'
contains "$WORK/grok.args" 'grok-4.7' 'explicit grok-4.7 forwarded'
printf 'explicit 4.6\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-46.err" \
  || fail 'grok-4.6 accepted'
contains "$WORK/grok.args" 'grok-4.6' 'explicit grok-4.6 forwarded'
printf 'compat 4.5\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.5 --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-45.err" \
  || fail 'grok-4.5 still accepted'
contains "$WORK/grok.args" 'grok-4.5' 'explicit grok-4.5 forwarded'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-9.9 >/dev/null 2> "$WORK/grok-unknown.err"
unknown_rc=$?
set -e
[ "$unknown_rc" -eq 2 ] || fail "unknown Grok model rc=$unknown_rc want 2"
contains "$WORK/grok-unknown.err" 'grok-4.7' 'unknown model error names grok-4.7'
contains "$WORK/grok-unknown.err" 'grok-4.6' 'unknown model error names grok-4.6'
contains "$WORK/grok-unknown.err" 'grok-4.5' 'unknown model error names grok-4.5'
[ ! -f "$WORK/grok.args" ] || fail 'unknown Grok model must not invoke grok'
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.5 --effort xhigh >/dev/null 2> "$WORK/grok-45-xhigh.err"
xhigh45_rc=$?
set -e
[ "$xhigh45_rc" -eq 2 ] || fail "grok-4.5+xhigh rc=$xhigh45_rc want 2"
contains "$WORK/grok-45-xhigh.err" 'low|medium|high' 'grok-4.5+xhigh names allowed efforts'
contains "$WORK/grok-45-xhigh.err" 'grok-4.5' 'grok-4.5+xhigh names the model'
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.5+xhigh must not invoke grok'
printf 'xhigh 4.6\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort xhigh --timeout 5 >/dev/null 2> "$WORK/grok-46-xhigh.err" \
  || fail 'grok-4.6+xhigh accepted'
contains "$WORK/grok.args" 'grok-4.6' 'grok-4.6+xhigh forwards model'
contains "$WORK/grok.args" '--reasoning-effort' 'grok-4.6+xhigh forwards effort flag'
exact_line "$WORK/grok.args" 'xhigh' 'grok-4.6+xhigh passes xhigh through'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort max >/dev/null 2> "$WORK/grok-46-max.err"
max46_rc=$?
set -e
[ "$max46_rc" -eq 2 ] || fail "grok-4.6+max rc=$max46_rc want 2"
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.6+max must not invoke grok'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort ultra >/dev/null 2> "$WORK/grok-46-ultra.err"
ultra46_rc=$?
set -e
[ "$ultra46_rc" -eq 2 ] || fail "grok-4.6+ultra rc=$ultra46_rc want 2"
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.6+ultra must not invoke grok'
printf 'xhigh 4.7\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort xhigh --timeout 5 >/dev/null 2> "$WORK/grok-47-xhigh.err" \
  || fail 'grok-4.7+xhigh accepted'
contains "$WORK/grok.args" 'grok-4.7' 'grok-4.7+xhigh forwards model'
exact_line "$WORK/grok.args" 'xhigh' 'grok-4.7+xhigh passes xhigh through'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort max >/dev/null 2> "$WORK/grok-47-max.err"
max47_rc=$?
set -e
[ "$max47_rc" -eq 2 ] || fail "grok-4.7+max rc=$max47_rc want 2"
contains "$WORK/grok-47-max.err" 'grok-4.7' 'grok-4.7+max names the model'
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.7+max must not invoke grok'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort ultra >/dev/null 2> "$WORK/grok-47-ultra.err"
ultra47_rc=$?
set -e
[ "$ultra47_rc" -eq 2 ] || fail "grok-4.7+ultra rc=$ultra47_rc want 2"
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.7+ultra must not invoke grok'
printf 'env model override\n' | MMO_GROK_MODEL=grok-4.5 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-env-model.err" \
  || fail 'MMO_GROK_MODEL=grok-4.5 accepted'
contains "$WORK/grok.args" 'grok-4.5' 'MMO_GROK_MODEL override forwarded'
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4 >/dev/null 2>&1; then
  fail 'earlier Grok model rejected'
fi
pass 'Grok runner defaults to 4.7 and enforces per-model efforts'

out="$(printf 'review Grok diff\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --effort high --timeout 5 2> "$WORK/grok-review.err")"
[ "$out" = $'grok findings\nAPPROVE' ] || fail 'Grok review output'
contains "$WORK/grok.args" '--tools' 'Grok review tools restriction'
contains "$WORK/grok.args" 'read_file,list_dir,grep' 'Grok review read-only tools'
contains "$WORK/grok.prompt" '+after' 'Grok review receives diff'
[ "$(cat "$WORK/grok.home-env")" != "$HOME" ] || fail 'Grok review HOME isolation'
if printf x | MMO_REVIEW_DIFF_MAX_BYTES=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD >/dev/null 2>&1; then
  fail 'Grok review diff cap enforced'
fi
pass 'Grok review is diff-aware, bounded, and read-only'

grok_log=''
while IFS= read -r line; do
  case "$line" in
    *' log='*) grok_log="${line##* log=}" ;;
  esac
done < "$WORK/grok.err"
[ -n "$grok_log" ] && [ -f "$grok_log" ] || fail 'Grok reported log persists after cleanup'
[ -f "${grok_log}.stderr" ] || fail 'Grok stderr log persists after cleanup'
rm -f "$grok_log" "${grok_log}.stderr"
pass 'Grok reports persistent diagnostic logs'

printf '{"key":"old"}\n' > "$GROK_HOME/auth.json"
mkdir "$GROK_HOME/auth.json.lockdir"
printf '99999999\n' > "$GROK_HOME/auth.json.lockdir/pid"
printf 'refresh auth\n' | STUB_GROK_REFRESH=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth.err"
contains "$GROK_HOME/auth.json" '"new"' 'Grok refreshed auth copied back after stale lock recovery'
[ ! -e "$GROK_HOME/auth.json.lockdir" ] || fail 'Grok stale auth lock removed'
pass 'Grok recovers stale auth locks safely'

# A lock directory with no pid file is stale only once it is older than a minute.
printf '{"key":"old"}\n' > "$GROK_HOME/auth.json"
mkdir "$GROK_HOME/auth.json.lockdir"; touch -d '5 minutes ago' "$GROK_HOME/auth.json.lockdir"
printf 'refresh auth\n' | STUB_GROK_REFRESH=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-nopid.err"
contains "$GROK_HOME/auth.json" '"new"' 'Grok refreshed auth written back past an old pid-less lock'
[ ! -e "$GROK_HOME/auth.json.lockdir" ] || fail 'Grok old pid-less auth lock removed'
printf '{"key":"old"}\n' > "$GROK_HOME/auth.json"
mkdir "$GROK_HOME/auth.json.lockdir"
printf 'refresh auth\n' | STUB_GROK_REFRESH=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-fresh.err"
contains "$WORK/grok-auth-fresh.err" 'lock busy' 'Grok fresh pid-less lock reports lock busy'
contains "$GROK_HOME/auth.json" '"old"' 'Grok fresh pid-less lock blocks the write-back'
rmdir "$GROK_HOME/auth.json.lockdir"
pass 'Grok pid-less auth lock: stale after a minute, busy while fresh'

# Concurrent host refresh while a leg runs must not be clobbered by stale isolated auth.
printf '{"key":"start"}\n' > "$GROK_HOME/auth.json"
printf 'host race no isolated refresh\n' | \
  STUB_GROK_HOST_RACE=1 STUB_GROK_HOST_AUTH="$GROK_HOME/auth.json" \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-race.err"
contains "$GROK_HOME/auth.json" '"host-newer"' 'Grok host refresh survives when isolated did not refresh'
printf '{"key":"start"}\n' > "$GROK_HOME/auth.json"
printf 'host race with isolated refresh\n' | \
  STUB_GROK_HOST_RACE=1 STUB_GROK_HOST_AUTH="$GROK_HOME/auth.json" STUB_GROK_REFRESH=1 \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-race2.err"
contains "$GROK_HOME/auth.json" '"host-newer"' 'Grok host refresh not clobbered by stale isolated refresh'
absent "$GROK_HOME/auth.json" '"new"' 'Grok isolated refresh must not overwrite concurrent host value'
# No host auth at start: concurrent host creation during the leg must survive.
rm -f "$GROK_HOME/auth.json"
printf 'host appears mid-leg\n' | \
  STUB_GROK_HOST_RACE=1 STUB_GROK_HOST_AUTH="$GROK_HOME/auth.json" STUB_GROK_REFRESH=1 \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-race3.err"
contains "$GROK_HOME/auth.json" '"host-newer"' 'Grok concurrent host create not clobbered when no start snapshot'
absent "$GROK_HOME/auth.json" '"new"' 'Grok isolated refresh must not overwrite mid-leg host create'
pass 'Grok auth writeback skips when host changed during the leg'

if printf x | STUB_CLAUDE_RESULT=empty "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" >/dev/null 2>&1; then
  fail 'Claude empty success rejected'
fi
if printf x | STUB_CLAUDE_RESULT=progress "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD >/dev/null 2>&1; then
  fail 'Claude progress-only review rejected'
fi
if printf x | STUB_GROK_RESULT=empty "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" >/dev/null 2>&1; then
  fail 'Grok empty success rejected'
fi
if printf x | STUB_GROK_RESULT=progress "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD >/dev/null 2>&1; then
  fail 'Grok progress-only review rejected'
fi
pass 'Claude and Grok reject empty or verdict-free success'

out="$(printf 'legacy alias\n' | MMO_OPUS_MODEL=opus "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --timeout 5 2> "$WORK/legacy-opus.err")"
[ "$out" = $'claude findings\nAPPROVE' ] || fail 'Legacy Opus alias output'
exact_line "$WORK/claude.args" 'claude-opus-5-5' 'Legacy Opus alias maps to Opus 5.5'
pass 'Legacy Opus alias maps only to the current model'

printf 'primary config\n' | MMO_CLAUDE_MODEL=claude-sonnet-5-5 MMO_CLAUDE_EFFORT=xhigh "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/primary-config.err"
contains "$WORK/claude.args" 'claude-sonnet-5-5' 'Compatibility wrapper preserves primary model config'
contains "$WORK/claude.args" 'xhigh' 'Compatibility wrapper preserves primary effort config'
pass 'Opus wrapper does not override primary Claude configuration'

contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$claude_pid"' 'Orchestration checks Claude reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$astra_pid"' 'Orchestration checks Codex reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$grok_pid"' 'Orchestration checks Grok reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'review_failed' 'Orchestration refuses arbitration after reviewer failure'
pass 'Orchestration preserves each parallel reviewer exit status'

contains "$PLUGIN_ROOT/commands/orchestrate.md" 'tribunal-review:closing-tribunal-loop' 'Orchestrate defaults final review to the tribunal flow'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" 'tribunal-review:closing-tribunal-loop' 'Orchestration skill defaults final review to the tribunal flow'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" 'Fallback' 'Orchestration skill keeps inline review as explicit fallback'
absent "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" 'tribunal-round' 'Orchestration skill references tribunal instead of duplicating its round protocol'
pass 'Orchestrate uses the closing-tribunal-loop flow by default'

META_CMD="$PLUGIN_ROOT/commands/meta-orchestrate.md"
META_SKILL="$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md"
META_REFS="$PLUGIN_ROOT/skills/meta-orchestration/references"
contains "$META_CMD" "Skill('multi-model-orchestrator:meta-orchestration')" 'Meta command invokes the meta-orchestration skill via the Skill tool'
contains "$META_CMD" 'allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill' 'Meta command allows the Skill tool'
contains "$META_SKILL" 'the summary is not authoritative' 'Meta skill re-anchors on the handoff after compaction'
contains "$PLUGIN_ROOT/README.md" '"autoCompactWindow": 500000' 'README documents the compaction cap'
contains "$META_CMD" '--resume' 'Meta command documents resume'
contains "$META_CMD" 'mission brief' 'Meta command takes a free-form what-to-achieve brief'
contains "$META_SKILL" 'HOW is yours' 'Meta skill owns the how; the brief owns the what'
contains "$META_SKILL" 'review-gate.sh --author <worker>' 'Meta skill gates with the worker as author'
contains "$META_SKILL" 'Hold the run lease' 'Meta skill holds the run lease'
contains "$META_REFS/handoff-template.md" 'handoff-lease.sh claim <owner>' 'Handoff template claims the lease'
contains "$META_REFS/handoff-template.md" 'Lease owner' 'Handoff template records the lease owner'
contains "$PLUGIN_ROOT/commands/orchestrate.md" '--author "$WORKER_PROVIDER"' 'Orchestrate passes the worker as gate author'
contains "$PLUGIN_ROOT/README.md" '--mode probe' 'README documents probe mode'
contains "$PLUGIN_ROOT/README.md" 'handoff-lease.sh' 'README documents the handoff lease'
contains "$META_SKILL" 'only on a gate exit of 0' 'Meta skill merges only on a gate exit of 0'
absent "$META_SKILL" 'READY TO MERGE' 'Meta skill no longer relies on a literal merge line'
contains "$META_SKILL" 'route-model-task' 'Meta skill routes via route-model-task'
contains "$META_SKILL" 'any research memo for the item' 'Meta skill feeds research memos into the worker packet'
contains "$META_SKILL" 'tribunal-review:closing-tribunal-loop' 'Meta skill chains the tribunal close-out'
contains "$META_SKILL" '124' 'Meta skill keeps the exit-124 salvage rule'
contains "$META_SKILL" 'not a liveness check' 'Meta skill keeps the transcript-mtime liveness rule'
contains "$META_SKILL" 'exit marker' 'Meta skill names exit marker in the liveness rule'
contains "$META_SKILL" 'never `pgrep`' 'Meta skill forbids pgrep for liveness'
contains "$META_SKILL" 'references/leg-liveness.md' 'Meta skill points at the leg-liveness reference'
[ -f "$META_REFS/leg-liveness.md" ] || fail 'Leg liveness reference exists'
contains "$META_REFS/leg-liveness.md" 'echo $?' 'Leg liveness reference names the exit-marker write'
contains "$META_REFS/leg-liveness.md" 'out.exit' 'Leg liveness reference names the out.exit example'
contains "$META_REFS/leg-liveness.md" 'never `pgrep`' 'Leg liveness reference forbids pgrep'
contains "$META_REFS/leg-liveness.md" '75 (EX_TEMPFAIL)' 'Leg liveness reference names exit 75 transient rule'
contains "$META_REFS/leg-liveness.md" '77 (EX_NOPERM)' 'Leg liveness reference names exit 77 auth rule'
contains "$META_REFS/leg-liveness.md" 'Wait at least 60s' 'Leg liveness reference requires 60s wait before transient retry'
contains "$META_REFS/leg-liveness.md" 'OPERATOR ACTIONS REQUIRED' 'Leg liveness reference queues auth under operator actions'
contains "$META_SKILL" 'failure exits 75/77' 'Meta skill points at failure exits in leg-liveness'
absent "$META_REFS/leg-liveness.md" 'queue.json' 'Leg liveness reference does not introduce queue.json'
contains "$META_SKILL" 'references/handoff-template.md' 'Meta skill instantiates the handoff template'
contains "$META_SKILL" 'write nothing and stop' 'Meta skill makes a no-op scan near-zero cost'
contains "$META_SKILL" 'multi-model-orchestrator.local.md' 'Meta skill reads per-repo source/model config'
contains "$META_SKILL" 'apply to the tribunal panel' 'Meta skill exempts the tribunal panel from leg model constraints'
contains "$META_SKILL" 'unresearched' 'Meta skill distinguishes unresearched unknowns from human decisions'
contains "$META_SKILL" 'completion re-invokes the orchestrator' 'Meta skill requires a completion path back to the orchestrator'
contains "$META_SKILL" 'run_in_background: true' 'Meta skill names the Claude Code completion mechanism'
contains "$META_SKILL" 'never use bare shell `&`' 'Meta skill forbids bare shell backgrounding'
contains "$META_SKILL" 'Start every turn by reading any unread dispatched-leg output' 'Meta skill reads unread leg output at turn start'
contains "$META_SKILL" 'resume at the gate' 'Meta skill resumes completed legs at their gate'
contains "$META_SKILL" 'a defect, not a wait' 'Meta skill rejects ending a turn with an unarranged live leg'
contains "$META_SKILL" 'immediately before every dispatch' 'Meta skill writes the handoff immediately before every dispatch'
[ "$(grep -cF 'immediately before every dispatch' "$META_SKILL")" -eq 1 ] || fail 'Meta skill states immediately before every dispatch exactly once'
contains "$META_SKILL" 'Once the queue is ordered, and again' 'Meta skill writes the handoff once the queue is ordered and again before dispatch'
contains "$META_SKILL" 'git rev-parse --git-path info/exclude' 'Meta skill excludes the handoff dir via git rev-parse --git-path'
contains "$META_SKILL" 'never commit it during the run' 'Meta skill never commits the handoff during the run'
contains "$META_SKILL" 'Handoff is local — never commit it during the run' 'Meta skill names the handoff as the local, uncommitted file'
contains "$META_SKILL" 'git ls-files -- "${MMO_HANDOFF_DIR:-.claude/handoffs}"' 'Meta skill detects already-tracked handoff files via git ls-files'
contains "$META_SKILL" 'git rm -r --cached' 'Meta skill queues untrack as git rm -r --cached'
contains "$META_SKILL" 'write new handoffs under fresh names' 'Meta skill writes new handoffs under fresh names when the dir is tracked'
contains "$META_REFS/handoff-template.md" "Write rules: see the skill's Preflight and Handoff discipline (handoffs are local; never commit them)" 'Handoff template write rules say handoffs are local and never committed'
absent "$META_REFS/handoff-template.md" 'Write/commit rules' 'Handoff template drops Write/commit'
contains "$META_SKILL" 'write the final handoff; close the epic' 'Meta skill writes the final handoff locally at close-out'
contains "$META_SKILL" 'browser QA + UX' 'Meta skill keeps browser QA in the strategy A close-out'
absent "$META_SKILL" 'commit it on the epic branch' 'Meta skill never commits a handoff, even at close-out'
absent "$META_SKILL" 'git add -f <handoff>' 'Meta skill has no handoff commit command'
contains "$META_SKILL" 'repo-relative' 'Meta skill states the handoff dir is repo-relative'
contains "$PLUGIN_ROOT/README.md" 'Repo-relative' 'README states MMO_HANDOFF_DIR is a repo-relative directory'
absent "$META_SKILL" 'Strategy B: never commit it' 'Meta skill no longer splits handoff commits as strategy B never-commit'
absent "$META_SKILL" '.git/info/exclude' 'Meta skill does not hardcode .git/info/exclude as a literal path'
absent "$META_SKILL" 'task/job id' 'Meta skill does not record a session-local task/job id'
contains "$META_SKILL" 'unless already listed' 'Meta skill appends the handoff exclude entry only when absent'
contains "$META_SKILL" 'grep -qxF' 'Meta skill names the exact-match exclude check'
contains "$META_SKILL" 'literal resume command' 'Meta skill requires the literal resume command in the handoff'
contains "$META_SKILL" 'announcing a dispatch without that written handoff is a defect' 'Meta skill forbids announced dispatches without the written handoff'
contains "$META_SKILL" 'unless the brief explicitly waives it' 'Meta skill requires an explicit tribunal waiver'
[ "$(grep -cF '# optional' "$META_SKILL")" -eq 5 ] || fail 'Meta skill YAML example keeps exactly five # optional markers'
contains "$META_SKILL" 'reconcile; do not overwrite it' 'Meta skill refuses conflicting concurrent handoff overwrites'
contains "$META_SKILL" 'recorded in-flight leg and open item' 'Meta skill reconciles each recorded in-flight leg and open item on resume'
contains "$META_SKILL" 'with reality (PR merged/closed' 'Meta skill reconciles with reality including PR merged/closed'
contains "$META_SKILL" 'output mtime still advancing' 'Meta skill checks output mtime still advancing on resume'
contains "$META_SKILL" 'branch head as recorded' 'Meta skill checks branch head as recorded on resume'
contains "$META_SKILL" 'then execute its "Stop here first" action' 'Meta skill executes Stop here first after reconciling'
contains "$META_SKILL" 'authoritative baseline' 'Meta skill treats the handoff State block as the authoritative baseline'
contains "$META_SKILL" 'reconcile, never discard' 'Meta skill inspects and reconciles unexplained worktree state, never discards'
contains "$META_SKILL" 'overrides of decided judgment calls and brief deltas' 'Meta skill keeps trailing text as overrides of decided judgment calls'
contains "$META_SKILL" "Within the brief's autonomy bounds" 'Meta skill runs within the brief autonomy bounds'
absent "$META_SKILL" 'queue is ratified' 'Meta skill does not reopen a queue-ratification stall'
contains "$META_SKILL" 'Self-merge IS permitted' 'Meta skill states self-merge is permitted'
contains "$META_SKILL" 'Pause to ask only for credentials, browser authentication, repo-policy changes,' 'Meta skill names the closed escalation set (credentials through policy)'
contains "$META_SKILL" 'spend, or irreversible production data' 'Meta skill names the closed escalation set (spend and production data)'
absent "$META_SKILL" '— nothing else' 'Meta skill does not claim the closed list overrides every other stop'
contains "$META_SKILL" "The brief's stop conditions and gate blockers still stop" 'Meta skill keeps brief stop conditions and blockers binding'
contains "$META_SKILL" 'stops the run' 'Meta skill stops the run on run-level conditions'
contains "$META_SKILL" 'Genuine judgment calls outside the pause set above are decided with the recommended default and recorded' 'Meta skill decides judgment calls instead of parking them'
contains "$META_SKILL" 'outside the pause set' 'Meta skill scopes autonomous judgment calls outside the pause set'
contains "$META_SKILL" 'a gate blocker parks that item' 'Meta skill parks an item on a gate blocker'
contains "$META_SKILL" "fifth cycle's delta" 'Meta skill parks after the fifth cycle delta still NEEDS_WORK'
contains "$META_SKILL" 'up to 5 fix cycles' 'Meta skill allows up to 5 NEEDS_WORK fix cycles'
absent "$META_SKILL" 'second ''NEEDS_WORK' 'Meta skill does not use the off-by-one second-NEEDS_WORK phrasing'
absent "$META_SKILL" 'escalat' 'Meta skill has no escalation-path wording'
contains "$META_SKILL" 'OPERATOR ACTIONS REQUIRED' 'Meta skill queues refused privileged actions instead of blocking'
contains "$META_SKILL" 'tree-independent item' 'Meta skill continues with tree-independent work after a queued host action'
contains "$META_SKILL" 'permission layer refuses' 'Meta skill treats a host permission refusal as a dispatch that never started'
[ "$(grep -cF 'tree-independent item' "$META_SKILL")" -eq 1 ] || fail 'Meta skill mentions tree-independent item exactly once'
contains "$META_SKILL" 'Do not burn the session on preflight beyond the Fresh-start checks' 'Meta skill bounds preflight to the Fresh-start checks'
contains "$META_SKILL" 'CLAUDE_PLUGIN_ROOT}/scripts/' 'Meta skill names the plugin scripts directory for runners'
absent "$META_SKILL" 'Poll ' 'Meta skill removes unactionable polling guidance'
absent "$META_SKILL" 'preflight.sh' 'Meta skill references tribunal instead of duplicating its preflight'
absent "$META_SKILL" 'tribunal-round' 'Meta skill references tribunal instead of duplicating its round protocol'
absent "$META_SKILL" 'as soon as real work starts' 'Meta skill no longer triggers the handoff on vague real-work start'
absent "$META_REFS/handoff-template.md" 'committed on the working branch' 'Handoff template defers commit location to the skill'
contains "$META_REFS/handoff-template.md" 'Stop here first' 'Handoff template keeps the single next action'
contains "$META_REFS/handoff-template.md" 'do not re-litigate' 'Handoff template keeps ratified decisions'
contains "$META_REFS/handoff-template.md" 'remain in force verbatim' 'Handoff template keeps delta inheritance'
contains "$META_REFS/handoff-template.md" 'In-flight legs:' 'Handoff template records dispatched legs'
contains "$META_REFS/handoff-template.md" 'runner + mode + model' 'In-flight legs identify their runner configuration'
contains "$META_REFS/handoff-template.md" 'output path' 'In-flight legs identify their output'
contains "$META_REFS/handoff-template.md" 'exit marker path' 'In-flight legs record the exit marker path'
contains "$META_REFS/handoff-template.md" 'dispatch time (UTC)' 'In-flight legs record UTC dispatch time'
contains "$META_REFS/handoff-template.md" 'how completion will be observed' 'In-flight legs record their completion path'
absent "$META_REFS/handoff-template.md" 'task/job id' 'Handoff template does not list a session-local task/job id'
contains "$META_REFS/handoff-template.md" 'expected artifact paths' 'In-flight legs carry expected artifact paths'
contains "$META_REFS/handoff-template.md" 'baseline the gate measures against' 'In-flight legs carry the gate baseline'
contains "$META_REFS/handoff-template.md" 'literal resume command' 'In-flight legs carry the literal resume command'
contains "$META_REFS/handoff-template.md" 'repo path' 'In-flight legs carry the repository path'
contains "$META_REFS/handoff-template.md" '## OPERATOR ACTIONS REQUIRED' 'Handoff template has an OPERATOR ACTIONS REQUIRED block'
absent "$META_REFS/handoff-template.md" "Open"' '"human decisions" 'Handoff template drops the parked-decisions heading'
contains "$META_REFS/handoff-template.md" '## Judgment calls decided' 'Handoff template records decided judgment calls'
absent "$META_REFS/handoff-template.md" 'or filed research memo — never only' 'Handoff template defers trigger list to the skill'
contains "$META_REFS/worker-prompt.md" 'No push, no PR' 'Worker template forbids worker push'
contains "$META_REFS/worker-prompt.md" 'expected red before the fix' 'Worker template keeps the expected-red phrasing'
contains "$META_REFS/worker-prompt.md" 'Out of scope' 'Worker template keeps the scope fence'
contains "$META_REFS/review-prompts.md" 'BY EXECUTION' 'Review template mandates verification by execution'
contains "$META_REFS/review-prompts.md" 'NEEDS_WORK' 'Review template uses the runner verdict token'
# Keep the prescribed template verdict line executable against the shared runner gate.
tmpl="$(grep -m1 -E '^VERDICT:' "$META_REFS/review-prompts.md")" || fail 'Review template lost its VERDICT line'
assert_review_verdict "${tmpl%%|*}" 'Template APPROVE alternative renders past the runner gate'
assert_review_verdict "${tmpl#*|}" 'Template NEEDS_WORK alternative renders past the runner gate'
contains "$META_REFS/review-prompts.md" 'Bounded DELTA by execution' 'Review template keeps the bounded delta round'
absent "$META_REFS/review-prompts.md" 'READY TO MERGE' 'Review templates no longer request a literal merge line'
contains "$META_REFS/review-prompts.md" '--mode probe' 'Review templates route execute-probe legs through --mode probe'
contains "$META_REFS/review-prompts.md" 'review-gate.sh --author <worker provider>' 'Review templates run the gate with --author'
absent "$META_REFS/review-prompts.md" '`--mode implement` + modify-nothing contract' 'Review templates dropped the implement+modify-nothing contract'
contains "$META_REFS/review-prompts.md" 'Send after each fix cycle' 'Delta re-review runs after each fix cycle'
absent "$META_REFS/review-prompts.md" 'single fix ''cycle' 'Delta re-review is not limited to one fix cycle'
contains "$META_REFS/worker-prompt.md" 'the orchestrator commits' 'Worker template reconciles commits with no-commit leg contracts'
absent "$META_REFS/review-prompts.md" 'REQUEST_CHANGES' 'Review template does not reintroduce the unsupported verdict token'
[ -f "$META_REFS/research-leg.md" ] || fail 'Research leg reference exists'
contains "$META_REFS/research-leg.md" 'Do not trigger' 'Research leg reference keeps the negative trigger rules'
absent "$META_REFS/research-leg.md" 'prompt-bounded' 'Research leg reference does not restate runner posture'
absent "$META_REFS/research-leg.md" 'would otherwise be ''escalated' 'Research leg does not assume an escalation path'
absent "$META_REFS/research-leg.md" 'skipping the ''human' 'Research leg does not frame convergence as skipping a human'
absent "$PLUGIN_ROOT/README.md" 'escalated as ''human' 'README does not escalate unknowns as human decisions'
meta_over_budget_fixture="$WORK/meta-orchestration-over-budget.md"
printf '%10001s' '' | tr ' ' x > "$meta_over_budget_fixture"
[ "$(wc -l < "$meta_over_budget_fixture")" -lt 150 ] || fail 'Meta skill budget fixture must stay below 150 lines'
[ "$(wc -c < "$meta_over_budget_fixture")" -gt 10000 ] || fail 'Meta skill budget fixture must exceed 10000 bytes'
! [ "$(wc -c < "$meta_over_budget_fixture")" -le 10000 ] || fail 'Meta skill character budget accepts an over-budget fixture'
[ "$(wc -c < "$META_SKILL")" -le 10000 ] || fail 'meta-orchestration SKILL.md exceeds the 10000-byte budget'
pass 'Meta orchestration skill character budget rejects an over-budget fixture'
pass 'Meta orchestration command, skill, and templates carry the required contracts'

# Installed-CLI smoke must use the user's real config path, not the fixture GROK_HOME
# (fixture auth.json is deliberately simplified and can fail stricter grok inspect).
if [ -n "$REAL_GROK" ]; then
  unset GROK_HOME
  real_grok_help="$($REAL_GROK --help 2>&1)"
  for flag in --reasoning-effort --sandbox --permission-mode --max-turns --no-subagents --prompt-file --tools --output-format --disable-web-search --cwd; do
    case "$real_grok_help" in
      *"$flag"*) ;;
      *) fail "installed Grok CLI lacks $flag" ;;
    esac
  done
  case "$real_grok_help" in
    *bypassPermissions*) ;;
    *) fail 'installed Grok CLI lacks bypassPermissions mode' ;;
  esac
  "$REAL_GROK" --sandbox none --permission-mode bypassPermissions --no-subagents --no-memory inspect >/dev/null
  grok_debug="$WORK/grok-research.debug"
  timeout -k 2 15 "$REAL_GROK" --cwd "$WORK/repo" --sandbox none --permission-mode bypassPermissions \
    --no-subagents --no-memory --max-turns 1 --tools "$GROK_RESEARCH_TOOLS" \
    --debug-file "$grok_debug" -p 'Reply only OK.' >/dev/null 2>&1 || true
  [ -s "$grok_debug" ] || fail 'installed Grok research tool resolution produced no debug log'
  absent "$grok_debug" 'unmappable' 'installed Grok resolves every research tool'
  absent "$grok_debug" 'keeping full grok toolset' 'installed Grok keeps the research allowlist'
  rm -f "$grok_debug"
  pass 'Installed Grok CLI parses the runner posture and supports its flags'
else
  printf 'SKIP: installed Grok CLI flag smoke test\n'
fi

# --- #517 runner flag surface: one vocabulary, no silent ignore, no empty exit-0 ---

# Req 1: --repo and --dir are synonyms on every runner (including opus wrapper).
# Behavioral: stubs record the cwd/repo they actually received; both spellings
# must deliver the supplied repo (not a silent fallback to $PWD).
repo_top="$(git -C "$WORK/repo" rev-parse --show-toplevel)"
printf 'synonym claude dir\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --dir "$WORK/repo" \
  --model claude-haiku-5-5 --timeout 5 >/dev/null 2> "$WORK/syn-claude-dir.err" \
  || fail 'Claude accepts --dir as --repo synonym'
exact_line "$WORK/claude.cwd" "$repo_top" 'Claude --dir places the stub in the supplied repo'
printf 'synonym claude repo\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --timeout 5 >/dev/null 2> "$WORK/syn-claude-repo.err" \
  || fail 'Claude keeps accepting --repo'
exact_line "$WORK/claude.cwd" "$repo_top" 'Claude --repo places the stub in the supplied repo'
printf 'synonym grok dir\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --dir "$WORK/repo" \
  --timeout 5 >/dev/null 2> "$WORK/syn-grok-dir.err" \
  || fail 'Grok accepts --dir as --repo synonym'
exact_line "$WORK/grok.cwd" "$repo_top" 'Grok --dir passes the supplied repo as --cwd'
printf 'synonym grok repo\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --timeout 5 >/dev/null 2> "$WORK/syn-grok-repo.err" \
  || fail 'Grok keeps accepting --repo'
exact_line "$WORK/grok.cwd" "$repo_top" 'Grok --repo passes the supplied repo as --cwd'
printf 'synonym codex repo\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --repo "$WORK/repo" \
  --timeout 5 >/dev/null 2> "$WORK/syn-codex-repo.err" \
  || fail 'Codex accepts --repo as --dir synonym'
exact_line "$WORK/codex.cwd" "$repo_top" 'Codex --repo passes the supplied repo as -C'
printf 'synonym codex dir\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --timeout 5 >/dev/null 2> "$WORK/syn-codex-dir.err" \
  || fail 'Codex keeps accepting --dir'
exact_line "$WORK/codex.cwd" "$repo_top" 'Codex --dir passes the supplied repo as -C'
printf 'synonym opus dir\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --dir "$WORK/repo" \
  --timeout 5 >/dev/null 2> "$WORK/syn-opus-dir.err" \
  || fail 'Opus wrapper accepts --dir via Claude'
exact_line "$WORK/claude.cwd" "$repo_top" 'Opus --dir places the stub in the supplied repo'
printf 'synonym opus repo\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --repo "$WORK/repo" \
  --timeout 5 >/dev/null 2> "$WORK/syn-opus-repo.err" \
  || fail 'Opus wrapper accepts --repo via Claude'
exact_line "$WORK/claude.cwd" "$repo_top" 'Opus --repo places the stub in the supplied repo'
contains "$PLUGIN_ROOT/scripts/run-claude.sh" '--repo|--dir)' 'Claude case lists --repo|--dir synonym'
contains "$PLUGIN_ROOT/scripts/run-grok.sh" '--repo|--dir)' 'Grok case lists --repo|--dir synonym'
contains "$PLUGIN_ROOT/scripts/run-codex.sh" '--repo|--dir)' 'Codex case lists --repo|--dir synonym'
contains "$PLUGIN_ROOT/scripts/run-claude.sh" '[--repo DIR|--dir DIR]' 'Claude usage documents synonym pair'
contains "$PLUGIN_ROOT/scripts/run-grok.sh" '[--repo DIR|--dir DIR]' 'Grok usage documents synonym pair'
contains "$PLUGIN_ROOT/scripts/run-codex.sh" '[--repo DIR|--dir DIR]' 'Codex usage documents synonym pair'
pass '#517 req1: --repo/--dir synonyms work on every runner'

# Req 2: every runner accepts --base, --stream-log, --max-turns; never silently ignore.
# --stream-log must actually stream where accepted.
mkdir -p "$WORK/flag-dest"
printf 'claude stream\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/flag-dest/claude-final.txt" \
  --stream-log "$WORK/flag-dest/claude.stream" --timeout 5 \
  >/dev/null 2> "$WORK/flag-dest/claude-stream.err" \
  || fail 'Claude accepts --stream-log'
[ -f "$WORK/flag-dest/claude.stream" ] || fail 'Claude --stream-log creates stream file'
[ -s "$WORK/flag-dest/claude.stream" ] || fail 'Claude --stream-log actually streams content'
contains "$WORK/flag-dest/claude-stream.err" "log=$WORK/flag-dest/claude.stream" 'Claude log= honors --stream-log'
printf 'grok stream\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/flag-dest/grok-final.txt" --stream-log "$WORK/flag-dest/grok.stream" --timeout 5 \
  >/dev/null 2> "$WORK/flag-dest/grok-stream.err" \
  || fail 'Grok accepts --stream-log'
[ -f "$WORK/flag-dest/grok.stream" ] || fail 'Grok --stream-log creates stream file'
[ -s "$WORK/flag-dest/grok.stream" ] || fail 'Grok --stream-log actually streams content'
contains "$WORK/flag-dest/grok-stream.err" "log=$WORK/flag-dest/grok.stream" 'Grok log= honors --stream-log'
printf 'codex base\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/flag-dest/codex-base.err" \
  || fail 'Codex accepts and honors --base in review'
contains "$WORK/codex.prompt" 'Unified diff from HEAD' 'Codex --base injects review diff'
contains "$WORK/codex.prompt" '+after' 'Codex --base diff includes working-tree changes'
# --base empty-diff and size guards (match Claude/Grok exit 3 / exit 4).
mkdir -p "$WORK/codex-clean"
git -C "$WORK/codex-clean" init -q
git -C "$WORK/codex-clean" config user.email test@example.com
git -C "$WORK/codex-clean" config user.name Test
printf 'clean\n' > "$WORK/codex-clean/app.txt"
git -C "$WORK/codex-clean" add app.txt
git -C "$WORK/codex-clean" commit -qm clean
set +e
printf 'codex empty diff\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/codex-clean" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/flag-dest/codex-empty.err"
codex_empty_rc=$?
set -e
[ "$codex_empty_rc" -eq 3 ] || fail "Codex --base empty diff rc=$codex_empty_rc want 3"
contains "$WORK/flag-dest/codex-empty.err" 'no diff to review' 'Codex empty --base diff message'
set +e
printf 'codex oversized diff\n' | MMO_REVIEW_DIFF_MAX_BYTES=1 \
  "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/flag-dest/codex-oversize.err"
codex_oversize_rc=$?
set -e
[ "$codex_oversize_rc" -eq 4 ] || fail "Codex --base oversized diff rc=$codex_oversize_rc want 4"
contains "$WORK/flag-dest/codex-oversize.err" 'MMO_REVIEW_DIFF_MAX_BYTES' 'Codex oversized --base diff names cap'
# --max-turns: Grok and Claude honor (forward to CLI); Codex must name the flag
# and say why it cannot. Claude invalid values fail exit 2 naming the bound.
printf 'grok turns\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --max-turns 7 --timeout 5 >/dev/null 2> "$WORK/flag-dest/grok-turns.err" \
  || fail 'Grok accepts --max-turns'
contains "$WORK/grok.args" '7' 'Grok honors --max-turns value'
printf 'claude turns\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --max-turns 3 --timeout 5 >/dev/null 2> "$WORK/flag-dest/claude-turns.err" \
  || fail 'Claude accepts --max-turns'
contains "$WORK/claude.args" '--max-turns' 'Claude forwards --max-turns to CLI'
exact_line "$WORK/claude.args" '3' 'Claude honors --max-turns value'
printf 'opus turns\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --repo "$WORK/repo" \
  --max-turns 5 --timeout 5 >/dev/null 2> "$WORK/flag-dest/opus-turns.err" \
  || fail 'Opus inherits --max-turns via run-claude.sh'
contains "$WORK/claude.args" '--max-turns' 'Opus forwards --max-turns to CLI'
exact_line "$WORK/claude.args" '5' 'Opus honors --max-turns value'
set +e
printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --max-turns notanumber --timeout 5 \
  >/dev/null 2> "$WORK/flag-dest/claude-turns-bad.err"
claude_turns_bad_rc=$?
set -e
[ "$claude_turns_bad_rc" -eq 2 ] || fail "Claude invalid --max-turns rc=$claude_turns_bad_rc want 2"
contains "$WORK/flag-dest/claude-turns-bad.err" 'max turns' 'Claude invalid --max-turns names the flag'
if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" \
  --max-turns 3 --timeout 5 >/dev/null 2> "$WORK/flag-dest/codex-turns.err"; then
  fail 'Codex must not silently ignore --max-turns'
fi
contains "$WORK/flag-dest/codex-turns.err" '--max-turns' 'Codex rejection names --max-turns'
contains "$WORK/flag-dest/codex-turns.err" 'Codex CLI' 'Codex rejection explains provider cannot honor --max-turns'
# #614: per-mode turn caps, exit 76 on a turn-budget stop, finishing resume on a changed tree.
grok_mt() {  # grok_mt ERRFILE ARGS... (prompt from stdin); sets mt_rc
  local err="$1"; shift
  set +e
  printf 'implement thing\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --repo "$WORK/repo" --timeout 60 "$@" >/dev/null 2> "$err"
  mt_rc=$?
  set -e
}
export STUB_GROK_CALLS="$WORK/grok.calls"
: > "$STUB_GROK_CALLS"
grok_mt "$WORK/mt-250.err" --mode implement --max-turns 250
[ "$mt_rc" -eq 0 ] || fail "implement --max-turns 250 rc=$mt_rc want 0"
exact_line "$WORK/grok.args" '250' 'implement forwards --max-turns 250'
contains "$WORK/grok.prompt" 'at most 250 agent turns' 'implement preamble states the turn budget'
contains "$WORK/grok.prompt" 'Do not broaden scope or commit.' 'implement preamble keeps the no-commit contract'
grok_mt "$WORK/mt-default.err" --mode implement
exact_line "$WORK/grok.args" '150' 'implement default max turns is 150'
grok_mt "$WORK/mt-301.err" --mode implement --max-turns 301
[ "$mt_rc" -eq 2 ] || fail "implement --max-turns 301 rc=$mt_rc want 2"
grok_mt "$WORK/mt-review250.err" --mode review --max-turns 250
[ "$mt_rc" -eq 2 ] || fail "review --max-turns 250 rc=$mt_rc want 2"
contains "$WORK/mt-review250.err" 'max turns must be an integer from 1 to 100 for --mode review' 'review cap message names mode and cap'
grok_mt "$WORK/mt-cont-review.err" --mode review --continue-on-max-turns 1
[ "$mt_rc" -eq 2 ] || fail "review --continue-on-max-turns 1 rc=$mt_rc want 2"
grok_mt "$WORK/mt-cont-4.err" --mode implement --continue-on-max-turns 4
[ "$mt_rc" -eq 2 ] || fail "--continue-on-max-turns 4 rc=$mt_rc want 2"
: > "$STUB_GROK_CALLS"
MMO_GROK_CONTINUE_ON_MAX_TURNS=2 grok_mt "$WORK/mt-env-review.err" --mode advise
[ "$mt_rc" -eq 0 ] || fail "env continue default must be ignored outside implement (rc=$mt_rc)"
MMO_GROK_MAX_TURNS=200 grok_mt "$WORK/mt-env200-review.err" --mode review
[ "$mt_rc" -eq 0 ] || fail "review env MMO_GROK_MAX_TURNS=200 rc=$mt_rc want 0"
exact_line "$WORK/grok.args" '100' 'review clamps env max turns to 100'
MMO_GROK_MAX_TURNS=200 grok_mt "$WORK/mt-env200-impl.err" --mode implement
exact_line "$WORK/grok.args" '200' 'implement honors env max turns 200'
MMO_GROK_MAX_TURNS=301 grok_mt "$WORK/mt-env301-impl.err" --mode implement
[ "$mt_rc" -eq 2 ] || fail "implement env MMO_GROK_MAX_TURNS=301 rc=$mt_rc want 2"
MMO_GROK_MAX_TURNS=200 grok_mt "$WORK/mt-flag200-review.err" --mode review --max-turns 200
[ "$mt_rc" -eq 2 ] || fail "review --max-turns 200 with env rc=$mt_rc want 2"
MMO_GROK_CONTINUE_ON_MAX_TURNS=5 grok_mt "$WORK/mt-env5-review.err" --mode review
[ "$mt_rc" -eq 0 ] || fail "review env continue=5 rc=$mt_rc want 0"
MMO_GROK_CONTINUE_ON_MAX_TURNS=5 grok_mt "$WORK/mt-env5-impl.err" --mode implement
[ "$mt_rc" -eq 2 ] || fail "implement env continue=5 rc=$mt_rc want 2"

export STUB_GROK_RESULT=maxturns STUB_GROK_TOUCH="$WORK/repo/mt-touched.txt"
rm -f "$STUB_GROK_TOUCH"
: > "$STUB_GROK_CALLS"
STUB_GROK_TOUCH= grok_mt "$WORK/mt-clean.err" --mode implement --max-turns 5
[ "$mt_rc" -eq 76 ] || fail "max turns on clean tree rc=$mt_rc want 76"
contains "$WORK/mt-clean.err" 'run-grok: max turns reached (5); work may be partial and uncommitted' 'max-turns stop prints the clear line'
contains "$WORK/mt-clean.err" '(--mode implement cap 300)' 'max-turns line names actual mode and cap'
contains "$WORK/mt-clean.err" 'exit=76' 'mmo_finish does not remap exit 76'
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail 'clean tree at max turns must not resume'
: > "$STUB_GROK_CALLS"
ln -sfn "$WORK/repo" "$WORK/repo-link"
(cd "$WORK/repo-link" && printf 'implement thing\n' | STUB_GROK_TOUCH= "$PLUGIN_ROOT/scripts/run-grok.sh" --mode implement --max-turns 5 --continue-on-max-turns 1 --timeout 60 --out rel.out >/dev/null 2> "$WORK/mt-symlink.err") && mt_link_rc=0 || mt_link_rc=$?
[ "$mt_link_rc" -eq 76 ] || fail "symlinked cwd relative --out rc=$mt_link_rc want 76"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail 'symlinked cwd + relative --out must not resume on a clean tree'
rm -f "$WORK/repo/rel.out" "$WORK/repo/rel.out.stderr" "$WORK/repo-link"
: > "$STUB_GROK_CALLS"
grok_mt "$WORK/mt-resume-all.err" --mode implement --max-turns 5 --continue-on-max-turns 2
rm -f "$STUB_GROK_TOUCH"
[ "$mt_rc" -eq 76 ] || fail "exhausted resumes rc=$mt_rc want 76"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 3 ] || fail 'resumes must stop at N=2 (3 calls total)'
contains "$WORK/mt-resume-all.err" 'continues=2' 'final line reports continues=2'
mt_sid="$(sed -n 's/.*--session-id \([0-9a-f-]*\).*/\1/p' "$STUB_GROK_CALLS" | head -1)"
[[ "$mt_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "first call lacks a v4 --session-id ($mt_sid)"
[ "$(grep -c -- "--resume $mt_sid" "$STUB_GROK_CALLS")" -eq 2 ] || fail 'resumes must reuse the same session UUID'
[ "$(grep -c -- '--session-id' "$STUB_GROK_CALLS")" -eq 1 ] || fail 'only the first call carries --session-id'
: > "$STUB_GROK_CALLS"
STUB_GROK_MAXTURNS_FIRST=1 grok_mt "$WORK/mt-resume-ok.err" --mode implement --max-turns 5 --stream-log "$WORK/mt.stream" --out "$WORK/mt.out"
rm -f "$STUB_GROK_TOUCH"
[ "$mt_rc" -eq 0 ] || fail "successful finishing resume rc=$mt_rc want 0"
contains "$WORK/mt-resume-ok.err" 'continues=1' 'successful resume reports continues=1'
contains "$WORK/mt.out" 'grok findings' '--out holds the last call final message'
contains "$WORK/mt.out.stderr" 'max turns reached' '.stderr accumulates the first call'
contains "$WORK/grok.prompt" 'Finish the remaining edits now' 'resume uses the finishing prompt'
: > "$STUB_GROK_CALLS"
STUB_GROK_TOUCH_ONCE=1 grok_mt "$WORK/mt-incr.err" --mode implement --max-turns 5 --continue-on-max-turns 2
rm -f "$STUB_GROK_TOUCH"
[ "$mt_rc" -eq 76 ] || fail "incremental baseline rc=$mt_rc want 76"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 2 ] || fail 'a resume that changes nothing must not trigger a second resume'
contains "$WORK/mt-incr.err" 'continues=1' 'incremental baseline reports continues=1'
: > "$STUB_GROK_CALLS"
grok_mt "$WORK/mt-review76.err" --mode review --max-turns 5
rm -f "$STUB_GROK_TOUCH"
[ "$mt_rc" -ne 76 ] || fail 'review leg at max turns must not exit 76'
[ "$mt_rc" -ne 0 ] || fail 'review leg at max turns must fail'
unset STUB_GROK_RESULT STUB_GROK_TOUCH
pass '#614: per-mode caps, exit 76, finishing resume bounded by N and tree change'

# #716: review/advise turn budget, default .stream, read-only allowlist synthesis on cap, exit 78.
mkdir -p "$WORK/716"
: > "$STUB_GROK_CALLS"
printf 'review budget check\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" \
  --base HEAD --out "$WORK/716/rev-default.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-default.err" \
  || fail '#716: default review run succeeds'
exact_line "$WORK/grok.args" '60' '#716: review default max turns is 60'
contains "$WORK/grok.prompt" 'at most 60 agent turns' '#716: review prompt states default 60-turn budget'
contains "$WORK/grok.prompt" 'read the diff first' '#716: review prompt instructs reading the diff first'
contains "$WORK/grok.prompt" 'write the report with turns to spare' '#716: review prompt instructs writing report with turns to spare'
[ -s "$WORK/716/rev-default.out.stream" ] || fail '#716: review --out without --stream-log writes FILE.stream'
contains "$WORK/716/rev-default.err" "log=$WORK/716/rev-default.out.stream" '#716: review log= points at default FILE.stream'
absent "$WORK/716/rev-default.out" 'Inspection truncated at the turn cap' '#716: non-truncated APPROVE review is untouched'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/716/rev-default.out")" || rc=$?
[ "$rc" -eq 0 ] && [ "$gout" = APPROVE ] || fail "#716: non-truncated APPROVE review passes review-gate ($rc/$gout)"

printf 'advise budget check\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/716/adv-default.out" --timeout 60 >/dev/null 2> "$WORK/716/adv-default.err" \
  || fail '#716: default advise run succeeds'
exact_line "$WORK/grok.args" '30' '#716: advise default max turns stays 30'
contains "$WORK/grok.prompt" 'at most 30 agent turns' '#716: advise prompt states 30-turn budget'
contains "$WORK/grok.prompt" 'write the report with turns to spare' '#716: advise prompt instructs writing report with turns to spare'
[ -s "$WORK/716/adv-default.out.stream" ] || fail '#716: advise --out without --stream-log writes FILE.stream'

# Review cap reached, resume returns VERDICT: APPROVE -> exit 0, model text kept, truncation note + VERDICT: NEEDS_WORK appended to --out and stdout, review-gate exits 1.
: > "$STUB_GROK_CALLS"
rc=0
cap_ok_stdout="$(printf 'review cap resume ok\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_RESUME_RESULT=verdict_approve STUB_GROK_PROGRESS='Opening progress only.' \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-cap-ok.out" --timeout 60 2> "$WORK/716/rev-cap-ok.err")" || rc=$?
[ "$rc" -eq 0 ] || fail "#716: review cap reached + resume ok rc=$rc want 0 ($(cat "$WORK/716/rev-cap-ok.err"))"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 2 ] || fail '#716: review cap reached resumes once (2 calls total)'
contains "$WORK/716/rev-cap-ok.out" 'grok findings' '#716: --out retains model review text'
contains "$WORK/716/rev-cap-ok.out" 'VERDICT: APPROVE' '#716: --out retains model VERDICT: APPROVE line'
printf 'grok findings\nVERDICT: APPROVE\n\nInspection truncated at the turn cap (5 turns): an approval from a partial inspection is not accepted.\nVERDICT: NEEDS_WORK\n' \
  | cmp -s - "$WORK/716/rev-cap-ok.out" \
  || fail "#716: --out must end with blank line + truncation note + VERDICT: NEEDS_WORK ($(cat "$WORK/716/rev-cap-ok.out"))"
printf '%s\n' "$cap_ok_stdout" | cmp -s - "$WORK/716/rev-cap-ok.out" \
  || fail '#716: stdout must include the appended truncation note and VERDICT: NEEDS_WORK'
absent "$WORK/716/rev-cap-ok.out" 'Opening progress only.' '#716: --out overwrites inspect progress with resumed message'
contains "$WORK/716/rev-cap-ok.out.stream" 'Opening progress only.' '#716: FILE.stream retains inspect progress'
contains "$WORK/716/rev-cap-ok.out.stream" 'VERDICT: APPROVE' '#716: FILE.stream appends resumed verdict'
contains "$WORK/716/rev-cap-ok.err" 'truncated=turns' '#716: exit line marked truncated=turns'
contains "$WORK/716/rev-cap-ok.err" 'max turns reached (5) in --mode review; synthesized from truncated inspection' \
  '#716: stderr explains truncated-turns synthesis'
contains "$WORK/716/rev-cap-ok.err" 'an approval from a partial inspection is not accepted' \
  '#716: stderr explains truncated review cannot approve'
rev_sid="$(sed -n 's/.*--session-id \([0-9a-f-]*\).*/\1/p' "$STUB_GROK_CALLS" | head -1)"
[[ "$rev_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "#716: inspect call lacks v4 --session-id ($rev_sid)"
contains "$WORK/grok.args" '--resume' '#716: resume call passes --resume'
exact_line "$WORK/grok.args" "$rev_sid" '#716: resume call reuses first call session id'
exact_line "$WORK/grok.args" '--tools' '#716: resume call passes --tools'
exact_line "$WORK/grok.args" 'read_file,list_dir,grep' '#716: resume call keeps read_file,list_dir,grep allowlist'
exact_line "$WORK/grok.args" '--no-plan' '#716: resume call passes --no-plan'
exact_line "$WORK/grok.args" '--debug-file' '#716: resume call passes --debug-file'
! grep -qx '' "$WORK/grok.args" || fail '#716: resume call must never pass an empty argument'
inspect_dbg="$(sed -n '1s/.*--debug-file \([^ ]*\).*/\1/p' "$STUB_GROK_CALLS")"
resume_dbg="$(sed -n '2s/.*--debug-file \([^ ]*\).*/\1/p' "$STUB_GROK_CALLS")"
[ -n "$inspect_dbg" ] && [ -n "$resume_dbg" ] && [ "$inspect_dbg" != "$resume_dbg" ] \
  || fail "#716: resume call must write its own --debug-file ($inspect_dbg vs $resume_dbg)"
contains "$WORK/grok.prompt" 'Stop inspecting' '#716: resume prompt tells Grok to stop inspecting'
contains "$WORK/grok.prompt" 'VERDICT: APPROVE or VERDICT: NEEDS_WORK' '#716: review resume prompt requires verdict line'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/716/rev-cap-ok.out")" || rc=$?
[ "$rc" -eq 1 ] && [ "$gout" = NEEDS_WORK ] || fail "#716: review-gate rejects truncated-turns approval with NEEDS_WORK ($rc/$gout)"

# Review cap reached, resume returns VERDICT: NEEDS_WORK -> file unchanged, review-gate exits 1.
: > "$STUB_GROK_CALLS"
rc=0
printf 'review cap resume needs_work\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_RESUME_RESULT=verdict_needs_work \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-cap-nw.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-cap-nw.err" || rc=$?
[ "$rc" -eq 0 ] || fail "#716: review cap reached + resume NEEDS_WORK rc=$rc want 0 ($(cat "$WORK/716/rev-cap-nw.err"))"
printf 'grok findings\nVERDICT: NEEDS_WORK\n' | cmp -s - "$WORK/716/rev-cap-nw.out" \
  || fail "#716: resumed NEEDS_WORK report must be left untouched ($(cat "$WORK/716/rev-cap-nw.out"))"
absent "$WORK/716/rev-cap-nw.err" 'an approval from a partial inspection is not accepted' \
  '#716: resumed NEEDS_WORK does not print approval-override stderr line'
rc=0
gout="$(bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg grok="$WORK/716/rev-cap-nw.out")" || rc=$?
[ "$rc" -eq 1 ] && [ "$gout" = NEEDS_WORK ] || fail "#716: review-gate exits 1 on resumed NEEDS_WORK ($rc/$gout)"

# Finding 1: missing or unenforced allowlist evidence on inspect or resume fails the leg with exit 7.
: > "$STUB_GROK_CALLS"
rc=0
printf 'review inspect no debug\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_DEBUG=absent STUB_GROK_RESUME_DEBUG=applied \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-ins-nodbg.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-ins-nodbg.err" || rc=$?
[ "$rc" -eq 7 ] || fail "#716: inspect debug absent + good resume rc=$rc want 7 ($(cat "$WORK/716/rev-ins-nodbg.err"))"
contains "$WORK/716/rev-ins-nodbg.err" 'no allowlist debug evidence' '#716: inspect debug absent + good resume prints exit-7 reason'
: > "$STUB_GROK_CALLS"
rc=0
printf 'review resume no debug\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_RESUME_DEBUG=absent \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-res-nodbg.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-res-nodbg.err" || rc=$?
[ "$rc" -eq 7 ] || fail "#716: resume without allowlist debug file rc=$rc want 7 ($(cat "$WORK/716/rev-res-nodbg.err"))"
contains "$WORK/716/rev-res-nodbg.err" 'no allowlist debug evidence' '#716: resume without debug file prints exit-7 reason'
: > "$STUB_GROK_CALLS"
rc=0
printf 'review resume empty allowlist\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_RESUME_DEBUG=empty_allowed \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-res-baddbg.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-res-baddbg.err" || rc=$?
[ "$rc" -eq 7 ] || fail "#716: resume with unenforced allowlist rc=$rc want 7 ($(cat "$WORK/716/rev-res-baddbg.err"))"
contains "$WORK/716/rev-res-baddbg.err" 'tool allowlist not enforced' '#716: resume with unenforced allowlist prints exit-7 reason'

# Advise cap reached, resume succeeds -> exit 0, truncated=turns, report untouched.
: > "$STUB_GROK_CALLS"
rc=0
printf 'advise cap resume ok\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --max-turns 5 \
  --out "$WORK/716/adv-cap-ok.out" --timeout 60 >/dev/null 2> "$WORK/716/adv-cap-ok.err" || rc=$?
[ "$rc" -eq 0 ] || fail "#716: advise cap reached + resume ok rc=$rc want 0"
contains "$WORK/716/adv-cap-ok.err" 'truncated=turns' '#716: advise exit line marked truncated=turns'
absent "$WORK/716/adv-cap-ok.out" 'Inspection truncated at the turn cap' '#716: advise mode report is untouched'

# T-002: with less than 30 s left in timeout, no resume runs and a capped review ends 78.
: > "$STUB_GROK_CALLS"
rc=0
printf 'review sub-30s timeout\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-sub30.out" --timeout 29 >/dev/null 2> "$WORK/716/rev-sub30.err" || rc=$?
[ "$rc" -eq 78 ] || fail "#716: review cap with <30s left rc=$rc want 78 ($(cat "$WORK/716/rev-sub30.err"))"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail '#716: review cap with <30s left must not resume (1 call)'

# Finding 4: --continue-on-max-turns 0 in review/advise disables the synthesis resume (1 grok call, exit 78).
: > "$STUB_GROK_CALLS"
rc=0
printf 'review continue 0\n' | STUB_GROK_RESULT=maxturns \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --continue-on-max-turns 0 --out "$WORK/716/rev-cont0.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-cont0.err" || rc=$?
[ "$rc" -eq 78 ] || fail "#716: review --continue-on-max-turns 0 at cap rc=$rc want 78"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail '#716: review --continue-on-max-turns 0 must make only 1 grok call'

# Review cap reached, resume also fails on max turns -> exit 78 (never 76 or 1), reason on stderr, pool treats 78 as a result.
: > "$STUB_GROK_CALLS"
rc=0
printf 'review cap resume fail\n' | STUB_GROK_RESULT=maxturns \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-cap-fail.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-cap-fail.err" || rc=$?
[ "$rc" -eq 78 ] || fail "#716: review cap reached + resume fail rc=$rc want 78"
[ "$rc" -ne 76 ] && [ "$rc" -ne 1 ] || fail '#716: review cap failure must never be 76 or 1'
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 2 ] || fail '#716: review cap failure tried the one synthesis resume'
contains "$WORK/716/rev-cap-fail.err" 'run-grok: max turns reached (5) in --mode review; no verdict' \
  '#716: review cap failure prints reason on stderr'
contains "$WORK/716/rev-cap-fail.err" 'exit=78' '#716: mmo_finish preserves exit=78'

# Finding 3: resume failing with provider/validation error keeps its own exit code (429 -> 75, body without verdict -> 6 on stdout).
: > "$STUB_GROK_CALLS"
rc=0
printf 'review cap then 429\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_RESUME_RESULT=transient \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-cap-429.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-cap-429.err" || rc=$?
[ "$rc" -eq 75 ] || fail "#716: review cap then 429 rc=$rc want 75 ($(cat "$WORK/716/rev-cap-429.err"))"
contains "$WORK/716/rev-cap-429.err" 'failure=transient' '#716: review cap then 429 reports failure=transient'
contains "$WORK/716/rev-cap-429.err" 'truncated=turns' '#716: review cap then 429 keeps truncated=turns'

: > "$STUB_GROK_CALLS"
rc=0
cap6_out="$(printf 'review cap then no verdict\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_RESUME_RESULT=progress \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --max-turns 5 \
  --out "$WORK/716/rev-cap-6.out" --timeout 60 2> "$WORK/716/rev-cap-6.err")" || rc=$?
[ "$rc" -eq 6 ] || fail "#716: review cap then body without verdict rc=$rc want 6 ($(cat "$WORK/716/rev-cap-6.err"))"
[ "$cap6_out" = 'Let me inspect the files.' ] || fail "#716: review cap then exit 6 exposes body on stdout ($cap6_out)"
contains "$WORK/716/rev-cap-6.err" 'truncated=turns' '#716: review cap then exit 6 keeps truncated=turns'

# Pool treats exit 78 as a result, not as worker unavailable.
printf 'T2\tgrok\tgrok-4.7\tmedium\nT2\tcodex\tgpt-6.1-sol\tmedium\n' > "$WORK/716/tiers.tsv"
: > "$STUB_GROK_CALLS"
rc=0
printf 'pool review cap fail\n' | MMO_POOL_TIERS="$WORK/716/tiers.tsv" STUB_GROK_RESULT=maxturns \
  bash "$PLUGIN_ROOT/scripts/pool.sh" run --tier T2 --mode review --base HEAD --usage /dev/null \
  --repo "$WORK/repo" --timeout 60 --out "$WORK/716/pool-cap.out" >/dev/null 2> "$WORK/716/pool-cap.err" || rc=$?
[ "$rc" -eq 78 ] || fail "#716: pool.sh run returns exit 78 directly (got $rc)"
absent "$WORK/716/pool-cap.err" 'unavailable' '#716: pool.sh run does not treat exit 78 as worker unavailable'
contains "$WORK/716/pool-cap.err" 'pool: exit=78 worker=grok' '#716: pool.sh run reports exit=78 from grok'

# Review leg whose inspect call times out makes one grok call and exits 124 with no truncated= field.
: > "$STUB_GROK_CALLS"
rc=0
printf 'review inspect timeout\n' | STUB_GROK_RESULT=timeout \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/716/rev-timeout.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-timeout.err" || rc=$?
[ "$rc" -eq 124 ] || fail "#716: review inspect timeout rc=$rc want 124 ($(cat "$WORK/716/rev-timeout.err"))"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail '#716: review inspect timeout makes 1 grok call'
absent "$WORK/716/rev-timeout.err" 'truncated=' '#716: review inspect timeout has no truncated= field'
pass '#716: Grok review/advise turn budget, default .stream, read-only allowlist synthesis on cap, exit 78'

# #621: --out /dev/stdout success path must exit 0 with the verdict on its own line.
rc=0
dev_out="$(printf x | STUB_GROK_RESULT=ok "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --out /dev/stdout --timeout 10 2> "$WORK/grok-devout.err")" || rc=$?
[ "$rc" -eq 0 ] || fail "grok --out /dev/stdout success rc=$rc want 0"
printf '%s\n' "$dev_out" | grep -qx 'APPROVE' || fail 'grok --out /dev/stdout verdict not on its own line'
pass '#621: grok --out /dev/stdout success path exits 0'
rc=0
printf x | STUB_GROK_RESULT=progress "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --out /dev/stdout --timeout 10 >/dev/null 2> "$WORK/grok-devout-nv.err" || rc=$?
[ "$rc" -eq 6 ] || fail "grok --out /dev/stdout review without verdict rc=$rc want 6"
rc=0
printf x | STUB_GROK_RESULT=ok "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --out /dev/stdout --timeout 10 > "$WORK/grok-devout-file.out" 2> "$WORK/grok-devout-file.err" || rc=$?
[ "$rc" -eq 0 ] || fail "grok --out /dev/stdout to file rc=$rc want 0"
[ "$(grep -c 'grok findings' "$WORK/grok-devout-file.out")" -eq 1 ] || fail 'grok --out /dev/stdout to file must hold the body exactly once'
rc=0
printf x | STUB_GROK_RESULT=transient503 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --out /dev/stdout --timeout 10 >/dev/null 2> "$WORK/grok-devout-tr.err" || rc=$?
[ "$rc" -eq 75 ] || fail "grok --out /dev/stdout transient rc=$rc want 75"
contains "$WORK/grok-devout-tr.err" 'failure=transient' 'grok --out /dev/stdout classifies transient failure'
pass '#621: grok --out /dev/* keeps verdict check, file stdout, and failure classification'

# #625: claude/codex --out /dev/stdout piped: body once, verdict gate intact.
for r in claude codex; do
  case "$r" in claude) rs=STUB_CLAUDE_RESULT nv=progress ;; codex) rs=STUB_CODEX_RESULT nv=noverdict ;; esac
  printf x | env "$rs=ok" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$WORK/repo" --base HEAD --out /dev/stdout --timeout 10 2> "$WORK/$r-devout.err" | cat > "$WORK/$r-devout.out"
  [ "${PIPESTATUS[1]}" -eq 0 ] || fail "$r --out /dev/stdout success rc want 0"
  [ "$(grep -c "$r findings" "$WORK/$r-devout.out")" -eq 1 ] || fail "$r --out /dev/stdout piped must hold the body exactly once"
  rc=0
  printf x | env "$rs=$nv" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$WORK/repo" --base HEAD --out /dev/stdout --timeout 10 >/dev/null 2> "$WORK/$r-devout-nv.err" || rc=$?
  [ "$rc" -eq 6 ] || fail "$r --out /dev/stdout review without verdict rc=$rc want 6"
done
pass '#625: claude/codex --out /dev/stdout: body once, verdict gate intact'

# usage() must advertise the shared flag surface
contains "$PLUGIN_ROOT/scripts/run-claude.sh" '--stream-log FILE' 'Claude usage lists --stream-log'
contains "$PLUGIN_ROOT/scripts/run-claude.sh" '--max-turns N' 'Claude usage lists --max-turns'
contains "$PLUGIN_ROOT/scripts/run-grok.sh" '--stream-log FILE' 'Grok usage lists --stream-log'
contains "$PLUGIN_ROOT/scripts/run-codex.sh" '--base REF' 'Codex usage lists --base'
contains "$PLUGIN_ROOT/scripts/run-codex.sh" '--max-turns N' 'Codex usage lists --max-turns'
# unknown flags stay loud
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --bogus 1 \
  >/dev/null 2> "$WORK/flag-dest/claude-unknown.err"; then
  fail 'Claude unknown option still rejected'
fi
contains "$WORK/flag-dest/claude-unknown.err" 'unknown option' 'Claude unknown-option path stays loud'
pass '#517 req2: shared flags accepted; honor or name-the-flag; stream-log streams'

# Regression: under --stream-log, normalize the provider's failure
# (PIPESTATUS[0]), not tee's always-success rc (PIPESTATUS[1]). Assert the
# final, stream, and ${out}.stderr artifacts still exist.
mkdir -p "$WORK/stream-fail"
set +e
printf 'claude stream fail\n' | STUB_CLAUDE_RESULT=error \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 \
  --out "$WORK/stream-fail/claude-final.txt" \
  --stream-log "$WORK/stream-fail/claude.stream" --timeout 5 \
  >/dev/null 2> "$WORK/stream-fail/claude-run.err"
claude_stream_fail_rc=$?
set -e
[ "$claude_stream_fail_rc" -eq 1 ] || fail "Claude --stream-log provider failure rc=$claude_stream_fail_rc want 1 (normalized provider failure)"
[ -f "$WORK/stream-fail/claude-final.txt" ] || fail 'Claude --stream-log failure still writes --out artifact'
[ -f "$WORK/stream-fail/claude.stream" ] || fail 'Claude --stream-log failure still writes stream artifact'
[ -f "$WORK/stream-fail/claude-final.txt.stderr" ] || fail 'Claude --stream-log failure still writes ${out}.stderr artifact'
set +e
printf 'grok stream fail\n' | STUB_GROK_RESULT=error \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/stream-fail/grok-final.txt" \
  --stream-log "$WORK/stream-fail/grok.stream" --timeout 5 \
  >/dev/null 2> "$WORK/stream-fail/grok-run.err"
grok_stream_fail_rc=$?
set -e
[ "$grok_stream_fail_rc" -eq 1 ] || fail "Grok --stream-log provider failure rc=$grok_stream_fail_rc want 1"
[ -f "$WORK/stream-fail/grok-final.txt" ] || fail 'Grok --stream-log failure still writes --out artifact'
[ -f "$WORK/stream-fail/grok.stream" ] || fail 'Grok --stream-log failure still writes stream artifact'
[ -f "$WORK/stream-fail/grok-final.txt.stderr" ] || fail 'Grok --stream-log failure still writes ${out}.stderr artifact'
pass '#517 regression: --stream-log propagates provider exit, not tee'

# Regression: provider exit 0 through tee into an unwritable --stream-log path
# must fail with tee's status and name the stream path (not report success).
mkdir -p "$WORK/stream-tee-fail"
bad_claude_stream="$WORK/stream-tee-fail/missing-dir/claude.stream"
bad_grok_stream="$WORK/stream-tee-fail/missing-dir/grok.stream"
set +e
printf 'claude tee fail\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 \
  --out "$WORK/stream-tee-fail/claude-final.txt" \
  --stream-log "$bad_claude_stream" --timeout 5 \
  >/dev/null 2> "$WORK/stream-tee-fail/claude-run.err"
claude_tee_fail_rc=$?
set -e
[ "$claude_tee_fail_rc" -ne 0 ] || fail 'Claude unwritable --stream-log must not exit 0'
contains "$WORK/stream-tee-fail/claude-run.err" "$bad_claude_stream" 'Claude tee failure names stream path'
set +e
printf 'grok tee fail\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/stream-tee-fail/grok-final.txt" \
  --stream-log "$bad_grok_stream" --timeout 5 \
  >/dev/null 2> "$WORK/stream-tee-fail/grok-run.err"
grok_tee_fail_rc=$?
set -e
[ "$grok_tee_fail_rc" -ne 0 ] || fail 'Grok unwritable --stream-log must not exit 0'
contains "$WORK/stream-tee-fail/grok-run.err" "$bad_grok_stream" 'Grok tee failure names stream path'
pass '#517 regression: --stream-log tee write failure fails and names path'

# --- #523 Claude --stream-log must be live (stream-json); --out stays final message ---
mkdir -p "$WORK/523"

# (a) completed --stream-log: --out equals result text; stream holds event lines.
printf 'claude 523a\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/a-final.txt" \
  --stream-log "$WORK/523/a.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/a.err" \
  || fail '523a: completed --stream-log run succeeds'
[ "$(cat "$WORK/523/a-final.txt")" = $'claude findings\nAPPROVE' ] || fail '523a: --out equals result text'
contains "$WORK/523/a.stream" '"type":"result"' '523a: stream holds result event'
contains "$WORK/523/a.stream" '"type":"system"' '523a: stream holds event lines'
pass '#523a: completed --stream-log extracts result text; stream holds events'

# (b) live stream: events then sleep past --timeout leaves a non-empty stream file.
set +e
printf 'claude 523b\n' | STUB_CLAUDE_RESULT=live_sleep \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/b-final.txt" \
  --stream-log "$WORK/523/b.stream" --timeout 2 \
  >/dev/null 2> "$WORK/523/b.err"
claude_523b_rc=$?
set -e
[ "$claude_523b_rc" -ne 0 ] || fail '523b: live mid-stream kill must exit nonzero'
[ -s "$WORK/523/b.stream" ] || fail '523b: killed mid-stream must leave a non-empty stream file'
pass '#523b: --stream-log is live (non-empty after mid-stream kill)'

# (c) error result (is_error:true) with provider exit 0: fail and name the stream file.
set +e
printf 'claude 523c\n' | STUB_CLAUDE_RESULT=stream_error \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/c-final.txt" \
  --stream-log "$WORK/523/c.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/c.err"
claude_523c_rc=$?
set -e
[ "$claude_523c_rc" -ne 0 ] || fail '523c: error result must not report success'
contains "$WORK/523/c.err" 'error result in --stream-log' '523c: error result message'
contains "$WORK/523/c.err" "$WORK/523/c.stream" '523c: error result names stream file'
pass '#523c: error result fails nonzero and names the stream file'

# (d) without --stream-log: argv stays --output-format text (not stream-json).
printf 'claude 523d\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/d-final.txt" --timeout 5 \
  >/dev/null 2> "$WORK/523/d.err" \
  || fail '523d: run without --stream-log succeeds'
exact_line "$WORK/claude.args" 'text' '523d: without --stream-log uses --output-format text'
absent "$WORK/claude.args" 'stream-json' '523d: without --stream-log omits stream-json'
absent "$WORK/claude.args" '--verbose' '523d: without --stream-log omits --verbose'
pass '#523d: without --stream-log invocation stays text mode'

# (e) review mode with --stream-log: verdict gate reads extracted final message.
printf 'claude 523e\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" \
  --base HEAD --model claude-haiku-5-5 --out "$WORK/523/e-final.txt" \
  --stream-log "$WORK/523/e.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/e.err" \
  || fail '523e: review with --stream-log must pass on APPROVE'
contains "$WORK/523/e-final.txt" 'APPROVE' '523e: --out holds extracted APPROVE verdict'
pass '#523e: review --stream-log verdict gate reads extracted final message'

# (f) valid success result followed by truncated JSON: provider 0 → runner non-zero.
set +e
printf 'claude 523f\n' | STUB_CLAUDE_RESULT=stream_trunc_after \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/f-final.txt" \
  --stream-log "$WORK/523/f.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/f.err"
claude_523f_rc=$?
set -e
[ "$claude_523f_rc" -ne 0 ] || fail '523f: truncated line after result must exit nonzero'
contains "$WORK/523/f.err" 'malformed' '523f: malformed stream message'
contains "$WORK/523/f.err" "$WORK/523/f.stream" '523f: malformed stream names stream file'
pass '#523f: truncated line after result fails and names the stream file'

# (g) non-JSON before a valid success result: not the missing-or-empty guard.
set +e
printf 'claude 523g\n' | STUB_CLAUDE_RESULT=stream_bad_before \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/g-final.txt" \
  --stream-log "$WORK/523/g.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/g.err"
claude_523g_rc=$?
set -e
[ "$claude_523g_rc" -eq 1 ] || fail "523g: bad line before result rc=$claude_523g_rc want 1"
contains "$WORK/523/g.err" 'malformed' '523g: malformed stream message'
contains "$WORK/523/g.err" "$WORK/523/g.stream" '523g: malformed stream names stream file'
absent "$WORK/523/g.err" 'missing or empty final-message artifact' \
  '523g: must not use missing-or-empty message'
pass '#523g: bad line before result fails as malformed, not missing-or-empty'

# (h) success result without string .result: fail; --out must not contain null.
set +e
printf 'claude 523h\n' | STUB_CLAUDE_RESULT=stream_null_result \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/h-final.txt" \
  --stream-log "$WORK/523/h.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/h.err"
claude_523h_rc=$?
set -e
[ "$claude_523h_rc" -ne 0 ] || fail '523h: success without string .result must exit nonzero'
contains "$WORK/523/h.err" "$WORK/523/h.stream" '523h: null-result failure names stream file'
absent "$WORK/523/h-final.txt" 'null' '523h: --out must not contain null'
pass '#523h: success without string .result fails; --out has no null'

# (i) success result with non-string .result (number): fail; do not coerce into --out.
set +e
printf 'claude 523i\n' | STUB_CLAUDE_RESULT=stream_number_result \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/i-final.txt" \
  --stream-log "$WORK/523/i.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/i.err"
claude_523i_rc=$?
set -e
[ "$claude_523i_rc" -ne 0 ] || fail '523i: non-string .result must exit nonzero'
contains "$WORK/523/i.err" "$WORK/523/i.stream" '523i: non-string .result failure names stream file'
absent "$WORK/523/i-final.txt" '42' '523i: --out must not contain coerced 42'
pass '#523i: non-string .result fails; stream named; no coerced --out'

# (j) success with empty-string .result: missing-or-empty guard (rc=5), empty --out.
set +e
printf 'claude 523j\n' | STUB_CLAUDE_RESULT=stream_empty_result \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/j-final.txt" \
  --stream-log "$WORK/523/j.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/j.err"
claude_523j_rc=$?
set -e
[ "$claude_523j_rc" -eq 5 ] || fail "523j: empty-string .result rc=$claude_523j_rc want 5"
contains "$WORK/523/j.err" 'missing or empty final-message artifact' \
  '523j: missing-or-empty message'
contains "$WORK/523/j.err" "$WORK/523/j-final.txt" '523j: message names --out'
[ -f "$WORK/523/j-final.txt" ] && [ ! -s "$WORK/523/j-final.txt" ] \
  || fail '523j: --out must exist and be empty'
pass '#523j: empty-string .result exits 5 with empty --out'

# (k) final --out write failure must not report success (--out replaced by a dir).
set +e
printf 'claude 523k\n' | STUB_CLAUDE_RESULT=stream_out_dir \
  STUB_LOCK_OUT="$WORK/523/k-final.txt" \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/k-final.txt" \
  --stream-log "$WORK/523/k.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/k.err"
claude_523k_rc=$?
set -e
# Remove the directory stand-in even on assertion failure.
rm -rf "$WORK/523/k-final.txt"
[ "$claude_523k_rc" -ne 0 ] || fail '523k: failed final --out write must not exit 0'
contains "$WORK/523/k.err" 'failed writing final message' '523k: write-failure diagnostic'
contains "$WORK/523/k.err" "$WORK/523/k-final.txt" '523k: diagnostic names --out'
pass '#523k: final --out write failure exits nonzero and names path'

# (l) provider exit 0 with empty stream under --stream-log: missing-or-empty
# guard (rc=5), not malformed (jq -e would false-positive on empty input).
set +e
printf 'claude 523l\n' | STUB_CLAUDE_RESULT=empty \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/523/l-final.txt" \
  --stream-log "$WORK/523/l.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/l.err"
claude_523l_rc=$?
set -e
[ "$claude_523l_rc" -eq 5 ] || fail "523l: empty stream rc=$claude_523l_rc want 5"
contains "$WORK/523/l.err" 'missing or empty final-message artifact' \
  '523l: missing-or-empty message'
absent "$WORK/523/l.err" 'malformed stream' '523l: must not report malformed stream'
pass '#523l: empty stream under --stream-log exits 5, not malformed'

# README/contract: jq is required for Claude --stream-log and the local-Qwen route.
absent "$PLUGIN_ROOT/README.md" 'No `jq` dependency is used' \
  'README must not claim no jq dependency'
contains "$PLUGIN_ROOT/README.md" \
  '`jq` is required for `run-claude.sh --stream-log`, `run-agy.sh`, `run-muse.sh`, `run-opencode.sh`, `run-vibe.sh`, and the local-Qwen route' \
  'README documents where jq is required'
pass 'README documents jq for Claude --stream-log, agy, Muse, OpenCode, Vibe, and local Qwen'

# Req 3: run-codex.sh resolves --dir/--repo to a git toplevel (match claude/grok).
# Intentional behavior change vs 0.7.6: existing non-git directory exits 2.
mkdir -p "$WORK/not-a-repo"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/not-a-repo" \
  --timeout 5 >/dev/null 2> "$WORK/codex-toplevel.err"
codex_nongit_rc=$?
set -e
[ "$codex_nongit_rc" -eq 2 ] || fail "Codex non-git directory rc=$codex_nongit_rc want 2"
[ "$(cat "$WORK/codex-toplevel.err" | head -1 | wc -c)" -gt 0 ] || fail 'Codex non-git failure prints a message'
# Positive: subdirectory of a git repo resolves to toplevel (codex -C gets toplevel).
mkdir -p "$WORK/repo/subdir"
printf 'toplevel resolve\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo/subdir" \
  --timeout 5 >/dev/null 2> "$WORK/codex-toplevel-ok.err" \
  || fail 'Codex resolves a git subdirectory to toplevel'
exact_line "$WORK/codex.args" "$WORK/repo" 'Codex -C uses git toplevel not the subdirectory'
pass '#517 req3: Codex resolves repo arg to git toplevel'

# Req 4: exit 0 with a missing OR empty final-message artifact is failure;
# message names the artifact in both states.
rm -f "$WORK/empty-claude.txt" "$WORK/empty-codex.txt" "$WORK/empty-grok.txt"
: > "$WORK/empty-claude.txt"
: > "$WORK/empty-codex.txt"
: > "$WORK/empty-grok.txt"
if printf x | STUB_CLAUDE_RESULT=empty "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/empty-claude.txt" --timeout 5 \
  >/dev/null 2> "$WORK/empty-claude.err"; then
  fail 'Claude empty final-message must not exit 0'
fi
contains "$WORK/empty-claude.err" "$WORK/empty-claude.txt" 'Claude empty-output message names the artifact'
if printf x | STUB_CODEX_RESULT=empty "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" \
  --out "$WORK/empty-codex.txt" --timeout 5 \
  >/dev/null 2> "$WORK/empty-codex.err"; then
  fail 'Codex empty final-message must not exit 0'
fi
contains "$WORK/empty-codex.err" "$WORK/empty-codex.txt" 'Codex empty-output message names the artifact'
if printf x | STUB_GROK_RESULT=empty "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/empty-grok.txt" --timeout 5 \
  >/dev/null 2> "$WORK/empty-grok.err"; then
  fail 'Grok empty final-message must not exit 0'
fi
contains "$WORK/empty-grok.err" "$WORK/empty-grok.txt" 'Grok empty-output message names the artifact'
[ -f "$WORK/empty-claude.txt" ] && [ ! -s "$WORK/empty-claude.txt" ] || fail 'Claude empty artifact exists and is empty'
[ -f "$WORK/empty-codex.txt" ] && [ ! -s "$WORK/empty-codex.txt" ] || fail 'Codex empty artifact exists and is empty'
[ -f "$WORK/empty-grok.txt" ] && [ ! -s "$WORK/empty-grok.txt" ] || fail 'Grok empty artifact exists and is empty'

# Missing artifact (rc=0, path absent): the silent no-op case req4 closes.
# Assert the guard message (not merely non-zero exit): a missing --out also
# trips `cat` under set -e, which is not the req4 failure mode.
rm -f "$WORK/missing-claude.txt" "$WORK/missing-codex.txt" "$WORK/missing-grok.txt"
set +e
printf x | STUB_CLAUDE_RESULT=missing STUB_UNLINK_OUT="$WORK/missing-claude.txt" \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-5-5 --out "$WORK/missing-claude.txt" --timeout 5 \
  >/dev/null 2> "$WORK/missing-claude.err"
missing_claude_rc=$?
set -e
[ "$missing_claude_rc" -eq 5 ] || fail "Claude missing final-message rc=$missing_claude_rc want 5"
contains "$WORK/missing-claude.err" 'final-message artifact' 'Claude missing-output guard message'
contains "$WORK/missing-claude.err" "$WORK/missing-claude.txt" 'Claude missing-output message names the artifact'
[ ! -f "$WORK/missing-claude.txt" ] || fail 'Claude missing artifact path must stay absent'
set +e
printf x | STUB_CODEX_RESULT=missing "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" \
  --out "$WORK/missing-codex.txt" --timeout 5 \
  >/dev/null 2> "$WORK/missing-codex.err"
missing_codex_rc=$?
set -e
[ "$missing_codex_rc" -eq 5 ] || fail "Codex missing final-message rc=$missing_codex_rc want 5"
contains "$WORK/missing-codex.err" 'final-message artifact' 'Codex missing-output guard message'
contains "$WORK/missing-codex.err" "$WORK/missing-codex.txt" 'Codex missing-output message names the artifact'
[ ! -f "$WORK/missing-codex.txt" ] || fail 'Codex missing artifact path must stay absent'
set +e
printf x | STUB_GROK_RESULT=missing STUB_UNLINK_OUT="$WORK/missing-grok.txt" \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" \
  --out "$WORK/missing-grok.txt" --timeout 5 \
  >/dev/null 2> "$WORK/missing-grok.err"
missing_grok_rc=$?
set -e
[ "$missing_grok_rc" -eq 5 ] || fail "Grok missing final-message rc=$missing_grok_rc want 5"
contains "$WORK/missing-grok.err" 'final-message artifact' 'Grok missing-output guard message'
contains "$WORK/missing-grok.err" "$WORK/missing-grok.txt" 'Grok missing-output message names the artifact'
[ ! -f "$WORK/missing-grok.txt" ] || fail 'Grok missing artifact path must stay absent'
pass '#517 req4: missing or empty final-message on exit 0 fails and names the artifact'

# --- #521: untracked --no-index exit >1 must fail the review leg (not silent drop) ---
# Pattern from PR #522 Codex verification: shim git so --no-index exits 2; a
# tracked change keeps the run green if the error is swallowed, so a silent
# || true would falsely pass. Exit 1 (files differ) must still succeed.
mkdir -p "$WORK/untracked-repo" "$WORK/git-shim-fail" "$WORK/git-shim-ok"
git -C "$WORK/untracked-repo" init -q
git -C "$WORK/untracked-repo" config user.email test@example.com
git -C "$WORK/untracked-repo" config user.name Test
printf 'base\n' > "$WORK/untracked-repo/app.txt"
git -C "$WORK/untracked-repo" add app.txt
git -C "$WORK/untracked-repo" commit -qm base
printf 'changed\n' > "$WORK/untracked-repo/app.txt"
printf 'trigger no-index failure\n' > "$WORK/untracked-repo/bad-untracked.txt"
real_git="$(command -v git)"
cat > "$WORK/git-shim-fail/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != --no-index ] || exit 2
done
exec "$real_git" "\$@"
EOF
chmod +x "$WORK/git-shim-fail/git"
cat > "$WORK/git-shim-ok/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != --no-index ] || exit 1
done
exec "$real_git" "\$@"
EOF
chmod +x "$WORK/git-shim-ok/git"

set +e
printf 'claude untracked fail\n' | PATH="$WORK/git-shim-fail:$PATH" \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/untracked-repo" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/claude-untracked-fail.err"
claude_untracked_fail_rc=$?
set -e
[ "$claude_untracked_fail_rc" -ne 0 ] || fail 'Claude must fail when untracked --no-index exits 2'
contains "$WORK/claude-untracked-fail.err" 'failed to include untracked file in review diff' \
  'Claude untracked --no-index exit 2 names the failure'
contains "$WORK/claude-untracked-fail.err" 'bad-untracked.txt' \
  'Claude untracked --no-index exit 2 names the file'
set +e
printf 'claude untracked ok\n' | PATH="$WORK/git-shim-ok:$PATH" \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/untracked-repo" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/claude-untracked-ok.err"
claude_untracked_ok_rc=$?
set -e
[ "$claude_untracked_ok_rc" -eq 0 ] || fail "Claude must tolerate untracked --no-index exit 1 (rc=$claude_untracked_ok_rc)"
pass '#521: Claude fails loud on untracked --no-index exit >1; tolerates exit 1'

set +e
printf 'grok untracked fail\n' | PATH="$WORK/git-shim-fail:$PATH" \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/untracked-repo" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/grok-untracked-fail.err"
grok_untracked_fail_rc=$?
set -e
[ "$grok_untracked_fail_rc" -ne 0 ] || fail 'Grok must fail when untracked --no-index exits 2'
contains "$WORK/grok-untracked-fail.err" 'failed to include untracked file in review diff' \
  'Grok untracked --no-index exit 2 names the failure'
contains "$WORK/grok-untracked-fail.err" 'bad-untracked.txt' \
  'Grok untracked --no-index exit 2 names the file'
set +e
printf 'grok untracked ok\n' | PATH="$WORK/git-shim-ok:$PATH" \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/untracked-repo" \
  --base HEAD --timeout 5 >/dev/null 2> "$WORK/grok-untracked-ok.err"
grok_untracked_ok_rc=$?
set -e
[ "$grok_untracked_ok_rc" -eq 0 ] || fail "Grok must tolerate untracked --no-index exit 1 (rc=$grok_untracked_ok_rc)"
pass '#521: Grok fails loud on untracked --no-index exit >1; tolerates exit 1'

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
[ "$(grep -l 'mmo_implement_prompt' "$PLUGIN_ROOT"/scripts/run-*.sh | wc -l)" -eq 8 ] || fail 'all eight implement runners use mmo_implement_prompt'
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

# review-gate: the advisory local engine may never be the only reviewer.
GATE="$PLUGIN_ROOT/scripts/review-gate.sh"
gate_dir="$WORK/gate"
mkdir -p "$gate_dir"
printf 'nothing blocking\n\nAPPROVE\n' > "$gate_dir/qwen.txt"
printf 'fine\n\nAPPROVE\n' > "$gate_dir/codex.txt"
printf 'a real problem\n\nNEEDS_WORK\n' > "$gate_dir/grok.txt"
printf 'prose with no verdict\n' > "$gate_dir/noverdict.txt"

rc=0
bash "$GATE" --leg qwen-local="$gate_dir/qwen.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "a local-only review set exits 3 (got $rc)"
rc=0
bash "$GATE" --leg qwen-local-8b="$gate_dir/qwen.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "any qwen-local-* provider is advisory (got $rc)"
out="$(bash "$GATE" --leg qwen-local="$gate_dir/qwen.txt" --leg codex="$gate_dir/codex.txt")"
[ "$out" = "APPROVE" ] || fail "local plus an independent approver returns APPROVE (got $out)"
rc=0
out="$(bash "$GATE" --leg qwen-local="$gate_dir/qwen.txt" --leg grok="$gate_dir/grok.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "NEEDS_WORK" ] || fail "any NEEDS_WORK leg wins (got $rc/$out)"
rc=0
bash "$GATE" --leg codex="$gate_dir/noverdict.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a leg without a terminal verdict exits 2 (got $rc)"
rc=0
bash "$GATE" --leg codex="$gate_dir/missing.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable leg exits 2 (got $rc)"
rc=0
bash "$GATE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "no legs is a usage error (got $rc)"
# --author: a leg must come from a hosted provider family other than the author's.
gate_author() { # EXPECTED_RC DESCRIPTION ARGS...
  local want="$1" desc="$2" got=0; shift 2
  bash "$GATE" "$@" >/dev/null 2>"$gate_dir/author.err" || got=$?
  [ "$got" -eq "$want" ] || fail "gate $desc: want $want, got $got"
}
gate_author 3 '--author codex --leg codex' --author codex --leg codex="$gate_dir/codex.txt"
contains "$gate_dir/author.err" 'other than the author' 'same-family gate exit 3 names the author rule'
gate_author 3 '--author gpt-6.1-sol --leg astra' --author gpt-6.1-sol --leg astra="$gate_dir/codex.txt"
gate_author 0 '--author codex --leg grok' --author codex --leg grok="$gate_dir/codex.txt"
gate_author 0 '--author qwen --leg codex' --author qwen --leg codex="$gate_dir/codex.txt"
gate_author 0 '--author claude-opus-5-5 --leg sonnet --leg codex' --author claude-opus-5-5 --leg sonnet="$gate_dir/codex.txt" --leg codex="$gate_dir/codex.txt"
gate_author 3 '--author grok --leg qwen' --author grok --leg qwen="$gate_dir/codex.txt"
gate_author 2 '--author without a value' --leg codex="$gate_dir/codex.txt" --author
gate_author 0 'no --author keeps --leg codex independent' --leg codex="$gate_dir/codex.txt"
gate_author 3 'agy is not a hosted label' --leg agy="$gate_dir/codex.txt"
gate_author 3 'opencode is not a hosted label' --leg opencode="$gate_dir/codex.txt"
pass 'review-gate --author requires a reviewer from another provider family'

# --- handoff-lease.sh ---
LEASE="$PLUGIN_ROOT/scripts/handoff-lease.sh"
lease_dir="$WORK/lease"
lease_rc() { local got=0; "$@" >/dev/null 2>"$WORK/lease.err" || got=$?; printf '%s' "$got"; }
[ "$(lease_rc bash "$LEASE" claim a1 --dir "$lease_dir")" = 0 ] || fail 'lease: first claim succeeds'
case "$(cat "$lease_dir/.lease")" in 'a1 '*) ;; *) fail 'lease: the lease file starts with the owner' ;; esac
[ "$(lease_rc bash "$LEASE" claim b2 --dir "$lease_dir")" = 75 ] || fail 'lease: a second owner exits 75'
contains "$WORK/lease.err" 'held by a1' 'lease: exit 75 names the holder'
[ "$(lease_rc bash "$LEASE" claim a1 --dir "$lease_dir")" = 0 ] || fail 'lease: the owner renews'
[ "$(lease_rc bash "$LEASE" release b2 --dir "$lease_dir")" = 0 ] || fail 'lease: a non-owner release exits 0'
[ -f "$lease_dir/.lease" ] || fail 'lease: a non-owner release leaves the lease in place'
case "$(cat "$lease_dir/.lease")" in 'a1 '*) ;; *) fail 'lease: still held by a1 after b2 release' ;; esac
[ "$(lease_rc bash "$LEASE" release a1 --dir "$lease_dir")" = 0 ] || fail 'lease: owner release exits 0'
[ ! -e "$lease_dir/.lease" ] || fail 'lease: owner release removes the lease'
[ "$(lease_rc bash "$LEASE" claim b2 --dir "$lease_dir")" = 0 ] || fail 'lease: claim after release succeeds'
printf 'a1 1\n' > "$lease_dir/.lease"
[ "$(lease_rc bash "$LEASE" claim b2 --dir "$lease_dir")" = 0 ] || fail 'lease: an expired lease is taken over'
case "$(cat "$lease_dir/.lease")" in 'b2 '*) ;; *) fail 'lease: takeover rewrites the owner' ;; esac
for bad in 'claim a1 --ttl 0' 'claim a1 --ttl x' 'claim' 'claim a\ b' 'frobnicate a1'; do
  # shellcheck disable=SC2086
  [ "$(lease_rc bash "$LEASE" $bad --dir "$lease_dir")" = 2 ] || fail "lease: '$bad' exits 2"
done
[ "$(lease_rc bash "$LEASE" claim 'a b' --dir "$lease_dir")" = 2 ] || fail 'lease: an owner with a space exits 2'
lease_repo="$WORK/lease-repo"; mkdir -p "$lease_repo"; git -C "$lease_repo" init -q
(cd "$lease_repo" && bash "$LEASE" claim r1 >/dev/null 2>&1) || fail 'lease: default dir claim succeeds in a repo'
[ -f "$lease_repo/.claude/handoffs/.lease" ] || fail 'lease: default dir is <repo>/.claude/handoffs'
(cd "$lease_repo" && MMO_HANDOFF_DIR=state/h bash "$LEASE" claim r1 >/dev/null 2>&1) || fail 'lease: MMO_HANDOFF_DIR claim succeeds'
[ -f "$lease_repo/state/h/.lease" ] || fail 'lease: MMO_HANDOFF_DIR is relative to the repo root'
pass 'handoff-lease: claim, renew, release, expiry, usage, and default directories'
# Fail-closed labels: the catalog names for the local engine, other casings, and
# unknown providers are all advisory; only hosted catalog names count.
for label in 'Local Qwen' 'qwen3.8-27b-local' 'Qwen-Local' 'gemini' 'codex-local' 'opencode' 'kimi-k3.1-pro'; do
  rc=0
  bash "$GATE" --leg "$label=$gate_dir/qwen.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "label '$label' alone is advisory (got $rc)"
done
for label in codex Claude grok-4.7 grok-4.6 grok-4.5 muse-spark-1.3 gpt-6-astra claude-opus-5 gpt GPT-5.6; do
  out="$(bash "$GATE" --leg "Local Qwen=$gate_dir/qwen.txt" --leg "$label=$gate_dir/codex.txt")" \
    || fail "label '$label' counts as independent"
  [ "$out" = APPROVE ] || fail "label '$label' beside Local Qwen approves (got $out)"
done
# The verdict is the LAST verdict line: quoted options earlier must not decide it.
printf 'the options are:\n* NEEDS_WORK\n* APPROVE\n\nall fine\n\nAPPROVE\n' > "$gate_dir/quoted.txt"
out="$(bash "$GATE" --leg codex="$gate_dir/quoted.txt")" || fail 'quoted options with terminal APPROVE approves'
[ "$out" = APPROVE ] || fail "terminal verdict decides the leg (got $out)"
printf '%s\n' '**VERDICT: APPROVE.**' > "$gate_dir/approve-period.txt"
out="$(bash "$GATE" --leg claude="$gate_dir/approve-period.txt")" || fail 'gate accepts **VERDICT: APPROVE.**'
[ "$out" = APPROVE ] || fail "gate APPROVE. got $out"
printf '%s\n' 'VERDICT: NEEDS_WORK.' > "$gate_dir/needs-period.txt"
rc=0
out="$(bash "$GATE" --leg claude="$gate_dir/needs-period.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$out" = NEEDS_WORK ] || fail "gate NEEDS_WORK. got $rc/$out"
printf '%s\n' 'I approve.' > "$gate_dir/i-approve.txt"
rc=0
bash "$GATE" --leg claude="$gate_dir/i-approve.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "gate rejects 'I approve.' (got $rc)"
pass 'review-gate: the local engine can never be the only reviewer'
pass 'review-gate accepts one trailing period and still rejects prose'

contains "$PLUGIN_ROOT/skills/meta-orchestration/references/review-prompts.md" \
  'review-gate.sh' 'review-prompts points at the enforced gate'
# The meta loop is the surface that uses those prompts: it must call the gate,
# not hand-grep a verdict it could satisfy with an advisory leg alone.
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  'review-gate.sh' 'meta per-item loop combines legs through the gate'
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  'never hand-grep' 'meta loop forbids hand-grepping the verdict'
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  '${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh' 'meta loop calls the gate by plugin-root path'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" \
  'review-gate.sh' 'orchestration skill keeps the gate instruction'
contains "$PLUGIN_ROOT/commands/orchestrate.md" \
  'scripts/review-gate.sh' 'orchestrate fallback block calls the gate'
contains "$PLUGIN_ROOT/commands/orchestrate.md" \
  'Only a gate exit of 0 ends' 'NEEDS_WORK loops back through the gate instead of proceeding'

REANCHOR="$PLUGIN_ROOT/hooks/reanchor.sh"
R="$WORK/re anchor"; H="$R/.claude/handoffs"; mkdir -p "$H"
hook() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$R" bash "$REANCHOR"; }
[ -z "$(hook '{"source": "compact"}')" ] || fail 'Compact hook is silent without a handoff'
touch -t 200001010000 "$H/handoff-2026-01-01T0000Z.md"
[ -z "$(hook '{"source": "compact"}')" ] || fail 'Compact hook ignores a stale handoff'
touch "$H/handoff-2026-01-02T0000Z.md"
case "$(hook '{"hook_event_name":"SessionStart","source":"compact","model":"clear"}')" in
  *"handoff-2026-01-02T0000Z.md"*"--resume"*) ;; *) fail 'Compact hook reads the source field exactly and names the newest fresh handoff' ;; esac
for src in startup clear; do
  [ -z "$(hook "{\"source\": \"$src\"}" 2>&1)" ] || fail "Reanchor hook ignores SessionStart source $src"
done
mkdir -p "$WORK/abs-handoffs"; touch "$WORK/abs-handoffs/handoff-2026-01-03T0000Z.md"
case "$(printf '%s' '{"source":"compact"}' | MMO_HANDOFF_DIR="$WORK/abs-handoffs" CLAUDE_PROJECT_DIR="$R" bash "$REANCHOR")" in
  *"$WORK/abs-handoffs/handoff-2026-01-03T0000Z.md"*) ;; *) fail 'Reanchor hook honors an absolute MMO_HANDOFF_DIR' ;; esac
contains "$PLUGIN_ROOT/hooks/hooks.json" '"matcher": "compact"' 'Reanchor hook runs after compaction'
! grep -q '"matcher": "clear"' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'No clear hook: the desktop app does not restart a cleared session'
contains "$META_REFS/handoff-template.md" '## Brief' 'Handoff template carries the verbatim brief'
pass 'Reanchor hook re-points a compacted orchestrator at its newest handoff'

WATCH="$PLUGIN_ROOT/hooks/context-watch.sh"
CW="$WORK/cw"; mkdir -p "$CW"
cw_claude() { printf '{"type":"user","message":{"content":"/multi-model-orchestrator:meta-orchestrate epic"}}\n{"message":{"usage":{"input_tokens":2,"cache_read_input_tokens":%s,"cache_creation_input_tokens":1000}},"type":"assistant"}\n{"type":"attachment","attachment":{"type":"x"}}\n' "$1" > "$CW/claude.jsonl"; }
watch() { printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | MMO_CONTEXT_WARN_TOKENS=100000 bash "$WATCH"; }
cw_claude 50000
[ -z "$(watch s1 "$CW/claude.jsonl")" ] || fail 'Context watch is silent below the threshold'
cw_claude 120000
case "$(watch s1 "$CW/claude.jsonl")" in
  *'"hookEventName":"PostToolUse"'*'121002 tokens'*'compaction resumes from the handoff'*) ;; *) fail 'Context watch sums Claude usage and warns past the threshold' ;; esac
[ -z "$(watch s1 "$CW/claude.jsonl")" ] || fail 'Context watch warns once per crossing'
cw_claude 10000; watch s1 "$CW/claude.jsonl" >/dev/null; cw_claude 120000
[ -n "$(watch s1 "$CW/claude.jsonl")" ] || fail 'Context watch re-arms after context drops (compaction)'
printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":130000,"cached_input_tokens":120000}}}}\n{"type":"user","message":"$multi-model-orchestrator:meta-orchestrate epic"}\n' > "$CW/codex.jsonl"
case "$(watch s2 "$CW/codex.jsonl")" in *'130000 tokens'*) ;; *) fail 'Context watch reads Codex token_count input tokens' ;; esac
printf '{"type":"assistant","message":{"usage":{"input_tokens":200000}}}\n' > "$CW/plain.jsonl"
[ -z "$(watch s3 "$CW/plain.jsonl")" ] || fail 'Context watch stays silent outside meta-orchestrate sessions'
printf '{"type":"user","message":{"content":"/multi-model-orchestrator:meta-orchestrate go"}}\n' >> "$CW/plain.jsonl"
[ -n "$(watch s3 "$CW/plain.jsonl")" ] || fail 'Context watch warns when meta-orchestrate starts after the crossing'
[ -z "$(printf '{}' | bash "$WATCH")" ] || fail 'Context watch tolerates missing hook fields'
cw_over='{"type":"assistant","message":{"usage":{"input_tokens":200000}}}'
cw_case() { printf '%s\n%s\n' "$cw_over" "$2" > "$CW/case.jsonl"; watch "$1" "$CW/case.jsonl"; }
[ -z "$(cw_case sl1 '{"skills":["multi-model-orchestrator:meta-orchestrate"]}
- multi-model-orchestrator:meta-orchestration: Use when ... Entrypoint: /multi-model-orchestrator:meta-orchestrate.')" ] || fail 'Context watch ignores a skill listing that only mentions the skill'
[ -n "$(cw_case sl2 '{"type":"user","message":{"content":"<command-name>/multi-model-orchestrator:meta-orchestrate</command-name>"}}')" ] || fail 'Context watch warns on a command-name invocation'
[ -n "$(cw_case sl3 '{"name":"Skill","input":{"skill":"multi-model-orchestrator:meta-orchestration"}}')" ] || fail 'Context watch warns on a Skill tool invocation'
[ -n "$(cw_case sl4 '{"type":"user","message":"$multi-model-orchestrator:meta-orchestrate epic"}')" ] || fail 'Context watch warns on a $-prefixed Codex invocation'
[ -n "$(cw_case sl5 '{"type":"user","message":"# /multi-model-orchestrator:meta-orchestrate Codex Workflow"}')" ] || fail 'Context watch warns on the loaded Codex workflow heading'
[ -z "$(cw_case sl6 '{"type":"user","message":"Explain \"/multi-model-orchestrator:meta-orchestrate\" without running it"}')" ] || fail 'Context watch ignores a quoted mention of the command'
contains "$PLUGIN_ROOT/hooks/hooks.json" 'hooks/context-watch.sh' 'Context watch runs as a PostToolUse hook'
pass 'Context watch warns a meta-orchestrator once past MMO_CONTEXT_WARN_TOKENS'

USAGE_SH="$PLUGIN_ROOT/scripts/usage.sh"
U="$WORK/usage"; mkdir -p "$U/codex/sessions/2026/01/01" "$U/bin"
# Hermetic: a real agy on PATH must not answer these runs.
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/agy"; chmod +x "$U/bin/agy"
export PATH="$U/bin:$PATH"
future=$(( $(date +%s) + 90000 )); past=$(( $(date +%s) - 60 ))
rl() { printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":91.6,"window_minutes":10080,"resets_at":%s}}}}\n' "$1" "$2" "$future"; }
{ rl 10 "$future"; rl 40 "$past"; } > "$U/codex/sessions/2026/01/01/rollout-a.jsonl"
out=$(CODEX_HOME="$U/codex" PATH="$U/bin:$PATH" bash "$USAGE_SH")
case "$out" in *"codex 5h 0% (reset at"*) ;; *) fail "usage.sh zeroes a Codex window whose reset passed: $out" ;; esac
case "$out" in *"codex 7d 92% resets "*" in 1d1h0m as-of "*|*"codex 7d 92% resets "*" in 1d0h59m as-of "*) ;; *) fail "usage.sh reports the newest Codex secondary window: $out" ;; esac
case "$out" in *"claude unknown (pass --claude-log or --probe-claude"*"grok unknown"*"muse unknown (no stream log with run.usage; pass --muse-log)"*"opencode unknown"*) ;; *) fail "usage.sh names providers it cannot read: $out" ;; esac
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.014,"resetsAt":%s},"seven_day":{"utilization":0.86,"resetsAt":%s}}}}\n' "$future" "$future" > "$U/claude.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude.jsonl" --claude-log "$U/missing.jsonl")
case "$out" in *"codex unknown"*"claude 5h 1% resets"*"claude 7d 86% resets"*) ;; *) fail "usage.sh reads Claude windows from a stream log: $out" ;; esac
printf '#!/usr/bin/env bash\n[ "$PWD" != "%s" ] || exit 9\ncat "%s"\n' "$PWD" "$U/claude.jsonl" > "$U/bin/claude"; chmod +x "$U/bin/claude"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --probe-claude)
case "$out" in *"claude 7d 86% resets"*) ;; *) fail "usage.sh --probe-claude parses the probe stream: $out" ;; esac
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/claude"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --probe-claude)
case "$out" in *"claude unknown (probe returned no rate_limit_event)"*) ;; *) fail "usage.sh reports a failed probe as unknown: $out" ;; esac
set +e; bash "$USAGE_SH" --bogus >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || fail "usage.sh rejects unknown flags (got $rc)"

# Top-level per-model window (e.g. seven_day_opus) not among unifiedWindows is also emitted.
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":%s}},"rateLimitType":"seven_day_opus","utilization":1.0,"resetsAt":%s}}\n' "$future" "$future" > "$U/claude-toplevel.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude-toplevel.jsonl")
case "$out" in *"claude 7d_opus 100% resets"*) ;; *) fail "usage.sh emits a per-model top-level window not in unifiedWindows: $out" ;; esac

# A window with a non-numeric reset is dropped, not shown blank, while a valid sibling survives.
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":null},"seven_day":{"utilization":0.2,"resetsAt":%s}}}}\n' "$future" > "$U/claude-badreset.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude-badreset.jsonl")
case "$out" in *"claude 5h"*) fail "usage.sh should drop a Claude window with a non-numeric reset: $out" ;; esac
case "$out" in *"claude 7d 20% resets"*) ;; *) fail "usage.sh keeps a valid Claude window beside a dropped one: $out" ;; esac

mkdir -p "$U/codex-badreset/sessions/2026/01/01"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":"n/a","window_minutes":300,"resets_at":"2026-01-01"}}}}\n' > "$U/codex-badreset/sessions/2026/01/01/rollout-a.jsonl"
out=$(CODEX_HOME="$U/codex-badreset" PATH="$U/bin:$PATH" bash "$USAGE_SH")
case "$out" in *"codex unknown"*) ;; *) fail "usage.sh drops a Codex window with a non-numeric used value: $out" ;; esac

# A truncated final JSONL line must not hide the last complete event.
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.3,"resetsAt":%s}}}}\n{"type":"rate_limit_event","rate_limit_info":{"unifiedWindow' "$future" > "$U/claude-trunc.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude-trunc.jsonl")
case "$out" in *"claude 5h 30% resets"*) ;; *) fail "usage.sh keeps the last complete Claude event despite a truncated line after it: $out" ;; esac

mkdir -p "$U/codex-trunc/sessions/2026/01/01"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":15,"window_minutes":300,"resets_at":%s}}}}\n{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_pe' "$future" > "$U/codex-trunc/sessions/2026/01/01/rollout-a.jsonl"
out=$(CODEX_HOME="$U/codex-trunc" PATH="$U/bin:$PATH" bash "$USAGE_SH")
case "$out" in *"codex 5h 15% resets"*) ;; *) fail "usage.sh keeps the last complete Codex event despite a truncated line after it: $out" ;; esac

# Newer file mtime must not beat an older file whose last rate_limits event is newer (#577).
# Mtimes are offsets from now (older file first, both inside 8 days). Event order stays on .timestamp.
mkdir -p "$U/codex-order/sessions/old" "$U/codex-order/sessions/new"
order_older_ts='2026-10-03T12:00:00.500Z'
order_newer_ts='2026-10-01T00:00:00Z'
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":55,"window_minutes":300,"resets_at":%s}}}}\n' "$order_older_ts" "$future" > "$U/codex-order/sessions/old/rollout-older-mtime.jsonl"
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":%s}}}}\n' "$order_newer_ts" "$future" > "$U/codex-order/sessions/new/rollout-newer-mtime.jsonl"
order_now=$(date +%s)
touch -d "@$((order_now - 3 * 86400))" "$U/codex-order/sessions/old/rollout-older-mtime.jsonl"
touch -d "@$((order_now - 86400))" "$U/codex-order/sessions/new/rollout-newer-mtime.jsonl"
out=$(CODEX_HOME="$U/codex-order" PATH="$U/bin:$PATH" bash "$USAGE_SH")
expect_asof=$(jq -nr --arg t "$order_older_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
lose_asof=$(jq -nr --arg t "$order_newer_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
case "$out" in *"codex 5h 55% resets "*" as-of ${expect_asof}"*) ;; *) fail "usage.sh as-of follows the newer rate_limits event (want as-of ${expect_asof}): $out" ;; esac
case "$out" in *"codex 5h 10%"*|*"as-of ${lose_asof}"*) fail "usage.sh let the newer-mtime file hide a newer event: $out" ;; esac
absent "$USAGE_SH" 'date -u -d' 'usage.sh does not format times with GNU date -d'
absent "$USAGE_SH" 'stat -c' 'usage.sh does not read mtime with GNU stat -c'
absent "$USAGE_SH" '-printf' 'usage.sh does not list files with GNU find -printf'

# Only the 20 newest rollout files are candidates. A newer event in an older file stays unread.
# bi=0 is the oldest mtime; each later file is one minute newer, a few hours before now.
mkdir -p "$U/codex-bound/sessions"
bound_excluded_ts='2026-10-04T18:00:00Z'
bound_kept_ts='2026-10-03T08:00:00Z'
bound_base=$(( $(date +%s) - 4 * 3600 ))
bi=0
while [ "$bi" -lt 21 ]; do
  bf="$U/codex-bound/sessions/rollout-$bi.jsonl"
  if [ "$bi" -eq 0 ]; then
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"window_minutes":300,"resets_at":%s}}}}\n' "$bound_excluded_ts" "$future" > "$bf"
  elif [ "$bi" -eq 20 ]; then
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"window_minutes":300,"resets_at":%s}}}}\n' "$bound_kept_ts" "$future" > "$bf"
  else
    printf '{"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":3,"window_minutes":300,"resets_at":%s}}}}\n' "$future" > "$bf"
  fi
  touch -d "@$((bound_base + bi * 60))" "$bf"
  bi=$((bi + 1))
done
out=$(CODEX_HOME="$U/codex-bound" PATH="$U/bin:$PATH" bash "$USAGE_SH")
expect_bound=$(jq -nr --arg t "$bound_kept_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
lose_bound=$(jq -nr --arg t "$bound_excluded_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
case "$out" in *"codex 5h 12% resets "*" as-of ${expect_bound}"*) ;; *) fail "usage.sh keeps Codex candidates to the 20 newest files (want 12% as-of ${expect_bound}): $out" ;; esac
case "$out" in *"codex 5h 99%"*|*"as-of ${lose_bound}"*) fail "usage.sh read a rate_limits event outside the 20 newest files: $out" ;; esac

# No .timestamp: the newer file mtime wins, and as-of is that mtime (still inside 8 days).
mkdir -p "$U/codex-mtime/sessions"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":77,"window_minutes":300,"resets_at":%s}}}}\n' "$future" > "$U/codex-mtime/sessions/rollout-old.jsonl"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":33,"window_minutes":300,"resets_at":%s}}}}\n' "$future" > "$U/codex-mtime/sessions/rollout-new.jsonl"
mtime_now=$(date +%s)
touch -d "@$((mtime_now - 2 * 86400))" "$U/codex-mtime/sessions/rollout-old.jsonl"
touch -d "@$((mtime_now - 86400))" "$U/codex-mtime/sessions/rollout-new.jsonl"
out=$(CODEX_HOME="$U/codex-mtime" PATH="$U/bin:$PATH" bash "$USAGE_SH")
mt_new=$(date -r "$U/codex-mtime/sessions/rollout-new.jsonl" +%s)
expect_mt=$(jq -nr --argjson t "$mt_new" '$t | strftime("%Y-%m-%dT%H:%MZ")')
case "$out" in *"codex 5h 33% resets "*" as-of ${expect_mt}"*) ;; *) fail "usage.sh falls back to file mtime when the event has no timestamp (want 33% as-of ${expect_mt}): $out" ;; esac
case "$out" in *"codex 5h 77%"*) fail "usage.sh let an older untimestamped rollout win: $out" ;; esac

# agy: local /usage JSON, one window per quota pool; unknown buckets skipped; fractional-second resets parse.
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S; }
cat > "$U/bin/agy" <<STUB
#!/usr/bin/env bash
[ "\$1" = "-p=/usage" ] || exit 9
printf '%s' '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","remaining_fraction":0.97,"reset_time":"$(iso "$future")Z"},{"id":"gemini-5h","remaining_fraction":0.84,"reset_time":"$(iso "$future").250Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-5h","remaining_fraction":0.5,"reset_time":"$(iso "$future")Z"},{"id":"3p-weekly","remaining_fraction":0.91,"reset_time":"$(iso "$future")Z"}]},{"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","remaining_fraction":0.99,"reset_time":"$(iso "$future")Z"},{"id":"mystery-bucket","remaining_fraction":0.2,"reset_time":"$(iso "$future")Z"}]}]}}}'
STUB
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH")
case "$out" in *"agy 7d_flash 3% resets"*) ;; *) fail "usage.sh reads the agy Gemini weekly bucket: $out" ;; esac
case "$out" in *"agy 5h_flash 16% resets"*) ;; *) fail "usage.sh parses a fractional-second agy reset: $out" ;; esac
case "$out" in *"agy 5h_claude 50% resets"*) ;; *) fail "usage.sh reads the agy Claude 5h bucket: $out" ;; esac
case "$out" in *"agy 7d_claude 9% resets"*) ;; *) fail "usage.sh reads the agy Claude weekly bucket: $out" ;; esac
case "$out" in *"agy 7d_argon 1% resets"*) ;; *) fail "usage.sh reads the agy Argon weekly bucket: $out" ;; esac
[ "$(printf '%s\n' "$out" | grep -c '^agy ')" -eq 5 ] || fail "usage.sh skips an unknown agy bucket id: $out"
case "$out" in *"80%"*|*mystery*|*"agy 5h "*|*"agy 7d "*) fail "usage.sh emits only per-pool agy windows: $out" ;; esac
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/agy"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH")
case "$out" in *"agy unknown (/usage returned no known quota buckets)"*) ;; *) fail "usage.sh reports a failed agy probe as unknown: $out" ;; esac

# #718: Muse allowance comes from a run stream, not the CLI session store.
# emit zeroes a window whose reset has passed, so the same parsed percent is asserted either way.
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
muse_allowance='{"tier":"Muse Code Power Usage","weekly":{"resets_at_ms":1794787200000,"used_percent":99},"window":{"resets_at_ms":1794764145000,"used_percent":6},"as_of_ms":1794700800000,"source":"mint"}'
muse_reason='API error 429 […]: Subscription quota exhausted. Your usage window resets at 2026-11-16T00:00:00Z. (rate_limit_error)'
jq -cn --argjson allowance "$muse_allowance" --arg reason "$muse_reason" \
  '{payload_type:"run.usage",payload:{allowance:$allowance}},{payload_type:"run.terminal.failed",payload:{terminal:"failed",reason:$reason,text:""}}' \
  > "$U/muse-issue.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-issue.jsonl" --muse-log "$U/missing-muse.jsonl")
expect_muse_line "$out" 7d 99 1794787200 '2026-11-15T00:00Z' 'usage.sh Muse weekly line from the issue allowance'
expect_muse_line "$out" 5h 6 1794764145 '2026-11-15T00:00Z' 'usage.sh Muse window line from the issue allowance'
jq -cn --argjson as_of 1794600000000 '{payload_type:"run.usage",payload:{allowance:{weekly:{resets_at_ms:1794787200000,used_percent:11},window:{resets_at_ms:1794764145000,used_percent:1},as_of_ms:$as_of}}}' > "$U/muse-old.jsonl"
jq -cn --argjson as_of 1794730000000 '{payload_type:"run.usage",payload:{allowance:{weekly:{resets_at_ms:1794787200000,used_percent:42},window:{resets_at_ms:1794764145000,used_percent:3},as_of_ms:$as_of}}}' > "$U/muse-new.jsonl"
touch -d "@$(( $(date +%s) - 86400 ))" "$U/muse-new.jsonl"
touch "$U/muse-old.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-old.jsonl" --muse-log "$U/muse-new.jsonl")
expect_muse_asof=$(jq -nr '1794730000 | strftime("%Y-%m-%dT%H:%MZ")')
expect_muse_line "$out" 7d 42 1794787200 "$expect_muse_asof" "usage.sh keeps the Muse allowance with the newest as_of_ms (want 42% as-of ${expect_muse_asof})"
case "$out" in *"muse 7d 11%"*) fail "usage.sh let an older Muse as_of_ms win: $out" ;; esac
jq -cn '{payload_type:"run.usage",payload:{allowance:{weekly:{used_percent:"n/a",resets_at_ms:1794787200000},window:{used_percent:6,resets_at_ms:1794764145000},as_of_ms:1794700800000}}}' > "$U/muse-partial.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-partial.jsonl")
case "$out" in *"muse 7d"*) fail "usage.sh should drop a Muse weekly bucket with a non-numeric used value: $out" ;; esac
expect_muse_line "$out" 5h 6 1794764145 '*' 'usage.sh keeps a valid Muse window beside a dropped weekly bucket'
jq -cn '{payload_type:"run.usage",payload:{allowance:{weekly:{used_percent:99,resets_at_ms:1794787200000},as_of_ms:1794700800000}}}' > "$U/muse-nowindow.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-nowindow.jsonl")
case "$out" in *"muse 5h"*) fail "usage.sh should omit a missing Muse window bucket: $out" ;; esac
expect_muse_line "$out" 7d 99 1794787200 '2026-11-15T00:00Z' 'usage.sh keeps a valid Muse weekly bucket when window is missing'
printf '%s\n' '{"payload_type":"run.usage","payload":{"allowance":{"weekly":{"used_percent":"x","resets_at_ms":"soon"},"window":{"used_percent":null,"resets_at_ms":1},"as_of_ms":"yesterday"}}}' > "$U/muse-bad.jsonl"
set +e
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-bad.jsonl")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "usage.sh exits 0 on a malformed Muse allowance (got $rc): $out"
case "$out" in *"muse unknown (no stream log with run.usage; pass --muse-log)"*) ;; *) fail "a Muse allowance with no numeric bucket is unknown: $out" ;; esac
case "$out" in *"muse 7d"*|*"muse 5h "*) fail "a malformed Muse allowance emitted a window: $out" ;; esac
jq -cn '{payload_type:"run.usage",payload:{allowance:{weekly:{used_percent:17,resets_at_ms:1794787200000}}}}' > "$U/muse-noasof.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-noasof.jsonl")
case "$out" in *"muse unknown (no stream log with run.usage; pass --muse-log)"*) ;; *) fail "a Muse allowance without numeric as_of_ms is unknown: $out" ;; esac

contains "$META_SKILL" 'references/usage-limits.md' 'Meta skill routes with usage headroom'
contains "$META_REFS/usage-limits.md" 'get_usage' 'Usage limits prefer the desktop get_usage tool'
contains "$META_REFS/handoff-template.md" '- Usage:' 'Handoff records the usage snapshot'
pass 'usage.sh reports plan-limit windows per provider'

# --- plan limits are 75 with failure=limit, not task failures or transient retries ---
for msg in 'You have hit your usage limit' 'RESOURCE_EXHAUSTED: quota exceeded' 'Resource exhausted' \
  'API error (status 402 Payment Required): Grok Build usage balance exhausted'; do
  printf '%s\n' "$msg" > "$WORK/plan-limit.txt"
  [ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = limit ] || fail "plan limit '$msg' classifies as limit"
done
printf '429 Too Many Requests\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = transient ] || fail 'a 429 stays transient'
pass 'Plan-limit errors classify as limit; rate limits stay transient'
printf '    at run (file:///x/cli.js:503:12)\n' > "$WORK/plan-limit.txt"
[ -z "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" ] || fail 'a stack-frame position is not a 503'
printf 'API Error: 503\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = transient ] || fail 'a real 503 stays transient'
printf 'at x.js:429:7\nIndividual quota reached\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = limit ] || fail 'a stack-frame 429 does not mask a quota limit'
printf '401 Unauthorized\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = auth ] || fail 'a 401 stays auth'
pass 'Failure classification ignores stack-frame positions'

# --- mmo_tree_state sees tracked, untracked-content, and HEAD changes; ignores the --out prefix ---
TS="$WORK/tree-state"; mkdir -p "$TS"
git -C "$TS" init -q
printf 'a\n' > "$TS/a.txt"; git -C "$TS" add a.txt; git -C "$TS" -c user.email=t@t -c user.name=t commit -qm a
s0="$(mmo_tree_state "$TS")"
printf 'u1\n' > "$TS/u.txt"; s1="$(mmo_tree_state "$TS")"
[ "$s1" != "$s0" ] || fail 'tree state sees a new untracked file'
printf 'u2\n' > "$TS/u.txt"; [ "$(mmo_tree_state "$TS")" != "$s1" ] || fail 'tree state sees untracked content change'
rm "$TS/u.txt"; [ "$(mmo_tree_state "$TS")" = "$s0" ] || fail 'tree state is stable for an unchanged tree'
printf 'x\n' > "$TS/out.txt"; printf 'x\n' > "$TS/out.txt.stream"
[ "$(mmo_tree_state "$TS" "$TS/out.txt")" = "$(mmo_tree_state "$TS" "$TS/out.txt")" ] || fail 'tree state is deterministic'
rm "$TS/out.txt" "$TS/out.txt.stream"
before="$(mmo_tree_state "$TS" "$TS/out.txt")"
printf 'x\n' > "$TS/out.txt"; printf 'x\n' > "$TS/out.txt.stream"
[ "$(mmo_tree_state "$TS" "$TS/out.txt")" = "$before" ] || fail 'tree state ignores the --out file and its siblings'
printf 'b\n' > "$TS/a.txt"; [ "$(mmo_tree_state "$TS" "$TS/out.txt")" != "$before" ] || fail 'tree state sees a tracked edit'
# The --out exclusion is exact: a source file sharing the --out prefix still counts.
printf 'r\n' > "$TS/result.py"; git -C "$TS" add result.py; git -C "$TS" -c user.email=t@t -c user.name=t commit -qm r
before="$(mmo_tree_state "$TS" "$TS/result")"
printf 'x\n' > "$TS/result"; printf 'x\n' > "$TS/result.exit"; printf 'x\n' > "$TS/result.stream.stderr"
[ "$(mmo_tree_state "$TS" "$TS/result")" = "$before" ] || fail 'tree state ignores --out, .exit, and .stream.stderr'
printf 'r2\n' > "$TS/result.py"
[ "$(mmo_tree_state "$TS" "$TS/result")" != "$before" ] || fail 'tree state sees an edit to a file that shares the --out prefix'
# A repository with no commits: a staged rewrite still counts.
TN="$WORK/tree-nohead"; mkdir -p "$TN"; git -C "$TN" init -q
printf 'one\n' > "$TN/n.txt"; git -C "$TN" add n.txt
before="$(mmo_tree_state "$TN")"
printf 'two\n' > "$TN/n.txt"; git -C "$TN" add n.txt
[ "$(mmo_tree_state "$TN")" != "$before" ] || fail 'tree state sees a staged rewrite in a repository without HEAD'
# Several OUT paths: each leg file and its siblings are ignored, anything else counts.
before="$(mmo_tree_state "$TS" "$TS/o1" "$TS/o2")"
printf 'x\n' > "$TS/o1"; printf 'x\n' > "$TS/o1.stream"; printf 'x\n' > "$TS/o2"; printf 'x\n' > "$TS/o2.exit"
[ "$(mmo_tree_state "$TS" "$TS/o1" "$TS/o2")" = "$before" ] || fail 'tree state ignores every OUT path and its siblings'
printf 'x\n' > "$TS/o3"
[ "$(mmo_tree_state "$TS" "$TS/o1" "$TS/o2")" != "$before" ] || fail 'tree state sees a file that is none of the OUT paths'
rm "$TS/o3"
pass 'mmo_tree_state detects repository writes and ignores leg artifacts'

# --- codex/claude: a non-implement leg that changes the repository exits 7; leg files and review diff ---
# The usage tests above put hermetic provider stubs first on PATH; these runs need the leg stubs.
leg_old_path="$PATH"; PATH="$WORK/bin:$PATH"
LR="$WORK/leg-repo"; mkdir -p "$LR"; git -C "$LR" init -q
printf 'one\n' > "$LR/f.txt"; git -C "$LR" add f.txt; git -C "$LR" -c user.email=t@t -c user.name=t commit -qm base
printf 'two\n' > "$LR/f.txt"
LR2="$WORK/leg-repo-clean"; mkdir -p "$LR2"; git -C "$LR2" init -q
printf 'one\n' > "$LR2/f.txt"; git -C "$LR2" add f.txt; git -C "$LR2" -c user.email=t@t -c user.name=t commit -qm base
for r in claude codex; do
  prompt="$WORK/$r.prompt"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r clean review exits 0 (got $rc)"
  case "$r" in claude) leg_modes='review advise research' ;; *) leg_modes='review research' ;; esac
  for mode in $leg_modes; do
    base_args=(); [ "$mode" != review ] || base_args=(--base HEAD)
    for mut in "printf changed >> '$LR/f.txt'" "printf fresh > '$LR/new.txt'"; do
      rc=0; printf x | STUB_MUTATE="$mut" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode "$mode" --repo "$LR" "${base_args[@]}" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
      printf 'two\n' > "$LR/f.txt"; rm -f "$LR/new.txt"
      [ "$rc" -eq 7 ] || fail "$r $mode leg that changed the repo exits 7 for '$mut' (got $rc)"
      exact_line "$WORK/$r-leg.err" "run-$r: the $mode leg changed $LR; inspect git status before trusting it" "$r $mode names the changed repository"
    done
  done
  rc=0; printf x | STUB_MUTATE="printf changed >> '$LR/f.txt'" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode implement --repo "$LR" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  printf 'two\n' > "$LR/f.txt"
  [ "$rc" -eq 0 ] || fail "$r implement may change the repository (got $rc)"
  # --out (and its siblings) inside the repo are not repository changes
  rm -f "$LR"/leg.out*
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --out "$LR/leg.out" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r review with --out inside the repo exits 0 (got $rc): $(cat "$WORK/$r-leg.err")"
  # leg files of an earlier attempt are not under review; a genuinely new file is
  printf 'LEG_MARKER\n' > "$LR/leg.out"; printf 'LEG_MARKER\n' > "$LR/leg.out.stream"; printf 'LEG_MARKER\n' > "$LR/leg.out.exit"
  printf 'brand-new-body\n' > "$LR/new.txt"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --out "$LR/leg.out" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r review with earlier leg files exits 0 (got $rc)"
  contains "$prompt" 'brand-new-body' "$r review diff carries a new untracked file"
  absent "$prompt" 'LEG_MARKER' "$r review diff leaves out the leg's own --out, .stream and .exit"
  rm -f "$LR"/leg.out* "$LR/new.txt"
  # only leg files untracked and nothing tracked changed: nothing to review
  printf 'LEG_MARKER\n' > "$LR2/leg.out"; printf 'LEG_MARKER\n' > "$LR2/leg.out.stream"; printf 'LEG_MARKER\n' > "$LR2/leg.out.exit"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR2" --base HEAD --out "$LR2/leg.out" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "$r review with only leg files untracked exits 3 (got $rc)"
  contains "$WORK/$r-leg.err" 'no diff to review' "$r names the empty review"
  rm -f "$LR2"/leg.out*
done
printf 'x\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$LR" --model claude-fable-5-2 --timeout 10 >/dev/null 2>"$WORK/claude-fable52.err" \
  || fail "claude accepts --model claude-fable-5-2: $(cat "$WORK/claude-fable52.err")"
exact_line "$WORK/claude.args" 'claude-fable-5-2' 'claude-fable-5-2 reaches the CLI'
# A failed codex rerun must not leave the previous round's verdict in --out.
printf 'APPROVE\n' > "$LR/stale.out"
rc=0; printf x | STUB_CODEX_RESULT=fake_metadata "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --repo "$LR" --base HEAD --out "$LR/stale.out" --timeout 10 >/dev/null 2>"$WORK/codex-stale.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'a failing codex review exits non-zero'
[ ! -e "$LR/stale.out" ] || fail 'a failed codex rerun removes the previous --out'
rc=0; bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg codex="$LR/stale.out" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "review-gate rejects the removed --out with exit 2 (got $rc)"
# A rerun that stops in preflight (nothing to review) must not leave the earlier verdict either.
for r in claude codex grok; do
  printf 'APPROVE\n' > "$LR2/stale.out"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR2" --base HEAD --out "$LR2/stale.out" --timeout 10 >/dev/null 2>"$WORK/$r-stale.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "$r review of a clean tree exits 3 (got $rc)"
  [ ! -e "$LR2/stale.out" ] || fail "$r preflight failure removes the previous --out"
done
# A symlinked --out inside the repo keeps pointing at its report and is not a repository change.
for r in claude codex; do
  printf 'APPROVE\n' > "$WORK/ext-report.txt"; ln -s "$WORK/ext-report.txt" "$LR/link.out"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --out "$LR/link.out" --timeout 10 >/dev/null 2>"$WORK/$r-link.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r review with a symlinked --out exits 0 (got $rc): $(cat "$WORK/$r-link.err")"
  [ -L "$LR/link.out" ] || fail "$r keeps the --out symlink"
  [ -s "$WORK/ext-report.txt" ] || fail "$r writes the report through the --out symlink"
  rm -f "$LR"/link.out* "$WORK/ext-report.txt"
done
# Grok resolves --out before writing: the symlink as given is still a leg output, not a change.
ln -s "$WORK/ext-grok.txt" "$LR2/link.out"
rc=0; printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$LR2" --base HEAD --out "$LR2/link.out" --timeout 10 >/dev/null 2>"$WORK/grok-link.err" || rc=$?
[ "$rc" -eq 3 ] || fail "grok review of a clean tree with a symlinked --out exits 3 (got $rc): $(cat "$WORK/grok-link.err")"
rm -f "$LR2"/link.out* "$WORK/ext-grok.txt"
# A tracked --out is a leg output too: it stays out of the tracked part of the review diff.
LR3="$WORK/leg-repo-tracked"; mkdir -p "$LR3"; git -C "$LR3" init -q
printf 'one\n' > "$LR3/f.txt"; printf 'TRACKED_MARKER\n' > "$LR3/leg.out"
git -C "$LR3" add f.txt leg.out; git -C "$LR3" -c user.email=t@t -c user.name=t commit -qm base
printf 'two\n' > "$LR3/f.txt"
rc=0; printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --repo "$LR3" --base HEAD --out "$LR3/leg.out" --timeout 10 >/dev/null 2>"$WORK/codex-tracked.err" || rc=$?
[ "$rc" -eq 0 ] || fail "codex review with a tracked --out exits 0 (got $rc): $(cat "$WORK/codex-tracked.err")"
contains "$WORK/codex.prompt" '+two' 'codex review diff carries the tracked change'
absent "$WORK/codex.prompt" 'TRACKED_MARKER' 'codex review diff leaves out a tracked --out'
# A custom --stream-log inside the repo is a leg output: an earlier run's stream is not under review.
printf 'GROK_STREAM_MARKER\n' > "$LR/custom.stream"
rc=0; printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$LR" --base HEAD --out "$WORK/grok-leg.out" --stream-log "$LR/custom.stream" --timeout 10 >/dev/null 2>"$WORK/grok-leg.err" || rc=$?
[ "$rc" -eq 0 ] || fail "grok review with an in-repo --stream-log exits 0 (got $rc): $(cat "$WORK/grok-leg.err")"
absent "$WORK/grok.prompt" 'GROK_STREAM_MARKER' 'grok review diff leaves out its --stream-log'
rm -f "$LR"/custom.stream*
PATH="$leg_old_path"
pass 'codex/claude: a non-implement leg that changes the repo exits 7; leg files stay out of the review diff; fable-5-2 accepted'

# --- run-agy.sh against a stub agy ---
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

out="$(printf 'make f say two\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --repo "$AR" --timeout 30 2>"$AG/err")" || fail "run-agy implement succeeds: $(cat "$AG/err")"
contains "$AG/calls/call.0.args" '--dangerously-skip-permissions' 'agy implement runs YOLO'
exact_line "$AG/calls/call.0.args" 'gemini-3.8-flash-medium' 'agy encodes the effort in the model id'
exact_line "$AG/calls/call.0.cwd" "$AR" 'agy implement runs in the repository'
[ "$(jq -r '.event' "$AG/calls/call.0.stdin")" = user ] || fail 'agy prompt arrives as a stream-json user event'
jq -r '.message.content' "$AG/calls/call.0.stdin" | grep -qF 'make f say two' || fail 'agy prompt carries the task packet'
case "$out" in *done*) ;; *) fail "run-agy prints the final response: $out" ;; esac
contains "$AG/err" 'run-agy: exit=0' 'run-agy reports its exit line'

printf 'two\n' > "$AR/f.txt"
out="$(printf 'review it\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode review --repo "$AR" --base HEAD --effort low --timeout 30 2>"$AG/err")" || fail "run-agy review succeeds: $(cat "$AG/err")"
absent "$AG/calls/call.1.args" '--dangerously-skip-permissions' 'agy review is not YOLO'
[ "$(cat "$AG/calls/call.1.cwd")" != "$AR" ] || fail 'agy review runs outside the repository'
jq -r '.message.content' "$AG/calls/call.1.stdin" | grep -qF '+two' || fail 'agy review is handed the diff'
case "$out" in *APPROVE*) ;; *) fail "run-agy review prints the verdict: $out" ;; esac

rc=0; printf 'review it\n' | "${agy_env[@]}" STUB_AGY_TOUCH="$AR/f.txt" bash "$AGY_RUN" --mode review --repo "$AR" --base HEAD --timeout 30 >/dev/null 2>"$AG/err" || rc=$?
[ "$rc" -eq 7 ] || fail "a review leg that wrote to the repo exits 7 (got $rc)"
printf 'two\n' > "$AR/f.txt"
rc=0; printf 'x\n' | "${agy_env[@]}" STUB_AGY_RESPONSE='looks fine' bash "$AGY_RUN" --mode review --repo "$AR" --base HEAD --timeout 30 >/dev/null 2>"$AG/err" || rc=$?
[ "$rc" -eq 6 ] || fail "an agy review without a verdict exits 6 (got $rc)"
rc=0; printf 'x\n' | "${agy_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-medium bash "$AGY_RUN" --mode implement --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" || rc=$?
[ "$rc" -eq 75 ] || fail "an agy quota error exits 75 (got $rc)"
contains "$AG/err" 'failure=limit' 'agy quota error is reported as a plan limit'
for bad in '--mode review' '--mode implement --base HEAD' '--mode implement --effort xhigh' '--mode implement --model gemini-3.1-pro' '--mode review --base --output=x'; do
  rc=0
  # shellcheck disable=SC2086
  printf 'x\n' | "${agy_env[@]}" bash "$AGY_RUN" $bad --repo "$AR" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "run-agy rejects '$bad' as usage (got $rc)"
done
git -C "$AR" checkout -q -- f.txt
pass 'run-agy: YOLO implement, diff-only review outside the repo, write detection, exits'
out="$(printf 'x\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --repo "$AR" --out /dev/stdout --timeout 30 2>"$AG/err")" || fail "run-agy --out /dev/stdout exits 0: $(cat "$AG/err")"
case "$out" in *done*) ;; *) fail "run-agy --out /dev/stdout puts the body on stdout: $out" ;; esac
pass 'run-agy: --out /dev/stdout exits 0 with the body on stdout'

for level in low medium high; do
  argon_n="$(find "$AG/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
  printf 'bounded task\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model gemini-4-argon --effort "$level" --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" \
    || fail "run-agy accepts Argon at $level: $(cat "$AG/err")"
  exact_line "$AG/calls/call.${argon_n}.args" "gemini-4-argon-$level" 'Argon model and selected effort reach the CLI'
done
rc=0; printf 'x\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model gemini-4-argon --effort xhigh --repo "$AR" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "Argon rejects unsupported xhigh effort (got $rc)"
pass 'run-agy: Argon forwards each supported effort and rejects unsupported effort'
hydrogen_n="$(find "$AG/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'bounded task\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model gemini-4-hydrogen --effort high --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" \
  || fail "run-agy accepts Hydrogen: $(cat "$AG/err")"
exact_line "$AG/calls/call.${hydrogen_n}.args" 'gemini-4-hydrogen-high' 'Hydrogen model and effort reach the CLI'
pass 'run-agy: Hydrogen is an accepted model'
carbon_n="$(find "$AG/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'bounded task\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model gemini-4-carbon --effort high --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" \
  || fail "run-agy accepts Carbon: $(cat "$AG/err")"
exact_line "$AG/calls/call.${carbon_n}.args" 'gemini-4-carbon-high' 'Carbon model and effort reach the CLI'
pass 'run-agy: Carbon is an accepted model'

for claude_model in claude-opus-5-5 claude-sonnet-5-5; do
  claude_n="$(find "$AG/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
  printf 'bounded task\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model "$claude_model" --effort high --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" \
    || fail "run-agy accepts $claude_model: $(cat "$AG/err")"
  exact_line "$AG/calls/call.${claude_n}.args" "$claude_model-high" "agy receives $claude_model with the effort suffix"
done
rc=0; printf 'x\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model no-such-model --repo "$AR" >/dev/null 2>"$AG/err" || rc=$?
[ "$rc" -eq 2 ] || fail "run-agy rejects an unknown model (got $rc)"
contains "$AG/err" 'claude-opus-5-5' 'the catalog error lists the agy Claude models'
pass 'run-agy: Claude models reach agy with the effort suffix; unknown models exit 2'

missing_argon='invalid model selection (--model "gemini-4-argon-high" --effort ""): model gemini-4-argon-high is not recognized as a known model or custom model in settings'
for failure in "$missing_argon" 'unexpected task execution failure'; do
  rc=0; printf 'x\n' | "${agy_env[@]}" STUB_AGY_FAIL_MODEL=gemini-4-argon STUB_AGY_FAIL_MESSAGE="$failure" bash "$AGY_RUN" --mode implement --model gemini-4-argon --repo "$AR" >/dev/null 2>"$AG/err" || rc=$?
  expected_rc=1; [ "$failure" != "$missing_argon" ] || expected_rc=75
  [ "$rc" -eq "$expected_rc" ] || fail "agy distinguishes unavailable model from task failure (got $rc, expected $expected_rc)"
done
printf 'two\n' > "$AR/f.txt"
rc=0; printf 'x\n' | "${agy_env[@]}" STUB_AGY_FAIL_MODEL=gemini-4-argon STUB_AGY_FAIL_MESSAGE="$missing_argon" STUB_AGY_TOUCH="$AR/f.txt" bash "$AGY_RUN" --mode review --base HEAD --model gemini-4-argon --repo "$AR" >/dev/null 2>"$AG/err" || rc=$?
[ "$rc" -eq 7 ] || fail "unavailable model never hides a review write (got $rc)"
git -C "$AR" checkout -q -- f.txt
pass 'run-agy: unavailable model allows fallback without hiding task failures or writes'

# #698: provider exit 3 must be classified; the runner's clean-review exit stays 3.
for failure in 'Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 4h32m11s.' 'generic task failure' '401 Unauthorized'; do
  expected_rc=1; expected_failure=''
  case "$failure" in Individual*) expected_rc=75; expected_failure=limit ;; 401*) expected_rc=77; expected_failure=auth ;; esac
  rc=0
  printf 'x\n' | "${agy_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-medium STUB_AGY_EXIT=3 STUB_AGY_FAIL_MESSAGE="$failure" \
    bash "$AGY_RUN" --mode implement --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" || rc=$?
  [ "$rc" -eq "$expected_rc" ] || fail "agy exit 3 with '$failure': got $rc, expected $expected_rc"
  contains "$AG/err" "run-agy: exit=$expected_rc" 'agy reports the classified exit'
  if [ -n "$expected_failure" ]; then
    contains "$AG/err" "failure=$expected_failure" 'agy reports the failure class'
  else
    absent "$AG/err" 'failure=' 'agy generic failure has no provider class'
  fi
  pass "#698: agy exit 3 classified as $expected_rc ${expected_failure:-generic}"
done
git -C "$AR" checkout -q -- f.txt
rc=0
printf 'review\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode review --base HEAD --repo "$AR" >/dev/null 2>"$AG/err" || rc=$?
[ "$rc" -eq 3 ] || fail "agy clean review still exits 3 (got $rc)"
contains "$AG/err" 'no diff to review' 'agy exit 3 comes from the runner'
pass '#698: agy runner-originated nothing-to-review exit stays 3'
printf 'two\n' > "$AR/f.txt"

# --- run-muse.sh against a stub muse ---
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

out="$(printf 'make f say two\n' | "${muse_env[@]}" bash "$MUSE_RUN" --mode implement --repo "$MR" --timeout 30 2>"$MU/err")" || fail "run-muse implement succeeds: $(cat "$MU/err")"
for flag in exec --json --yolo medium --disable-web-tools --no-foreign-personal-context --disable-reminders; do
  exact_line "$MU/calls/call.0.args" "$flag" "muse implement passes $flag"
done
absent "$MU/calls/call.0.args" '--disable-write' 'muse implement keeps write tools'
exact_line "$MU/calls/call.0.args" '--model' 'unset MMO_MUSE_MODEL passes --model'
exact_line "$MU/calls/call.0.args" 'muse-spark-1.3' 'unset MMO_MUSE_MODEL requests muse-spark-1.3'
exact_line "$MU/calls/call.0.cwd" "$MR" 'muse implement runs in the repository'
contains "$MU/calls/call.0.prompt" 'make f say two' 'muse prompt carries the task packet'
case "$out" in *done*) ;; *) fail "run-muse prints the final response: $out" ;; esac
contains "$MU/err" 'run-muse: exit=0' 'run-muse reports its exit line'

printf 'two\n' > "$MR/f.txt"
out="$(printf 'review it\n' | "${muse_env[@]}" bash "$MUSE_RUN" --mode review --repo "$MR" --base HEAD --effort low --timeout 30 2>"$MU/err")" || fail "run-muse review succeeds: $(cat "$MU/err")"
for flag in --disable-write --disable-shell --disable-web-tools; do
  exact_line "$MU/calls/call.1.args" "$flag" "muse review passes $flag"
done
contains "$MU/calls/call.1.prompt" '+two' 'muse review is handed the diff'
case "$out" in *APPROVE*) ;; *) fail "run-muse review prints the verdict: $out" ;; esac

printf 'what is new\n' | "${muse_env[@]}" bash "$MUSE_RUN" --mode research --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || fail "run-muse research succeeds: $(cat "$MU/err")"
absent "$MU/calls/call.2.args" '--disable-web-tools' 'muse research keeps web tools'
exact_line "$MU/calls/call.2.args" '--disable-write' 'muse research drops write tools'
[ "$(cat "$MU/calls/call.2.cwd")" != "$MR" ] || fail 'muse research runs outside the repository'
contains "$MU/calls/call.2.prompt" 'sources OUTSIDE this repository' 'muse research prompt carries the external-source contract'

rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_TOUCH="$MR/f.txt" bash "$MUSE_RUN" --mode advise --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 7 ] || fail "an advise leg that wrote to the repo exits 7 (got $rc)"
printf 'two\n' > "$MR/f.txt"
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_SERVED=muse-spark-1.3-contributor bash "$MUSE_RUN" --mode implement --model muse-spark-1.3 --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 7 ] || fail "a pinned leg served by another model exits 7 (got $rc)"
contains "$MU/err" 'not the requested muse-spark-1.3' 'run-muse names the model it was served'
printf 'x\n' | "${muse_env[@]}" STUB_MUSE_SERVED=none bash "$MUSE_RUN" --mode implement --model muse-spark-1.3 --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" \
  || fail "a configured event without model_id is not a model mismatch: $(cat "$MU/err")"
default_n="$(find "$MU/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'x\n' | "${muse_env[@]}" STUB_MUSE_SERVED=muse-spark-1.3-contributor bash "$MUSE_RUN" --mode implement --model default --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" \
  || fail "run-muse --model default accepts the CLI-selected model: $(cat "$MU/err")"
absent "$MU/calls/call.${default_n}.args" '--model' '--model default passes no --model'
wonder_n="$(find "$MU/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'x\n' | "${muse_env[@]}" STUB_MUSE_SERVED=muse-wonder-full-1.0 bash "$MUSE_RUN" --mode implement --model muse-wonder-full-1.0 --effort high --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" \
  || fail "run-muse accepts an explicit muse-wonder-full-1.0 pin: $(cat "$MU/err")"
exact_line "$MU/calls/call.${wonder_n}.args" '--model' 'muse-wonder-full-1.0 is passed to the Muse CLI'
exact_line "$MU/calls/call.${wonder_n}.args" 'muse-wonder-full-1.0' 'muse-wonder-full-1.0 reaches the Muse CLI model argument'
exact_line "$MU/calls/call.${wonder_n}.args" 'high' 'muse-wonder-full-1.0 pin keeps the requested high effort'
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_SERVED=muse-spark-1.3 bash "$MUSE_RUN" --mode implement --model muse-wonder-full-1.0 --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 7 ] || fail "a muse-wonder-full-1.0 pin served as another model exits 7 (got $rc)"
contains "$MU/err" 'not the requested muse-wonder-full-1.0' 'run-muse names the wonder model it was not served'
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_RESPONSE='looks fine' bash "$MUSE_RUN" --mode review --repo "$MR" --base HEAD --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 6 ] || fail "a muse review without a verdict exits 6 (got $rc)"
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_FAIL='429 Too Many Requests' bash "$MUSE_RUN" --mode implement --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 75 ] || fail "a muse rate limit exits 75 (got $rc)"
line="$(grep '^run-muse: ' "$MU/err" || true)"
case "$line" in *'resets='*) fail "a muse 429 without a reset timestamp adds no resets= field: ${line:-missing}" ;; esac
muse_reason='API error 429 […]: Subscription quota exhausted. Your usage window resets at 2026-11-16T00:00:00Z. (rate_limit_error)'
muse_allowance='{"tier":"Muse Code Power Usage","weekly":{"resets_at_ms":1794787200000,"used_percent":99},"window":{"resets_at_ms":1794764145000,"used_percent":6},"as_of_ms":1794700800000,"source":"mint"}'
rc=0
printf 'x\n' | "${muse_env[@]}" STUB_MUSE_SERVED=muse-wonder-full-1.0 STUB_MUSE_FAIL="$muse_reason" STUB_MUSE_USAGE="$muse_allowance" \
  bash "$MUSE_RUN" --mode implement --model muse-wonder-full-1.0 --effort high --repo "$MR" --timeout 30 --out "$MU/limit.out" >/dev/null 2>"$MU/limit.err" || rc=$?
[ "$rc" -eq 75 ] || fail "muse quota exhaustion exits 75 (got $rc): $(cat "$MU/limit.err")"
line="$(grep '^run-muse: ' "$MU/limit.err" || true)"
case "$line" in
  *"exit=75 failure=limit"*"resets=2026-11-16T00:00Z"*) ;;
  *) fail "muse limit exit line carries resets=2026-11-16T00:00Z: ${line:-missing}" ;;
esac
contains "$MU/limit.out.stream" '"run.usage"' 'the quota fixture stream keeps the run.usage event'
out=$(CODEX_HOME="$U/none" PATH="$U/bin:/usr/bin:/bin" bash "$USAGE_SH" --muse-log "$MU/limit.out.stream")
expect_muse_line "$out" 7d 99 1794787200 '*' "the runner stream's allowance is Muse weekly 99%"
expect_muse_line "$out" 5h 6 1794764145 '*' "the runner stream's allowance is Muse window 6%"
rc=0
printf 'x\n' | "${muse_env[@]}" STUB_MUSE_FAIL='Subscription quota exhausted' \
  bash "$MUSE_RUN" --mode implement --repo "$MR" --timeout 30 >/dev/null 2>"$MU/limit-plain.err" || rc=$?
[ "$rc" -eq 75 ] || fail "muse quota without a reset time exits 75 (got $rc)"
line="$(grep '^run-muse: ' "$MU/limit-plain.err" || true)"
case "$line" in
  *"failure=limit"*) ;;
  *) fail "muse quota without a reset time is still a limit: ${line:-missing}" ;;
esac
case "$line" in *'resets='*) fail "muse quota without a reset time adds no resets= field: $line" ;; esac
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_FAIL='missing meta credentials: run `muse login` or set META_API_KEY' bash "$MUSE_RUN" --mode implement --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 77 ] || fail "missing muse credentials exit 77 (got $rc)"
# step cap: a failed terminal whose reason is the step-cap message maps by mode; other failures stay 1
step_reason='model did not reach a terminal state within 50 step(s)'
for mode_rc in implement:76 review:78 advise:78; do
  mode="${mode_rc%%:*}"; want="${mode_rc##*:}"; margs=(); [ "$mode" != review ] || margs=(--base HEAD)
  rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_FAIL="$step_reason" bash "$MUSE_RUN" --mode "$mode" --repo "$MR" "${margs[@]}" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "muse $mode step cap exits $want (got $rc)"
  contains "$MU/err" 'step cap reached' "muse $mode step cap is named"
done
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_FAIL='boom' bash "$MUSE_RUN" --mode implement --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 1 ] || fail "a muse failure other than the step cap still exits 1 (got $rc)"
pass 'run-muse: step cap exits 76 for implement and 78 for review/advise; other failures stay 1'

# --mode probe: shell kept, writes disabled, verdict and unchanged repository enforced
muse_f="$(cat "$MR/f.txt")"
probe_n="$(find "$MU/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
rc=0; printf 'probe it\n' | "${muse_env[@]}" bash "$MUSE_RUN" --mode probe --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 0 ] || fail "muse probe with APPROVE exits 0 (got $rc): $(cat "$MU/err")"
exact_line "$MU/calls/call.${probe_n}.args" '--disable-write' 'muse probe drops write tools'
absent "$MU/calls/call.${probe_n}.args" '--disable-shell' 'muse probe keeps the shell'
contains "$MU/calls/call.${probe_n}.prompt" 'verifies by execution' 'muse probe prompt carries the execute-probe contract'
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_RESPONSE='looks fine' bash "$MUSE_RUN" --mode probe --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 6 ] || fail "a muse probe without a verdict exits 6 (got $rc)"
contains "$MU/err" 'probe completed without APPROVE or NEEDS_WORK' 'muse probe names the missing verdict'
rc=0; printf 'x\n' | "${muse_env[@]}" STUB_MUSE_TOUCH="$MR/f.txt" bash "$MUSE_RUN" --mode probe --repo "$MR" --timeout 30 >/dev/null 2>"$MU/err" || rc=$?
printf '%s\n' "$muse_f" > "$MR/f.txt"
[ "$rc" -eq 7 ] || fail "a muse probe that wrote to the repo exits 7 (got $rc)"
rc=0; printf 'x\n' | "${muse_env[@]}" bash "$MUSE_RUN" --mode bogus --repo "$MR" >/dev/null 2>"$MU/err" || rc=$?
[ "$rc" -eq 2 ] || fail "run-muse unknown mode exits 2 (got $rc)"
contains "$MU/err" 'probe' 'run-muse unknown-mode error lists probe'
pass 'run-muse --mode probe: write tools off, shell on, verdict and unchanged repo enforced'
for bad in '--mode review --base --output=x' '--mode implement --effort ultra' '--mode implement --model gpt-6-sol' '--mode implement --max-steps 0' '--mode bogus'; do
  rc=0
  # shellcheck disable=SC2086
  printf 'x\n' | "${muse_env[@]}" bash "$MUSE_RUN" $bad --repo "$MR" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "run-muse rejects '$bad' as usage (got $rc)"
done
git -C "$MR" checkout -q -- f.txt
printf 'two\n' > "$MR/f.txt"
printf x | "${muse_env[@]}" bash "$MUSE_RUN" --mode review --repo "$MR" --base HEAD --out /dev/stdout --timeout 30 2> "$WORK/muse-devout.err" | cat > "$WORK/muse-devout.out"
[ "${PIPESTATUS[1]}" -eq 0 ] || fail 'muse --out /dev/stdout success rc want 0'
[ "$(grep -c 'APPROVE' "$WORK/muse-devout.out")" -eq 1 ] || fail 'muse --out /dev/stdout piped must hold the body exactly once'
rc=0
printf x | "${muse_env[@]}" STUB_MUSE_RESPONSE='looks fine' bash "$MUSE_RUN" --mode review --repo "$MR" --base HEAD --out /dev/stdout --timeout 30 >/dev/null 2> "$WORK/muse-devout-nv.err" || rc=$?
[ "$rc" -eq 6 ] || fail "muse --out /dev/stdout review without verdict rc=$rc want 6"
git -C "$MR" checkout -q -- f.txt
pass '#625: muse --out /dev/stdout: body once, verdict gate intact'
pass 'run-muse: YOLO implement, read-only advise/review, web-only research, default model, pin check, write detection, exits'

# --- run-opencode.sh against a stub opencode ---
OC="$WORK/opencode"; mkdir -p "$OC/bin" "$OC/calls"
OC_RUN="$PLUGIN_ROOT/scripts/run-opencode.sh"
cat > "$OC/bin/opencode" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SECRET_SEEN:-}" ] || printf '%s %s\n' "${0##*/}" "${LEG_SECRET-unset}" >> "$STUB_SECRET_SEEN"
if [ "${1:-}" = --version ]; then printf '%s\n' "${STUB_OPENCODE_VERSION:-opencode v2.2.4}"; exit 0; fi
n=$(find "$STUB_OPENCODE_CALLS" -name 'call.*.args' | wc -l)
printf '%s\n' "$@" > "$STUB_OPENCODE_CALLS/call.$n.args"
pwd > "$STUB_OPENCODE_CALLS/call.$n.cwd"
cat > "$STUB_OPENCODE_CALLS/call.$n.prompt"
[ -z "${STUB_OPENCODE_TOUCH:-}" ] || printf 'touched\n' >> "$STUB_OPENCODE_TOUCH"
if [ -n "${STUB_OPENCODE_ERROR_TYPE:-}" ]; then
  printf '%s\n' '{"type":"step_start","part":{"messageID":"msg_A"}}'
  jq -cn --arg t "$STUB_OPENCODE_ERROR_TYPE" --arg m "${STUB_OPENCODE_ERROR_MESSAGE:-}" --arg s "${STUB_OPENCODE_ERROR_STATUS:-}" \
    '{type:"error",error:({type:$t,message:$m} + (if $s == "" then {} else {status:($s|tonumber)} end))}'
  exit "${STUB_OPENCODE_EXIT:-1}"
fi
printf '%s\n' '{"type":"step_start","part":{"messageID":"msg_A"}}' \
  '{"type":"tool_use","part":{"messageID":"msg_A","tool":"write","state":{"status":"completed"}}}' \
  '{"type":"text","part":{"messageID":"msg_A","type":"text","text":"thinking aloud"}}' \
  '{"type":"step_finish","part":{"messageID":"msg_A","reason":"tool-calls","tokens":{"input":100,"output":10,"reasoning":5,"cache":{"read":1,"write":2}}}}' \
  '{"type":"step_start","part":{"messageID":"msg_B"}}'
[ -z "${STUB_OPENCODE_DRAFT:-}" ] || jq -cn --arg t "$STUB_OPENCODE_DRAFT" '{type:"text",part:{id:"prt_B1",messageID:"msg_B",type:"text",text:$t}}'
jq -cn --arg t "${STUB_OPENCODE_RESPONSE-done

APPROVE}" '{type:"text",part:{id:"prt_B1",messageID:"msg_B",type:"text",text:$t}}'
jq -cn --arg r "${STUB_OPENCODE_FINISH:-stop}" '{type:"step_finish",part:{messageID:"msg_B",reason:$r,tokens:{input:50,output:4,reasoning:1,cache:{read:0,write:0}}}}'
STUB
chmod +x "$OC/bin/opencode"
OR="$OC/repo"; mkdir -p "$OR"; git -C "$OR" init -q
printf 'one\n' > "$OR/f.txt"; git -C "$OR" add f.txt; git -C "$OR" -c user.email=t@t -c user.name=t commit -qm base
oc_env=(env -u MMO_OPENCODE_MODEL -u MMO_OPENCODE_EFFORT PATH="$OC/bin:$PATH" STUB_OPENCODE_CALLS="$OC/calls")

out="$(printf 'make f say two\n' | "${oc_env[@]}" bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30 2>"$OC/err")" || fail "run-opencode implement succeeds: $(cat "$OC/err")"
for flag in run --standalone --format json --auto -m 'opencode-go/glm-5.3#high'; do
  exact_line "$OC/calls/call.0.args" "$flag" "opencode implement passes $flag"
done
absent "$OC/calls/call.0.args" '--agent' 'opencode implement is not the plan agent'
exact_line "$OC/calls/call.0.cwd" "$OR" 'opencode implement runs in the repository'
contains "$OC/calls/call.0.prompt" 'make f say two' 'opencode prompt carries the task packet'
case "$out" in *done*) ;; *) fail "run-opencode prints the final message: $out" ;; esac
case "$out" in *thinking*) fail "run-opencode prints only the last step: $out" ;; esac
contains "$OC/err" 'run-opencode: exit=0' 'run-opencode reports its exit line'

printf 'x\n' | "${oc_env[@]}" bash "$OC_RUN" --mode implement --repo "$OR" --effort default --model glm-5.3-flash --timeout 30 >/dev/null 2>"$OC/err" \
  || fail "run-opencode accepts --effort default: $(cat "$OC/err")"
exact_line "$OC/calls/call.1.args" 'opencode-go/glm-5.3-flash' '--effort default passes the bare model'
absent "$OC/calls/call.1.args" '#' '--effort default adds no variant'

printf 'two\n' > "$OR/f.txt"
out="$(printf 'review it\n' | "${oc_env[@]}" bash "$OC_RUN" --mode review --repo "$OR" --base HEAD --timeout 30 2>"$OC/err")" || fail "run-opencode review succeeds: $(cat "$OC/err")"
exact_line "$OC/calls/call.2.args" 'plan' 'opencode review uses the plan agent'
absent "$OC/calls/call.2.args" '--auto' 'opencode review does not auto-approve'
[ "$(cat "$OC/calls/call.2.cwd")" != "$OR" ] || fail 'opencode review runs outside the repository'
contains "$OC/calls/call.2.prompt" '+two' 'opencode review is handed the diff'
case "$out" in *APPROVE*) ;; *) fail "run-opencode review prints the verdict: $out" ;; esac

oc_rc() { local want="$1"; shift; local r=0; printf 'x\n' | "${oc_env[@]}" "$@" >/dev/null 2>"$OC/err" || r=$?; [ "$r" -eq "$want" ] || fail "run-opencode want $want got $r: $*"; }
oc_rc 6 STUB_OPENCODE_RESPONSE='looks fine' bash "$OC_RUN" --mode review --repo "$OR" --base HEAD --timeout 30
oc_rc 7 STUB_OPENCODE_TOUCH="$OR/f.txt" bash "$OC_RUN" --mode review --repo "$OR" --base HEAD --timeout 30
printf 'two\n' > "$OR/f.txt"
oc_rc 5 STUB_OPENCODE_RESPONSE='' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
r=0; printf 'x\n' | "${oc_env[@]}" STUB_OPENCODE_FINISH=length bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30 >/dev/null 2>"$OC/err" || r=$?
[ "$r" -ne 0 ] && [ "$r" -ne 5 ] || fail "finish reason length must fail (got $r)"
contains "$OC/err" 'finish reason length' 'run-opencode names the finish reason'
oc_rc 77 STUB_OPENCODE_ERROR_TYPE=provider.auth STUB_OPENCODE_ERROR_STATUS=401 STUB_OPENCODE_ERROR_MESSAGE='Upstream request failed: Invalid credential' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
contains "$OC/err" 'failure=auth' 'opencode auth error is classified as auth'
oc_rc 75 STUB_OPENCODE_ERROR_TYPE=provider.go-limit STUB_OPENCODE_ERROR_MESSAGE='OpenCode Go rolling usage limit reached. Switch to a free model, or turn on Extra Usage on the Go page in OpenCode Console to keep going.' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
contains "$OC/err" 'failure=limit' 'opencode Go limit is classified as a plan limit'
oc_rc 75 STUB_OPENCODE_EXIT=3 STUB_OPENCODE_ERROR_TYPE=provider.go-limit STUB_OPENCODE_ERROR_MESSAGE='OpenCode Go rolling usage limit reached.' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
contains "$OC/err" 'exit=75 failure=limit' 'opencode provider exit 3 cannot bypass Go limit classification'
pass 'run-opencode: provider exit 3 with Go limit becomes 75 failure=limit'

oc_rc 75 STUB_OPENCODE_ERROR_TYPE=provider.no-route STUB_OPENCODE_ERROR_MESSAGE='Model unavailable: opencode-go/x' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
contains "$OC/err" 'not routable here' 'opencode no-route names the cause'
oc_rc 75 STUB_OPENCODE_ERROR_TYPE=provider.no-route STUB_OPENCODE_ERROR_STATUS=401 STUB_OPENCODE_ERROR_MESSAGE='Model unavailable: opencode-go/glm-5.3#medium' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
out="$(printf 'x\n' | "${oc_env[@]}" STUB_OPENCODE_DRAFT='partial draft' bash "$OC_RUN" --mode review --repo "$OR" --base HEAD --timeout 30 2>/dev/null)" \
  || fail 'run-opencode review with a re-emitted text part succeeds'
case "$out" in *'partial draft'*) fail "a re-emitted text part keeps only its last text: $out" ;; esac
oc_rc 75 STUB_OPENCODE_ERROR_TYPE=provider.rate-limit STUB_OPENCODE_ERROR_STATUS=429 STUB_OPENCODE_ERROR_MESSAGE='Rate limit exceeded' bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
oc_n="$(find "$OC/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
oc_rc 127 STUB_OPENCODE_VERSION=1.19.5 bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30
contains "$OC/err" 'needs OpenCode v2' 'run-opencode refuses v1'
[ "$(find "$OC/calls" -name 'call.*.args' | wc -l | tr -d ' ')" = "$oc_n" ] || fail 'opencode v1 never reaches run'
for bad in '--mode advise' '--mode implement --effort HIGH' '--mode implement --model Bad/Id' '--mode review' '--mode implement --base HEAD'; do
  r=0
  # shellcheck disable=SC2086
  printf 'x\n' | "${oc_env[@]}" bash "$OC_RUN" $bad --repo "$OR" >/dev/null 2>&1 || r=$?
  [ "$r" -eq 2 ] || fail "run-opencode rejects '$bad' as usage (got $r)"
done
printf 'x' | "${oc_env[@]}" bash "$OC_RUN" --mode review --repo "$OR" --base HEAD --out /dev/stdout --timeout 30 2>"$WORK/oc-devout.err" | cat > "$WORK/oc-devout.out"
[ "${PIPESTATUS[1]}" -eq 0 ] || fail 'opencode --out /dev/stdout success rc want 0'
[ "$(grep -c 'APPROVE' "$WORK/oc-devout.out")" -eq 1 ] || fail 'opencode --out /dev/stdout piped must hold the body exactly once'
git -C "$OR" checkout -q -- f.txt
printf 'x\n' | "${oc_env[@]}" MMO_OUTCOMES_FILE="$OC/outcomes.tsv" bash "$OC_RUN" --mode implement --repo "$OR" --timeout 30 >/dev/null 2>&1 \
  || fail 'run-opencode records an outcome'
awk -F '\t' 'NR == 2 {exit !($5 == "opencode" && $11 == 173)} END {if (NR != 2) exit 1}' "$OC/outcomes.tsv" || fail "opencode outcome row has provider and summed tokens: $(cat "$OC/outcomes.tsv")"
pass 'run-opencode: --auto implement, plan-agent review outside the repo, variants, write detection, error mapping, v1 refusal, exits'

# --- run-vibe.sh against a stub vibe (stream and export shapes of vibe 3.1.3) ---
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

out="$(printf 'make f say two\n' | "${vibe_env[@]}" bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30 2>"$VB/err")" || fail "run-vibe implement succeeds: $(cat "$VB/err")"
for flag in --prompt-file --output streaming --trust --auto-approve --max-turns 50 --max-price 0 --output-dir; do
  exact_line "$VB/calls/call.0.args" "$flag" "vibe implement passes $flag"
done
for flag in --enabled-tools --model --thinking; do
  absent "$VB/calls/call.0.args" "$flag" "vibe implement passes no $flag by default"
done
exact_line "$VB/calls/call.0.cwd" "$VR" 'vibe implement runs in the repository'
contains "$VB/calls/call.0.prompt" 'make f say two' 'vibe prompt carries the task packet'
case "$out" in *done*) ;; *) fail "run-vibe prints the final message: $out" ;; esac
case "$out" in *thinking*|*private*) fail "run-vibe prints only the last assistant message: $out" ;; esac
contains "$VB/err" 'run-vibe: exit=0 model=mistral-large-4-0 effort=default mode=implement' 'run-vibe reports its exit line with the served model'

printf 'x\n' | "${vibe_env[@]}" bash "$VIBE_RUN" --mode implement --model mistral-medium-3.5 --effort high --max-turns 7 --repo "$VR" --timeout 30 >/dev/null 2>"$VB/err" \
  || fail "run-vibe accepts a model alias and effort: $(cat "$VB/err")"
for flag in --model mistral-medium-3.5 --thinking high 7 --max-price 0; do
  exact_line "$VB/calls/call.1.args" "$flag" "vibe pin passes $flag"
done

printf 'two\n' > "$VR/f.txt"
out="$(printf 'review it\n' | "${vibe_env[@]}" bash "$VIBE_RUN" --mode review --repo "$VR" --base HEAD --timeout 30 2>"$VB/err")" || fail "run-vibe review succeeds: $(cat "$VB/err")"
exact_line "$VB/calls/call.2.args" '--enabled-tools' 'vibe review restricts tools'
exact_line "$VB/calls/call.2.args" '--max-price' 'vibe review passes --max-price'
exact_line "$VB/calls/call.2.args" '0' 'vibe review caps price at 0'
exact_line "$VB/calls/call.2.args" 'read_file' 'vibe review enables read_file only'
[ "$(grep -c -- '--enabled-tools' "$VB/calls/call.2.args")" -eq 1 ] || fail 'vibe review enables exactly one tool'
absent "$VB/calls/call.2.args" '--auto-approve' 'vibe review does not auto-approve'
absent "$VB/calls/call.2.args" '--trust' 'vibe review does not trust the folder'
exact_line "$VB/calls/call.2.cwd" "$VR" 'vibe review runs in the repository'
contains "$VB/calls/call.2.prompt" '+two' 'vibe review is handed the diff'
case "$out" in *APPROVE*) ;; *) fail "run-vibe review prints the verdict: $out" ;; esac
printf 'x\n' | "${vibe_env[@]}" STUB_VIBE_RESPONSE='file map' bash "$VIBE_RUN" --mode advise --repo "$VR" --timeout 30 >/dev/null 2>"$VB/err" \
  || fail "run-vibe advise succeeds without a verdict: $(cat "$VB/err")"
exact_line "$VB/calls/call.3.args" 'read_file' 'vibe advise enables read_file only'
exact_line "$VB/calls/call.3.args" '--max-price' 'vibe advise passes --max-price'
exact_line "$VB/calls/call.3.args" '0' 'vibe advise caps price at 0'
absent "$VB/calls/call.3.args" '--auto-approve' 'vibe advise does not auto-approve'

vibe_rc() { local want="$1"; shift; local r=0; printf 'x\n' | "${vibe_env[@]}" "$@" >"$VB/out" 2>"$VB/err" || r=$?; [ "$r" -eq "$want" ] || fail "run-vibe want $want got $r: $* -- $(cat "$VB/err")"; }
# Mistral Large 4 (also the default model) answers off/xhigh/max with an API 400 (mistral-vibe#1439).
for vibe_bad in "--model mistral-large-4-0 --effort max" "--model mistral-large-4-0 --effort off" "--model mistral-large-4 --effort xhigh"; do
  # shellcheck disable=SC2086
  vibe_rc 2 bash "$VIBE_RUN" --mode implement $vibe_bad --repo "$VR" --timeout 30
  contains "$VB/err" 'is rejected by Mistral Large 4' "vibe names the Large 4 effort rejection: $vibe_bad"
done
vibe_rc 0 bash "$VIBE_RUN" --mode implement --model mistral-medium-3.5 --effort max --repo "$VR" --timeout 30
# default passes no --model: the configured model decides, so the level passes through.
vibe_rc 0 bash "$VIBE_RUN" --mode implement --effort off --repo "$VR" --timeout 30
vibe_rc 6 STUB_VIBE_RESPONSE='looks fine' bash "$VIBE_RUN" --mode review --repo "$VR" --base HEAD --timeout 30
vibe_rc 7 STUB_VIBE_TOUCH="$VR/f.txt" bash "$VIBE_RUN" --mode review --repo "$VR" --base HEAD --timeout 30
git -C "$VR" checkout -q -- f.txt; printf 'two\n' > "$VR/f.txt"
vibe_rc 7 STUB_VIBE_TOUCH="$VR/new.txt" bash "$VIBE_RUN" --mode advise --repo "$VR" --timeout 30
rm -f "$VR/new.txt"
vibe_rc 5 STUB_VIBE_RESPONSE='' bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
vibe_rc 5 STUB_VIBE_RESPONSE='' STUB_VIBE_DISCARDED='APPROVE' bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
# vibe exits 3 for every limit stop; the export's outcome names which one.
vibe_rc 78 STUB_VIBE_EXIT=3 STUB_VIBE_OUTCOME=turn_limit STUB_VIBE_STDERR='Tool call denied: file_system.write_file (Tool execution denied by approval policy)' bash "$VIBE_RUN" --mode review --repo "$VR" --base HEAD --timeout 30
contains "$VB/err" 'turn cap reached (50) in --mode review' 'vibe review turn cap is named'
contains "$VB/err" 'vibe denied 1 tool call(s) in --mode review' 'vibe denied tool calls are counted'
[ ! -s "$VB/out" ] || fail 'a turn-capped vibe leg prints no interim message as its report'
vibe_rc 78 STUB_VIBE_EXIT=3 STUB_VIBE_OUTCOME=turn_limit bash "$VIBE_RUN" --mode advise --repo "$VR" --out "$VB/capped.txt" --timeout 30
[ ! -s "$VB/capped.txt" ] || fail 'a turn-capped vibe leg leaves no interim message at --out'
vibe_rc 76 STUB_VIBE_EXIT=3 STUB_VIBE_OUTCOME=turn_limit bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'work may be partial' 'vibe implement turn cap says the work may be partial'
vibe_rc 1 STUB_VIBE_EXIT=3 STUB_VIBE_OUTCOME=token_limit bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'vibe failed (outcome: token_limit)' 'vibe names another limit stop'
vibe_rc 75 STUB_VIBE_EXIT=3 STUB_VIBE_OUTCOME=price_limit bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'run-vibe: stopped at max-price 0 (plan budget spent; paid usage refused)' 'vibe price limit names the refused paid spill'
contains "$VB/err" 'exit=75 failure=limit' 'vibe price limit is quota-exhausted'
[ ! -s "$VB/out" ] || fail 'a price-limited vibe leg prints no success body'
printf 'x\n' | "${vibe_env[@]}" MMO_VIBE_MAX_PRICE=9 bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30 >/dev/null 2>"$VB/err" \
  || fail "run-vibe ignores an env attempt to raise max-price: $(cat "$VB/err")"
price_call="$(find "$VB/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
price_call=$((price_call - 1))
exact_line "$VB/calls/call.${price_call}.args" '--max-price' 'an env var cannot drop --max-price'
[ "$(grep -Fx -A1 -- '--max-price' "$VB/calls/call.${price_call}.args" | sed -n 2p)" = '0' ] \
  || fail 'an env var cannot raise the price cap'
! grep -Fx -- '9' "$VB/calls/call.${price_call}.args" >/dev/null \
  || fail 'an env var is not forwarded as a price'
vibe_rc 77 STUB_VIBE_EXIT=1 STUB_VIBE_OUTCOME=config_error STUB_VIBE_ERROR='Missing MISTRAL_API_KEY environment variable for mistral provider' bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'no Mistral API key in this home' 'vibe missing key is named'
vibe_rc 77 STUB_VIBE_EXIT=1 STUB_VIBE_OUTCOME=infrastructure_failure STUB_VIBE_ERROR='API error 401 Unauthorized' bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'exit=77 failure=auth' 'vibe 401 is classified as auth'
vibe_rc 75 STUB_VIBE_EXIT=1 STUB_VIBE_OUTCOME=infrastructure_failure STUB_VIBE_ERROR='API error 429: rate limit exceeded' bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'exit=75 failure=transient' 'vibe 429 is classified as transient'
vibe_rc 1 STUB_VIBE_EXIT=1 STUB_VIBE_OUTCOME=usage_error STUB_VIBE_ERROR='Unknown model: nope. Available: mistral-large-4-0' bash "$VIBE_RUN" --mode implement --model nope --repo "$VR" --timeout 30
contains "$VB/err" 'Unknown model: nope' 'vibe unknown alias is named'
vibe_rc 1 STUB_VIBE_OUTCOME=terminated bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'without a finished run export' 'vibe exit 0 without a finished export is a failure'
vibe_rc 124 STUB_VIBE_SLEEP=5 bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 1
vibe_n="$(find "$VB/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
vibe_rc 127 STUB_VIBE_VERSION='vibe 2.9.4' bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30
contains "$VB/err" 'needs Mistral Vibe 3' 'run-vibe refuses vibe 2'
[ "$(find "$VB/calls" -name 'call.*.args' | wc -l | tr -d ' ')" = "$vibe_n" ] || fail 'vibe 2 never reaches a run'
for bad in '--mode probe' '--mode implement --effort ultra' '--mode implement --model Bad/Id' '--mode implement --max-turns 0' '--mode implement --max-price 1' '--mode review --base --output=x'; do
  r=0
  # shellcheck disable=SC2086
  printf 'x\n' | "${vibe_env[@]}" bash "$VIBE_RUN" $bad --repo "$VR" >/dev/null 2>&1 || r=$?
  [ "$r" -eq 2 ] || fail "run-vibe rejects '$bad' as usage (got $r)"
done
printf 'x' | "${vibe_env[@]}" bash "$VIBE_RUN" --mode review --repo "$VR" --base HEAD --out /dev/stdout --timeout 30 2>"$WORK/vibe-devout.err" | cat > "$WORK/vibe-devout.out"
[ "${PIPESTATUS[1]}" -eq 0 ] || fail 'vibe --out /dev/stdout success rc want 0'
[ "$(grep -c 'APPROVE' "$WORK/vibe-devout.out")" -eq 1 ] || fail 'vibe --out /dev/stdout piped must hold the body exactly once'
printf 'x\n' | "${vibe_env[@]}" bash "$VIBE_RUN" --mode review --repo "$VR" --base HEAD --out "$VR/review.txt" --timeout 30 >/dev/null 2>"$VB/err" \
  || fail "run-vibe review with --out inside the repository is not a repository write: $(cat "$VB/err")"
[ -s "$VR/review.txt.stream" ] || fail 'run-vibe keeps the event stream beside --out'
rm -f "$VR/review.txt" "$VR/review.txt.stream"
git -C "$VR" checkout -q -- f.txt
printf 'x\n' | "${vibe_env[@]}" MMO_OUTCOMES_FILE="$VB/outcomes.tsv" bash "$VIBE_RUN" --mode implement --repo "$VR" --timeout 30 >/dev/null 2>&1 \
  || fail 'run-vibe records an outcome'
awk -F '\t' 'NR == 2 {exit !($5 == "vibe" && $6 == "default" && $7 == "mistral-large-4-0" && $11 == 173)} END {if (NR != 2) exit 1}' "$VB/outcomes.tsv" || fail "vibe outcome row has provider, served model and tokens: $(cat "$VB/outcomes.tsv")"
pass 'run-vibe: auto-approve implement, read_file-only untrusted advise/review, default model, write detection, turn cap, error mapping, vibe 2 refusal, exits'

# --- secret isolation (#589): untracked .env* refusal and a scrubbed leg environment ---
SE="$WORK/secret-env"; mkdir -p "$SE"; git -C "$SE" init -q
printf '.env*\n' > "$SE/.gitignore"; printf 'x\n' > "$SE/f.txt"
git -C "$SE" add .gitignore f.txt; git -C "$SE" -c user.email=t@t -c user.name=t commit -qm base
printf 'TOKEN=1\n' > "$SE/.env.local"
seen="$WORK/secret-seen"; : > "$seen"
se_env=(env PATH="$WORK/bin:$AG/bin:$MU/bin:$OC/bin:$VB/bin:$PATH" STUB_AGY_CALLS="$AG/calls" STUB_MUSE_CALLS="$MU/calls" STUB_OPENCODE_CALLS="$OC/calls" STUB_VIBE_CALLS="$VB/calls" STUB_SECRET_SEEN="$seen" LEG_SECRET=leak)
for runner in claude codex grok agy muse opencode vibe; do
  rc=0; printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-$runner.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>"$WORK/secret.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "run-$runner refuses a repo holding an untracked .env file (got $rc)"
  contains "$WORK/secret.err" '.env.local' "run-$runner names the env file it refused"
done
rc=0; printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-agy.sh" --mode review --base HEAD --repo "$SE" --timeout 30 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "run-agy review refuses too, since its diff inlines untracked files (got $rc)"
rc=0; printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-muse.sh" --mode research --repo "$SE" --timeout 30 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "run-muse research refuses too, since it keeps read tools (got $rc)"
[ ! -s "$seen" ] || fail 'a refused leg never starts its provider CLI'
printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-claude.sh" --mode research --repo "$SE" --timeout 30 >/dev/null 2>"$WORK/secret.err" \
  || fail "a research leg has no repository access and is not refused: $(cat "$WORK/secret.err")"
printf 'x\n' | "${se_env[@]}" MMO_ALLOW_ENV_FILES=1 bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>&1 \
  || fail 'MMO_ALLOW_ENV_FILES=1 opts out of the refusal'
rm "$SE/.env.local"; : > "$seen"
for runner in claude codex grok agy muse opencode vibe; do
  printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-$runner.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>"$WORK/secret.err" \
    || fail "run-$runner runs in a repo without env files: $(cat "$WORK/secret.err")"
  exact_line "$seen" "$runner unset" "run-$runner scrubs an unlisted variable from the leg environment"
done
: > "$seen"
printf 'x\n' | "${se_env[@]}" MMO_LEG_ENV='STUB_* LEG_SECRET' bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>&1 \
  || fail 'run-codex runs with MMO_LEG_ENV additions'
exact_line "$seen" 'codex leak' 'MMO_LEG_ENV passes a listed variable through'
rc=0; MMO_LEG_ENV='BAD-NAME' mmo_leg_env -- true 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "an invalid MMO_LEG_ENV name is rejected (got $rc)"
pass 'Legs refuse untracked .env files and run with a scrubbed environment'

# --- pool.sh: pick filters and orders; run falls through unavailable workers ---
POOL="$PLUGIN_ROOT/scripts/pool.sh"
PL="$WORK/pool"; mkdir -p "$PL/bin" "$PL/calls"
for cli in claude codex grok; do printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/$cli"; chmod +x "$PL/bin/$cli"; done
cp "$AG/bin/agy" "$PL/bin/agy"
cat > "$PL/tiers.tsv" <<'TSV'
# test table
T1	qwen	default	n/a
T1	agy	gemini-3.8-flash	low
T2	claude	claude-sonnet-5	medium
T2	agy	gemini-3.8-flash	low
T2	agy	gemini-3.8-flash	high
T2	codex	gpt-5.6-terra	medium
T3	codex	gpt-6-astra	high
T3	claude	claude-opus-5-5	high
TSV
far=$(( $(date +%s) + 86400 )); soon=$(( $(date +%s) + 60 ))
utc_min() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ; }
printf 'codex 7d 98%% resets %s in 1d as-of x\nclaude 7d_opus 95%% resets %s in 1d as-of x\nclaude 5h 95%% resets %s in 1m as-of x\ngrok unknown (none)\n' \
  "$(utc_min "$far")" "$(utc_min "$far")" "$(utc_min "$soon")" > "$PL/usage.txt"
mkdir -p "$PL/home"
# HOME and PATH hide any real local-Qwen wrapper, so the qwen row answers 75 (no wrapper).
pool_env=(env -u MMO_QWEN_LOCAL_RUN HOME="$PL/home" PATH="$PL/bin:/usr/bin:/bin" MMO_POOL_TIERS="$PL/tiers.tsv" STUB_AGY_CALLS="$PL/calls")
pick() { "${pool_env[@]}" bash "$POOL" pick --usage "$PL/usage.txt" "$@"; }

out="$(pick --tier T2 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f2,4 | tr '\t\n' ': ')" = "claude:medium agy:low agy:high " ] || fail "T2 pick keeps table order and skips a tight provider: $out"
contains "$PL/err" 'skip T2 codex/gpt-5.6-terra: plan window >= 90%' 'pick names the tight window it skipped'
rc=0; pick --tier T3 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "T3 with Astra tight and Opus behind 7d_opus exits 75 (got $rc)"
contains "$PL/err" 'skip T3 claude/claude-opus-5-5: plan window' 'a per-model window binds Opus'
contains "$PL/err" "earliest plan reset $(utc_min "$far")" 'no-worker exit names the earliest reset'
absent "$PL/err" 'claude-sonnet-5' 'T3 never falls to a weaker tier'
out="$(pick --tier T2 --deny agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2 | tr '\n' ' ')" = "claude " ] || fail "a short-window 95% that resets before the timeout does not bind; deny removes a provider: $out"
out="$(pick --tier T2 --allow gemini-3.8-flash --prefer agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = agy ] || fail "allow by model keeps only that model: $out"
out="$(pick --tier T2 --prefer agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2,4 | tr '\t\n' ': ')" = "agy:low agy:high claude:medium " ] || fail "prefer moves a provider first, keeping its table order: $out"
out="$(pick --tier T2 --prefer gpt-5.6-terra --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = gpt-5.6-terra ] || fail "an exact model preference leads its tier: $out"
out="$(pick --tier T2 --prefer gpt-6-astra --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f1)" = T2 ] || fail "a preferred model cannot pull a higher tier ahead of the requested tier: $out"
out="$(pick --tier T2 --prefer gpt-5.6-terra --deny codex --usage /dev/null 2>/dev/null)"
case "$out" in *gpt-5.6-terra*) fail 'model preference cannot bypass provider denial' ;; esac
out="$(pick --tier T2 --prefer gpt-5.6-terra 2>/dev/null)"
case "$out" in *gpt-5.6-terra*) fail 'model preference cannot bypass tight usage windows' ;; esac
# A worker bound by several tight windows is usable only after the LATEST of them resets.
two_h=$(( $(date +%s) + 7200 )); three_d=$(( $(date +%s) + 259200 ))
printf 'claude 5h 95%% resets %s in 2h as-of x\nclaude 7d 97%% resets %s in 3d as-of x\n' "$(utc_min "$two_h")" "$(utc_min "$three_d")" > "$PL/usage-multi.txt"
rc=0; pick --tier T2 --allow claude --usage "$PL/usage-multi.txt" >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "two tight Claude windows with only Claude allowed exit 75 (got $rc)"
contains "$PL/err" "skip T2 claude/claude-sonnet-5: plan window >= 90% until $(utc_min "$three_d")" 'skip line shows the latest binding reset'
contains "$PL/err" "earliest plan reset $(utc_min "$three_d")" 'no-worker exit shows the latest binding reset of the only worker'
pass 'pool reports the latest reset among the tight windows binding a worker'
# Use it or lose it: a 7d window <= 60% used that resets within 24h moves that provider first.
half=$(( $(date +%s) + 43200 )); twodays=$(( $(date +%s) + 172800 ))
printf 'codex 7d 40%% resets %s in 12h as-of x\nagy 7d 61%% resets %s\nclaude 7d 10%% resets %s\n' \
  "$(utc_min "$half")" "$(utc_min "$half")" "$(utc_min "$twodays")" > "$PL/spare.txt"
out="$(pick --tier T2 --usage "$PL/spare.txt" 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | grep '^T2' | cut -f2,4 | tr '\t\n' ': ')" = "codex:medium claude:medium agy:low agy:high " ] \
  || fail "a spare 7d window resetting within 24h moves its provider first; >60% or >24h does not: $out"
contains "$PL/err" 'use it or lose it: codex 7d 40% used' 'pick names the spare window'
absent "$PL/err" 'lose it: agy' 'a 61% window is not spare'
absent "$PL/err" 'lose it: claude' 'a window resetting after 24h is not spare'
out="$(pick --tier T2 --usage "$PL/spare.txt" --prefer agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | grep '^T2' | cut -f2,4 | tr '\t\n' ': ')" = "agy:low agy:high codex:medium claude:medium " ] || fail "explicit --prefer stays ahead of a spare provider: $out"
out="$(pick --tier T2 --usage "$PL/spare.txt" --prefer claude-sonnet-5 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = claude-sonnet-5 ] || fail "task-fit model preference stays ahead of spare headroom: $out"
out="$(pick --tier T3 --usage "$PL/spare.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t\n' ': ')" = "T3:codex T3:claude " ] || fail "spare reorders T3 within the tier only: $out"
printf 'claude 7d 30%% resets %s\n' "$(utc_min "$half")" > "$PL/spare.txt"
out="$(pick --tier T3 --usage "$PL/spare.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t\n' ': ')" = "T3:claude T3:codex " ] || fail "a spare provider leads T3 without pulling in a weaker tier: $out"
# Operator-written lines for providers usage.sh cannot read (Grok, Muse) parse like usage.sh's own.
printf 'grok unknown (none)\ngrok 7d 30%% resets %s\n' "$(utc_min "$half")" > "$PL/manual.txt"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --usage "$PL/manual.txt" 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | head -n1 | cut -f2)" = grok ] || fail "an operator-written spare Grok line moves Grok first: $out"
printf 'grok 7d 95%% resets %s\n' "$(utc_min "$far")" > "$PL/manual.txt"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --usage "$PL/manual.txt" 2>"$PL/err")" || true
contains "$PL/err" 'skip T2 grok/grok-4.7: plan window >= 90%' 'an operator-written tight Grok line skips Grok'
out="$(pick --tier T2 --mode review 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f2 | tr '\n' ' ')" = "claude " ] || fail "review skips advisory engines: $out"
contains "$PL/err" 'advisory reviewer' 'pick names the advisory skip'
out="$(pick --tier T1 --deny agy 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f1,2 | head -n1 | tr '\t' ':')" = "T1:qwen" ] || fail "qwen needs no CLI on PATH to be picked: $out"
out="$(pick --tier T1 --deny agy,qwen 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f1 | sort -u)" = T2 ] || fail "an empty T1 escalates to T2: $out"
rm "$PL/bin/claude"
out="$(pick --tier T2 --deny agy 2>"$PL/err")" || true
contains "$PL/err" 'skip T2 claude/claude-sonnet-5: CLI not installed' 'pick skips a provider whose CLI is missing'
printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/claude"; chmod +x "$PL/bin/claude"
for compat in gpt-5.6-luna gpt-6-sol claude-sonnet-5 gpt-6.1-terra gpt-5.6-terra; do
  out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T1 --allow "$compat" --usage /dev/null 2>/dev/null)" || true
  [ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = "$compat" ] || fail "shipped table keeps an allowlisted prior-generation model routable: $compat ($out)"
done
cp "$MU/bin/muse" "$PL/bin/muse"
muse_tight_reset=$(( $(date +%s) + 3 * 86400 ))
jq -cn --argjson reset_ms "$((muse_tight_reset * 1000))" --argjson as_of_ms "$(( $(date +%s) * 1000 ))" \
  '{payload_type:"run.usage",payload:{allowance:{weekly:{resets_at_ms:$reset_ms,used_percent:99},window:{resets_at_ms:$reset_ms,used_percent:6},as_of_ms:$as_of_ms}}}' \
  > "$U/muse-tight.jsonl"
muse_usage=$(CODEX_HOME="$U/none" PATH="$U/bin:/usr/bin:/bin" bash "$USAGE_SH" --muse-log "$U/muse-tight.jsonl")
printf '%s\n' "$muse_usage" > "$PL/muse-usage.txt"
case "$muse_usage" in *"muse 7d 99% resets"*) ;; *) fail "usage.sh emits a tight Muse weekly window for pool: $muse_usage" ;; esac
rc=0
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow muse --usage "$PL/muse-usage.txt" 2>"$PL/err")" || rc=$?
[ "$rc" -eq 75 ] || fail "pool pick skips Muse when its weekly window is at 99% (got $rc): $out"
contains "$PL/err" 'skip T2 muse/muse-spark-1.3: plan window >= 90%' 'pick names the tight Muse weekly window'
contains "$PL/err" 'skip T3 muse/muse-wonder-full-1.0: plan window >= 90%' 'a tight Muse window binds every Muse model'
case "$out" in *muse*) fail "a tight Muse window still listed a Muse row: $out" ;; esac
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --prefer gpt-6-sol --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = gpt-6-sol ] || fail "exact preference distinguishes models within one provider: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow muse --mode review --usage /dev/null 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | head -n1 | cut -f2-4 | tr '\t' ' ')" = "muse muse-spark-1.3 medium" ] || fail "shipped T2 table routes Muse Spark, including review: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --usage /dev/null 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | cut -f2-4 | tr '\t' ' ' | tr '\n' '|')" = "codex gpt-6-astra high|claude claude-opus-5-5 high|agy claude-opus-5-5 high|muse muse-wonder-full-1.0 high|codex gpt-6.1-sol high|agy gemini-4-argon high|agy gemini-4-hydrogen high|agy gemini-4-carbon high|" ] \
  || fail "shipped T3 table keeps Astra and Opus ahead of muse-wonder-full-1.0: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --allow muse-wonder-full-1.0 --usage /dev/null 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | cut -f2-4 | tr '\t' ' ')" = "muse muse-wonder-full-1.0 high" ] || fail "allow muse-wonder-full-1.0 keeps only that T3 worker: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --deny muse-wonder-full-1.0 --usage /dev/null 2>/dev/null)" || true
case "$out" in *muse-wonder-full-1.0*) fail "deny muse-wonder-full-1.0 still listed it: $out" ;; esac
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "gpt-6-astra claude-opus-5-5 claude-opus-5-5 gpt-6.1-sol gemini-4-argon gemini-4-hydrogen gemini-4-carbon " ] || fail "deny muse-wonder-full-1.0 keeps the other T3 workers: $out"
rm -rf "$PL/muse-calls"; mkdir -p "$PL/muse-calls"
printf 'task\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" \
  STUB_MUSE_CALLS="$PL/muse-calls" STUB_MUSE_SERVED=muse-wonder-full-1.0 \
  bash "$POOL" run --tier T3 --allow muse-wonder-full-1.0 --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "pool run dispatches muse-wonder-full-1.0: $(cat "$PL/err")"
exact_line "$PL/muse-calls/call.0.args" '--model' 'pool run passes --model for muse-wonder-full-1.0'
exact_line "$PL/muse-calls/call.0.args" 'muse-wonder-full-1.0' 'pool run sends muse-wonder-full-1.0 to the Muse CLI'
exact_line "$PL/muse-calls/call.0.args" 'high' 'pool run sends the T3 high effort'
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --prefer gemini-4-argon --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3-4 | tr '\t' ' ')" = 'gemini-4-argon high' ] || fail "hard-debugging preference selects Argon high: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --prefer gemini-4-argon --mode review --usage /dev/null 2>/dev/null)"
case "$out" in *gemini-4-argon*) fail 'a stronger agy model cannot bypass advisory-review restrictions' ;; esac
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T4 --prefer gemini-4-argon --usage /dev/null 2>/dev/null)"
case "$out" in *gemini-4-argon*) fail 'task preference cannot lower the high-risk tier floor' ;; esac
printf 'fixture-api-key\n' > "$PL/api-key"
printf 'claude 7d 95%% resets %s\n' "$(utc_min "$far")" > "$PL/claude-usage.txt"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" MMO_CLAUDE_API_KEY_FILE="$PL/api-key" \
  bash "$POOL" pick --tier T4 --usage "$PL/claude-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2-4 | tr '\t' ' ')" = 'codex gpt-6-astra xhigh' ] \
  || fail "T4 with a tight Claude plan and key file keeps only Codex: $out"
pass 'T4 never routes claude-api with a tight Claude plan and key file'
argon_n="$(find "$PL/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'debug a bounded problem\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" \
  bash "$POOL" run --tier T3 --prefer gemini-4-argon --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "pool executes the exact preferred Argon route: $(cat "$PL/err")"
exact_line "$PL/calls/call.${argon_n}.args" 'gemini-4-argon-high' 'pool execution preserves selected model and effort'

# agy quota pools: each per-pool window binds only its own models.
ship() { "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick "$@"; }
printf 'agy 7d_flash 95%% resets %s\n' "$(utc_min "$far")" > "$PL/agy-usage.txt"
out="$(ship --tier T1 --allow agy --usage "$PL/agy-usage.txt" 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "claude-sonnet-5-5 claude-opus-5-5 gemini-4-argon gemini-4-hydrogen gemini-4-carbon " ] || fail "a spent agy Gemini pool skips only Flash: $out"
contains "$PL/err" 'skip T1 agy/gemini-3.8-flash: plan window >= 90%' 'pick names the spent Gemini pool'
printf 'agy 5h_claude 95%% resets %s\n' "$(utc_min "$far")" > "$PL/agy-usage.txt"
out="$(ship --tier T1 --allow agy --usage "$PL/agy-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "gemini-3.8-flash gemini-3.8-flash gemini-4-argon gemini-4-hydrogen gemini-4-carbon " ] || fail "a spent agy Claude 5h pool skips only agy Claude: $out"
printf 'claude 7d 95%% resets %s\n' "$(utc_min "$far")" > "$PL/agy-usage.txt"
out="$(ship --tier T3 --usage "$PL/agy-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2,3 | tr '\t\n' ':|')" = "codex:gpt-6-astra|agy:claude-opus-5-5|muse:muse-wonder-full-1.0|codex:gpt-6.1-sol|agy:gemini-4-argon|agy:gemini-4-hydrogen|agy:gemini-4-carbon|" ] \
  || fail "a spent Claude plan moves Opus to agy in its table position: $out"
out="$(ship --tier T2 --usage "$PL/agy-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f2,3 | tr '\t' ':')" = "agy:claude-sonnet-5-5" ] || fail "a spent Claude plan moves Sonnet to agy first: $out"
printf 'agy 7d_argon 10%% resets %s\n' "$(utc_min "$half")" > "$PL/agy-usage.txt"
out="$(ship --tier T3 --usage "$PL/agy-usage.txt" 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "gemini-4-argon gpt-6-astra claude-opus-5-5 claude-opus-5-5 muse-wonder-full-1.0 gpt-6.1-sol gemini-4-hydrogen gemini-4-carbon " ] \
  || fail "a spare agy Argon pool promotes only Argon: $out"
contains "$PL/err" 'use it or lose it: agy 7d_argon 10% used' 'pick names the spare per-pool window'
out="$(ship --tier T1 --deny claude --usage /dev/null 2>/dev/null)"
case "$out" in *claude*) fail "deny claude removes Claude through every transport: $out" ;; esac
case "$out" in *gemini-3.8-flash*gemini-4-argon*) ;; *) fail "deny claude keeps agy Gemini rows: $out" ;; esac
out="$(ship --tier T1 --allow claude --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = claude ] || fail "allow claude admits no agy transport: $out"
out="$(ship --tier T1 --mode review --usage /dev/null 2>"$PL/err")" || true
case "$out" in *agy*) fail "review still skips every agy row: $out" ;; esac
contains "$PL/err" 'skip T3 agy/claude-opus-5-5: advisory reviewer' 'agy Claude stays an advisory reviewer'

# run: the Claude plan is spent at run time (exit 75), so the same Opus model runs through agy.
mv "$PL/bin/claude" "$PL/claude.ok"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "API Error: 429 rate limit\\n"\nexit 1\n' > "$PL/bin/claude"; chmod +x "$PL/bin/claude"
rm -f "$PL/calls"/*
printf 'task\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" \
  bash "$POOL" run --tier T3 --allow claude,agy --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "a spent Claude plan falls through to agy Opus: $(cat "$PL/err")"
contains "$PL/err" 'pool: claude unavailable (exit 75); next worker' 'the Claude Opus row was tried first'
exact_line "$PL/calls/call.0.args" 'claude-opus-5-5-high' 'agy receives the same Opus model and effort'
contains "$PL/err" 'pool: exit=0 worker=agy model=claude-opus-5-5 effort=high tier=T3' 'pool names the agy Opus worker'
mv "$PL/claude.ok" "$PL/bin/claude"
for bad in '--tier T5' '--tier T2 --mode advise' '--tier T2 --timeout 0' '--tier T2 --bogus'; do
  rc=0
  # shellcheck disable=SC2086
  "${pool_env[@]}" bash "$POOL" pick --usage "$PL/usage.txt" $bad >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "pool rejects '$bad' as usage (got $rc)"
done
rc=0; printf 'x\n' | "${pool_env[@]}" bash "$POOL" run --tier T2 --mode review --usage "$PL/usage.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "pool run --mode review without --base is usage (got $rc)"

# run: the low worker hits a quota (75), the pool moves to the high one; --out inside the repo is fine.
rm -f "$PL/calls"/*
out="$(printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 --out "$AR/leg.out" 2>"$PL/err")" \
  || fail "pool run falls through to the next worker: $(cat "$PL/err")"
exact_line "$PL/calls/call.0.args" 'gemini-3.8-flash-low' 'pool tries the first worker first'
exact_line "$PL/calls/call.1.args" 'gemini-3.8-flash-high' 'pool moves to the next worker on exit 75'
contains "$PL/err" 'pool: agy unavailable (exit 75); next worker' 'pool reports the fall-through'
contains "$PL/err" 'pool: exit=0 worker=agy model=gemini-3.8-flash effort=high tier=T2' 'pool names the worker that ran'
case "$out" in *done*) ;; *) fail "pool passes the worker's body through: $out" ;; esac
rm -f "$AR"/leg.out*

# run: a worker that changed the repo before failing is not replaced.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low STUB_AGY_TOUCH="$AR/f.txt" \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 55 ] || fail "pool exits 55 when the failed leg changed the repo (got $rc)"
[ ! -e "$PL/calls/call.1.args" ] || fail 'pool must not hand a dirtied tree to another worker'
contains "$PL/err" 'after changing the repository' 'pool explains why it stopped'
git -C "$AR" checkout -q -- f.txt

# run: a clean fall-through followed by a leg that edits and fails still exits 55.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash STUB_AGY_TOUCH="$AR/f.txt" \
  STUB_AGY_TOUCH_MODEL=gemini-3.8-flash-high \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ -e "$PL/calls/call.1.args" ] || fail 'the second worker ran after a clean fall-through'
[ "$rc" -eq 55 ] || fail "a dirtying leg after a clean fall-through exits 55 (got $rc)"
git -C "$AR" checkout -q -- f.txt

# run: when every T1 worker is unavailable at run time, the T2 workers are next.
rm -f "$PL/calls"/*
printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low \
  bash "$POOL" run --tier T1 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "a T1 run falls back to T2 workers: $(cat "$PL/err")"
contains "$PL/err" 'pool: qwen unavailable (exit 75); next worker' 'the T1 qwen row was tried first'
contains "$PL/err" 'pool: exit=0 worker=agy model=gemini-3.8-flash effort=high tier=T2' 'a T2 worker ran after T1 was exhausted'

# run: every worker unavailable -> 75 naming the tier.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "pool exits 75 when every worker is unavailable (got $rc)"
contains "$PL/err" 'every T2 worker was unavailable' 'pool names the exhausted tier'

# The shipped table routes nothing to OpenCode, even with its CLI installed.
cp "$OC/bin/opencode" "$PL/bin/opencode"
rc=0; "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T1 --allow opencode --usage /dev/null >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "shipped table has no OpenCode route (got $rc)"
rm -f "$PL/bin/opencode"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/vibe"
chmod +x "$PL/bin/vibe"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow vibe --usage /dev/null 2>"$PL/err")" \
  || fail "pool pick T2 --allow vibe failed: $(cat "$PL/err")"
[ "$(printf '%s\n' "$out" | head -n1)" = $'T2\tvibe\tmistral-large-4\tmedium' ] || fail "T2 pick returns the vibe row when others are excluded: $out"
[ "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = vibe ] || fail "allow vibe keeps only vibe rows: $out"
rc=0
"${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow vibe --mode review --usage /dev/null >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "vibe is not picked for review (got $rc)"
contains "$PL/err" 'advisory reviewer' 'vibe stays an advisory reviewer'
rm -f "$PL/bin/vibe"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow vibe --usage /dev/null 2>"$PL/err")" || true
case "$out" in *vibe*) fail "pick skips vibe when the CLI is missing: $out" ;; esac
contains "$PL/err" 'CLI not installed' 'pick names a missing vibe CLI'
mkdir -p "$PL/vibe-calls"
printf 'task\n' | env -u MMO_VIBE_MODEL -u MMO_VIBE_EFFORT -u MMO_VIBE_MAX_TURNS \
  HOME="$PL/home" PATH="$VB/bin:/usr/bin:/bin" \
  MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" STUB_VIBE_CALLS="$PL/vibe-calls" \
  bash "$POOL" run --tier T2 --allow vibe --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "pool run dispatches vibe: $(cat "$PL/err")"
exact_line "$PL/vibe-calls/call.0.args" '--model' 'pool run passes --model to vibe'
exact_line "$PL/vibe-calls/call.0.args" 'mistral-large-4' 'pool run sends mistral-large-4'
exact_line "$PL/vibe-calls/call.0.args" '--thinking' 'pool run passes effort as --thinking'
exact_line "$PL/vibe-calls/call.0.args" 'medium' 'pool run sends the T2 medium effort'
exact_line "$PL/vibe-calls/call.0.args" '--max-price' 'pool run keeps the hard price cap'
exact_line "$PL/vibe-calls/call.0.args" '0' 'pool run caps price at 0'
pass 'pool.sh: tiers, headroom, allow/deny/prefer, advisory review skip, escalation, fall-through'

# --- leg-check.sh: deterministic scope/verify/no-change checks, one TSV row per check ---
LC="$WORK/leg-check"; LCR="$LC/repo"; mkdir -p "$LCR/src/lib"
LEG_CHECK="$PLUGIN_ROOT/scripts/leg-check.sh"
git -C "$LCR" init -q
printf 'one\n' > "$LCR/f.txt"; printf 'lib\n' > "$LCR/src/lib/a.txt"
git -C "$LCR" add . && git -C "$LCR" -c user.email=t@t -c user.name=t commit -qm base
lc_base="$(git -C "$LCR" rev-parse HEAD)"
lc_rc() {  # lc_rc WANT ARGS... (stderr in $LC/err)
  local want="$1" got=0; shift
  bash "$LEG_CHECK" "$@" >"$LC/out" 2>"$LC/err" || got=$?
  [ "$got" -eq "$want" ] || fail "leg-check want $want got $got: $* -- $(cat "$LC/err")"
}
lc_row() { tail -n 1 "$MMO_LEG_CHECKS_FILE"; }
lc_rc 10 --repo "$LCR" --base "$lc_base"
contains "$LC/err" 'leg-check: exit=10 check=no_change paths=0' 'leg-check reports no_change'
[ "$(head -n 1 "$MMO_LEG_CHECKS_FILE")" = $'utc_time\trepo\ttask\tcycle\ttier\tprovider\tmodel\teffort\tcheck\tdetail\thead_sha\tchanged_paths\tduration_seconds' ] \
  || fail 'leg-check writes the TSV header once'
printf 'two\n' > "$LCR/f.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt' --verify-cmd 'grep -q two f.txt && echo "1 passed"' \
  --verify-pattern '[1-9][0-9]* passed' --task "T	7" --cycle 2 --tier T2 --provider codex --model gpt-5.6-terra --effort medium
exact_line "$LC/err" 'leg-check: exit=0 check=pass paths=1' 'leg-check reports a pass'
awk -F '\t' -v head="$lc_base" 'END {
  if (NF != 13 || $2 != "repo" || $3 != "T 7" || $4 != "2" || $5 != "T2" || $6 != "codex" || $7 != "gpt-5.6-terra" ||
      $8 != "medium" || $9 != "pass" || $10 != "" || $11 != head || $12 != "1" || $13 !~ /^[0-9]+$/) exit 1
}' "$MMO_LEG_CHECKS_FILE" || fail "leg-check row fields: $(lc_row)"
# Committed work counts as changed against the base, too.
git -C "$LCR" -c user.email=t@t -c user.name=t commit -qam leg
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'src/'
contains "$LC/err" 'changed outside --allow-paths: f.txt' 'leg-check names a committed edit outside the allow-list'
[ "$(lc_row | cut -f9,10)" = $'scope\tf.txt' ] || fail "scope row names the first offending path: $(lc_row)"
git -C "$LCR" reset -q --hard "$lc_base"
printf 'new\n' > "$LCR/stray.txt"; printf 'more\n' >> "$LCR/src/lib/a.txt"
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'src/'
contains "$LC/err" 'changed outside --allow-paths: stray.txt' 'leg-check catches an untracked file outside the allow-list'
absent "$LC/err" 'src/lib/a.txt' 'a directory prefix allows nested paths'
lc_rc 0 --repo "$LCR" --base "$lc_base" --allow-paths 'src/,*.txt'
lc_rc 0 --repo "$LCR" --base "$lc_base" --allow-paths 'src/' --out "$LCR/stray.txt"
contains "$LC/err" 'paths=1' 'a leg --out file is not a changed path'
rm -f "$LCR/stray.txt"
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'echo VERIFY_TAIL_MARKER; exit 3'
contains "$LC/err" 'VERIFY_TAIL_MARKER' 'a failed verify prints its output tail'
[ "$(lc_row | cut -f9,10)" = $'verify\tverify-exit=3' ] || fail "verify failure row: $(lc_row)"
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'sleep 30' --verify-timeout 1
[ "$(lc_row | cut -f10)" = verify-timeout ] || fail "verify timeout row: $(lc_row)"
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'echo "0 tests ran"' --verify-pattern '[1-9][0-9]* passed'
[ "$(lc_row | cut -f10)" = verify-pattern ] || fail "verify pattern miss row: $(lc_row)"
printf 'Done.\nWould you like me to add more tests?\n' > "$LC/final.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --final "$LC/final.txt"
contains "$LC/err" 'check=pass paths=1 note=asks-to-continue' 'an ask-to-continue final message is advisory only'
[ "$(lc_row | cut -f9,10)" = $'pass\tasks-to-continue' ] || fail "advisory note row: $(lc_row)"
printf 'Done. Assumed UTC.\n' > "$LC/final.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --final "$LC/final.txt"
absent "$LC/err" 'note=' 'a plain final message adds no note'
rows_before="$(wc -l < "$MMO_LEG_CHECKS_FILE")"
lc_rc 2 --repo "$LCR"
lc_rc 2 --repo "$LCR" --base no-such-ref
lc_rc 2 --repo "$LCR" --base "$lc_base" --verify-pattern x
lc_rc 2 --repo "$LCR" --base "$lc_base" --verify-cmd true --verify-timeout 0
lc_rc 2 --repo "$LCR" --base "$lc_base" --allow-paths ' , '
lc_rc 2 --repo "$LCR" --base "$lc_base" --bogus x
[ "$(wc -l < "$MMO_LEG_CHECKS_FILE")" -eq "$rows_before" ] || fail 'usage errors record no row'
touch "$LC/not-a-dir"
MMO_LEG_CHECKS_FILE="$LC/not-a-dir/leg.tsv" bash "$LEG_CHECK" --repo "$LCR" --base "$lc_base" 2>/dev/null \
  || fail 'leg-check keeps its exit when the record cannot be written'
git -C "$LCR" checkout -q -- src/lib/a.txt
# Baseline: edits that predate the leg are not its work.
printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
bash "$LEG_CHECK" --snapshot "$LC/snap" --repo "$LCR" || fail 'leg-check --snapshot succeeds'
lc_rc 10 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'check=no_change paths=0' 'a no-op leg on a dirty tree is no_change'
printf 'leg\n' >> "$LCR/f.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'check=pass paths=1' 'a pre-existing unrelated edit does not fail scope'
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt'
git -C "$LCR" checkout -q -- src/lib/a.txt
lc_rc 8 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'changed outside --allow-paths: src/lib/a.txt' 'reverting a pre-existing edit is a change'
printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
# A staged out-of-scope change with the working copy restored is still a change.
printf 'staged\n' > "$LCR/staged.txt"; git -C "$LCR" add staged.txt; rm "$LCR/staged.txt"
lc_rc 8 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'changed outside --allow-paths: staged.txt' 'a staged-only change is enumerated'
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt,src/'
contains "$LC/err" 'changed outside --allow-paths: staged.txt' 'a staged-only change is enumerated without a baseline'
git -C "$LCR" rm -q --cached staged.txt
# A verify that rewrites a disallowed tracked file cannot pass.
lc_rc 8 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt' --verify-cmd 'printf x >> src/lib/a.txt'
contains "$LC/err" 'changed outside --allow-paths: src/lib/a.txt' 'scope is re-checked after verify'
[ "$(lc_row | cut -f9,12)" = $'scope\t2' ] || fail "post-verify scope row records the final path count: $(lc_row)"
git -C "$LCR" checkout -q -- src/lib/a.txt; printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
# The verify command runs in the scrubbed leg environment; MMO_LEG_ENV passes a name through.
LEG_SECRET=leak lc_rc 0 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --verify-cmd 'test "${LEG_SECRET-unset}" = unset'
LEG_SECRET=leak MMO_LEG_ENV=LEG_SECRET lc_rc 0 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --verify-cmd 'test "$LEG_SECRET" = leak'
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'exit 124'
[ "$(lc_row | cut -f10)" = verify-exit=124 ] || fail "a fast exit 124 is not a timeout: $(lc_row)"
# A git failure while enumerating is exit 11, never a pass.
mkdir -p "$LC/failgit"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" != "${FAIL_GIT_ON:-diff}" ] || { echo "fatal: injected" >&2; exit 128; }; done\nexec %s "$@"\n' "$(command -v git)" > "$LC/failgit/git"
chmod +x "$LC/failgit/git"
PATH="$LC/failgit:$PATH" lc_rc 11 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt'
contains "$LC/err" 'check=error' 'a failed git diff reports check=error'
[ "$(lc_row | cut -f9)" = error ] || fail "a failed enumeration records an error row: $(lc_row)"
FAIL_GIT_ON=ls-files PATH="$LC/failgit:$PATH" lc_rc 11 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap"
# --validate checks the contract without a repository.
lc_rc 0 --validate --allow-paths 'f.txt,src/' --verify-cmd true --verify-pattern 'ok' --task 1 --cycle 0
lc_rc 2 --validate --verify-cmd true --verify-pattern '['
lc_rc 2 --validate --allow-paths ','
lc_rc 2 --validate --allow-paths $'f.txt\nsrc/'
contains "$LC/err" 'must not contain a newline' 'a newline in --allow-paths is rejected'
git -C "$LCR" checkout -q -- f.txt src/lib/a.txt
pass 'leg-check.sh: pass, scope, verify, no_change, advisory note, rows, usage errors'

# pool.sh run: contract flags run leg-check after a worker exit 0; without them nothing changes.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_TOUCH="$LCR/outside.txt" \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 \
  --allow-paths 'f.txt' --task 9 --cycle 1 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 8 ] || fail "pool run exits 8 when the worker edits outside --allow-paths (got $rc): $(cat "$PL/err")"
contains "$PL/err" 'pool: exit=8 worker=agy model=gemini-3.8-flash effort=low tier=T2 check=scope' 'pool final line carries check=scope'
[ "$(lc_row | cut -f3-9)" = $'9\t1\tT2\tagy\tgemini-3.8-flash\tlow\tscope' ] || fail "pool passes the selected row to leg-check: $(lc_row)"
rows_before="$(wc -l < "$MMO_LEG_CHECKS_FILE")"
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_TOUCH="$LCR/outside.txt" \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 0 ] || fail "pool run without contract flags keeps the worker exit (got $rc)"
tail -n 1 "$PL/err" | grep -Fxq 'pool: exit=0 worker=agy model=gemini-3.8-flash effort=low tier=T2' || fail "pool final line unchanged without contract flags: $(tail -n 1 "$PL/err")"
[ "$(wc -l < "$MMO_LEG_CHECKS_FILE")" -eq "$rows_before" ] || fail 'pool run without contract flags runs no leg check'
rm -f "$LCR/outside.txt"
for bad in "pick --tier T2 --allow-paths f.txt" "run --tier T2 --mode review --base HEAD --verify-cmd true"; do
  rc=0
  # shellcheck disable=SC2086
  printf 'task\n' | "${pool_env[@]}" bash "$POOL" $bad --usage "$PL/usage.txt" --repo "$LCR" >/dev/null 2>"$PL/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "pool rejects contract flags outside run --mode implement: $bad (got $rc)"
  contains "$PL/err" 'apply to run --mode implement only' "pool names the contract-flag restriction: $bad"
done
rm -f "$PL/calls"/*
for bad in "--verify-pattern passed" "--cycle one --allow-paths f.txt" "--allow-paths f.txt --task  " "--allow-paths ," "--verify-cmd true --verify-pattern ["; do
  rc=0
  # shellcheck disable=SC2086
  printf 'task\n' | "${pool_env[@]}" bash "$POOL" run --tier T2 --deny claude $bad --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "pool rejects a malformed contract before dispatch: $bad (got $rc)"
done
[ -z "$(ls -A "$PL/calls" 2>/dev/null)" ] || fail 'a malformed contract must not reach a worker'
# Dirty start: the pool snapshots the tree, so edits made before dispatch are not the leg's.
printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
rc=0; printf 'task\n' | "${pool_env[@]}" bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" \
  --repo "$LCR" --timeout 30 --allow-paths 'f.txt' >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 10 ] || fail "a no-op worker on a dirty tree exits 10 (got $rc): $(cat "$PL/err")"
contains "$PL/err" 'check=no_change' 'pool reports no_change on a dirty start'
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_TOUCH="$LCR/f.txt" bash "$POOL" run --tier T2 --deny claude \
  --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 --allow-paths 'f.txt' >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 0 ] || fail "a pre-existing unrelated edit does not fail the pool's scope check (got $rc): $(cat "$PL/err")"
contains "$PL/err" 'check=pass' 'pool passes a leg on a dirty start'
git -C "$LCR" checkout -q -- f.txt src/lib/a.txt
# Cancelling the pool during a long verify stops the verify instead of waiting for its timeout.
rm -f "$LC/verify.pid"
lc_started=$SECONDS
printf 'task\n' | "${pool_env[@]}" STUB_AGY_TOUCH="$LCR/f.txt" bash "$POOL" run --tier T2 --deny claude \
  --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 --allow-paths 'f.txt' \
  --verify-cmd "echo \$\$ > '$LC/verify.pid'; exec sleep 60" >/dev/null 2>"$PL/err" &
pool_pid=$!
timeout 20 bash -c "until [ -s '$LC/verify.pid' ]; do sleep 0.1; done" || fail 'the pool verify command started'
kill -TERM "$pool_pid"
rc=0; wait "$pool_pid" || rc=$?
[ "$rc" -eq 143 ] || fail "a cancelled pool exits 143 during verify (got $rc): $(cat "$PL/err")"
[ $((SECONDS - lc_started)) -lt 30 ] || fail 'a cancelled pool does not wait for the verify'
! kill -0 "$(cat "$LC/verify.pid")" 2>/dev/null || fail 'cancelling the pool stops the verify command'
git -C "$LCR" checkout -q -- f.txt
pass 'pool.sh run: contract flags gate a worker exit 0 through leg-check'

contains "$PLUGIN_ROOT/skills/route-model-task/SKILL.md" 'pool.sh pick --tier' 'route-model-task picks through the pool'
contains "$PLUGIN_ROOT/skills/route-model-task/SKILL.md" 'never lifts a family exclusion' 'route-model-task keeps a family exclusion when a multi-family runner is allowed'
contains "$PLUGIN_ROOT/skills/route-model-task/references/routing.md" 'pool-tiers.tsv' 'routing names the tier table'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'pool.sh" run --tier' 'orchestrate dispatches through the pool'
contains "$META_SKILL" 'pool.sh run --tier' 'meta loop dispatches implement legs through the pool'
contains "$META_REFS/usage-limits.md" '--usage <file>' 'usage limits feed the pool'
pass 'Pool is wired into route-model-task, orchestrate, and meta-orchestrate'

bash "$PLUGIN_ROOT/tests/claude-api-tests.sh"
# Outcome records use CLI stubs above; collect independent failures to expose every regression.
outcome_passes=0
outcome_failures=0
outcome_check() {
  local label="$1"; shift
  if "$@"; then
    pass "outcomes: $label"
    outcome_passes=$((outcome_passes + 1))
  else
    printf 'FAIL: outcomes: %s\n' "$label" >&2
    outcome_failures=$((outcome_failures + 1))
  fi
}
OUTCOMES="$WORK/outcome-regressions"
mkdir -p "$OUTCOMES/bin"
# Restore the idle endpoint stub after the busy/error endpoint tests.
cat > "$OUTCOMES/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '[{"id":0,"is_processing":false}]' 200
STUB
chmod +x "$OUTCOMES/bin/curl"
outcome_env=(env PATH="$OUTCOMES/bin:$WORK/bin:$AG/bin:$MU/bin:$OC/bin:$PATH" \
  STUB_AGY_CALLS="$AG/calls" STUB_MUSE_CALLS="$MU/calls" STUB_OPENCODE_CALLS="$OC/calls" \
  MMO_QWEN_LOCAL_RUN="$WORK/bin/qwen-wrapper.sh" OPENAI_BASE_URL=http://127.0.0.1:9/v1)
# Worktree basename fallback is deliberately distinct from the parent repository.
outcome_repo="$OUTCOMES/project"
mkdir -p "$outcome_repo"
git -C "$outcome_repo" init -q
printf 'base\n' > "$outcome_repo/app.txt"
git -C "$outcome_repo" add app.txt
git -C "$outcome_repo" -c user.name=t -c user.email=t@t commit -qm base

outcome_row() {
  local file="$1" provider="$2" expected_rc="$3"
  [ -f "$file" ] && awk -F '\t' -v p="$provider" -v rc="$expected_rc" '
    NR == 1 { if (NF != 13 || $1 != "utc_time" || $12 != "head_sha" || $13 != "verdict") exit 1 }
    NR == 2 { if (NF != 13 || $1 !~ /^[0-9][0-9][0-9][0-9]-.*Z$/ || $2 != "project" || $3 != "" || $4 != "implement" || $5 != p || $9 != rc || $10 !~ /^[0-9]+$/) exit 1 }
    END { if (NR != 2) exit 1 }
  ' "$file"
}
for provider in codex claude grok agy muse opencode qwen; do
  runner="run-$provider.sh"
  [ "$provider" != qwen ] || runner=run-qwen-local.sh
  for result in success failure; do
    expected_rc=0
    failure_env=()
    if [ "$result" = failure ]; then
      expected_rc=23
      case "$provider" in
        codex) failure_env=(STUB_CODEX_RESULT=error); expected_rc=1 ;;
        claude) failure_env=(STUB_CLAUDE_RESULT=error); expected_rc=1 ;;
        grok) failure_env=(STUB_GROK_RESULT=error); expected_rc=1 ;;
        agy) failure_env=(STUB_AGY_FAIL_MODEL=gemini-3.8-flash-medium); expected_rc=75 ;;
        muse) failure_env=(STUB_MUSE_FAIL='429 Too Many Requests'); expected_rc=75 ;;
        opencode) failure_env=(STUB_OPENCODE_ERROR_TYPE=provider.go-limit STUB_OPENCODE_ERROR_MESSAGE='OpenCode Go rolling usage limit reached.'); expected_rc=75 ;;
        qwen) failure_env=(QL_STUB_EXIT=23); expected_rc=1 ;;
      esac
    fi
    outcome_file="$OUTCOMES/$provider-$result.tsv"
    rc=0
    printf 'task\n' | "${outcome_env[@]}" "${failure_env[@]}" MMO_OUTCOMES_FILE="$outcome_file" \
      bash "$PLUGIN_ROOT/scripts/$runner" --mode implement --repo "$outcome_repo" --timeout 10 \
      >"$OUTCOMES/body" 2>"$OUTCOMES/error" || rc=$?
    outcome_check "$provider $result appends exactly one row with exit $expected_rc" \
      outcome_row "$outcome_file" "$provider" "$expected_rc"
    [ "$rc" -eq "$expected_rc" ] || fail "outcome fixture $provider $result returned $rc, expected $expected_rc: $(cat "$OUTCOMES/error")"
  done
done
outcome_check 'unreported served model and tokens stay empty' awk -F '\t' 'NR == 2 {exit !($7 == "" && $11 == "")} END {if (NR != 2) exit 1}' "$OUTCOMES/codex-success.tsv"
outcome_check 'Muse records its configured model' awk -F '\t' 'NR == 2 {exit !($7 == "muse-spark-1.3")} END {if (NR != 2) exit 1}' "$OUTCOMES/muse-success.tsv"

printf 'task\n' | "${outcome_env[@]}" STUB_CODEX_RESULT=metadata MMO_OUTCOMES_FILE="$OUTCOMES/codex-metadata.tsv" \
  bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$outcome_repo" --timeout 10 >/dev/null 2>&1
outcome_check 'Codex records reported token count without inventing served model' awk -F '\t' 'NR == 2 {exit !($7 == "" && $11 == 1234)} END {if (NR != 2) exit 1}' "$OUTCOMES/codex-metadata.tsv"
printf 'task\n' | "${outcome_env[@]}" STUB_CODEX_RESULT=fake_metadata MMO_OUTCOMES_FILE="$OUTCOMES/codex-fake-metadata.tsv" \
  bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$outcome_repo" --timeout 10 >/dev/null 2>&1 || true
outcome_check 'Codex ignores token-looking echoed text before an error' awk -F '\t' 'NR == 2 {exit !($7 == "" && $11 == "")} END {if (NR != 2) exit 1}' "$OUTCOMES/codex-fake-metadata.tsv"
printf 'task\n' | "${outcome_env[@]}" STUB_CLAUDE_RESULT=metadata MMO_OUTCOMES_FILE="$OUTCOMES/claude-metadata.tsv" \
  bash "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$outcome_repo" --timeout 10 \
  --stream-log "$OUTCOMES/claude.stream" >/dev/null 2>&1
outcome_check 'Claude records response model and all reported usage categories' awk -F '\t' 'NR == 2 {exit !($7 == "served-model" && $11 == 65)} END {if (NR != 2) exit 1}' "$OUTCOMES/claude-metadata.tsv"

# Bad parsed options and classified timeout/auth/transient exits must also record once.
for pair in timeout:124 auth:77 transient:75; do
  fixture="${pair%:*}"; expected_rc="${pair#*:}"
  outcome_file="$OUTCOMES/codex-$fixture.tsv"
  rc=0
  printf 'task\n' | "${outcome_env[@]}" STUB_CODEX_RESULT="$fixture" MMO_OUTCOMES_FILE="$outcome_file" \
    bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$outcome_repo" --timeout 10 >/dev/null 2>&1 || rc=$?
  outcome_check "Codex $fixture exit $expected_rc recorded once" outcome_row "$outcome_file" codex "$expected_rc"
done
for runner in codex claude grok agy muse qwen-local; do
  outcome_file="$OUTCOMES/$runner-bad-args.tsv"
  rc=0
  "${outcome_env[@]}" MMO_OUTCOMES_FILE="$outcome_file" bash "$PLUGIN_ROOT/scripts/run-$runner.sh" \
    --mode implement --repo "$outcome_repo" --timeout 0 >/dev/null 2>&1 || rc=$?
  provider="$runner"; [ "$runner" != qwen-local ] || provider=qwen
  outcome_check "$runner bad parsed arguments recorded once" outcome_row "$outcome_file" "$provider" 2
done
printf 'task\n' | "${outcome_env[@]}" MMO_OUTCOMES_FILE="$OUTCOMES/opus.tsv" bash "$PLUGIN_ROOT/scripts/run-opus.sh" \
  --mode implement --repo "$outcome_repo" --timeout 10 >/dev/null 2>&1
outcome_check 'Opus alias records only the Claude invocation' outcome_row "$OUTCOMES/opus.tsv" claude 0

# The CLI already exposes this model identity on stderr; do not infer it from --model.
printf 'task\n' | "${outcome_env[@]}" QL_STUB_ERR='subagent-local-qwen3.8-27b-run: running model actual-local-model' \
  MMO_OUTCOMES_FILE="$OUTCOMES/qwen-served.tsv" bash "$PLUGIN_ROOT/scripts/run-qwen-local.sh" \
  --mode implement --repo "$outcome_repo" --timeout 10 >/dev/null 2>&1
outcome_check 'Qwen records the wrapper-reported served model' awk -F '\t' 'NR == 2 {exit !($6 == "default" && $7 == "actual-local-model")} END {if (NR != 2) exit 1}' "$OUTCOMES/qwen-served.tsv"

env -u MMO_OUTCOMES_FILE "${outcome_env[@]}" XDG_STATE_HOME="$OUTCOMES/xdg" bash "$PLUGIN_ROOT/scripts/run-codex.sh" \
  --mode implement --repo "$outcome_repo" --timeout 0 >/dev/null 2>&1 || true
outcome_check 'unset override uses XDG state location' outcome_row "$OUTCOMES/xdg/multi-model-orchestrator/outcomes.tsv" codex 2
rc=0
"${outcome_env[@]}" MMO_OUTCOMES_FILE="$OUTCOMES/escaped.tsv" bash "$PLUGIN_ROOT/scripts/run-codex.sh" \
  --mode implement --repo "$outcome_repo" --model $'invalid\tmodel\nname' >/dev/null 2>&1 || rc=$?
outcome_check 'tabs and newlines cannot split a row or column' outcome_row "$OUTCOMES/escaped.tsv" codex 2
(cd "$outcome_repo" && MMO_OUTCOMES_FILE="$OUTCOMES/relative-repo.tsv" \
  bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo . --timeout 0) >/dev/null 2>&1 || true
outcome_check 'relative repository path records its directory basename on early failure' \
  outcome_row "$OUTCOMES/relative-repo.tsv" codex 2
for remote in git@example.test:example/fixture.git https://example.test/example/fixture.git; do
  git -C "$outcome_repo" remote remove origin 2>/dev/null || true
  git -C "$outcome_repo" remote add origin "$remote"
  rm -f "$OUTCOMES/origin.tsv"
  "${outcome_env[@]}" MMO_OUTCOMES_FILE="$OUTCOMES/origin.tsv" bash "$PLUGIN_ROOT/scripts/run-codex.sh" \
    --mode implement --repo "$outcome_repo" --timeout 0 >/dev/null 2>&1 || true
  outcome_check "repository identity from $remote" awk -F '\t' 'NR == 2 {exit !($2 == "example/fixture")} END {if (NR != 2) exit 1}' "$OUTCOMES/origin.tsv"
done
git -C "$outcome_repo" remote remove origin

# Compare exact output for an impossible parent and a read-only existing file.
printf 'blocked\n' > "$OUTCOMES/not-a-directory"
printf 'existing\n' > "$OUTCOMES/readonly.tsv"
chmod 444 "$OUTCOMES/readonly.tsv"
for fixture in ok error; do
  for blocked in not-a-directory/outcomes.tsv readonly.tsv; do
    if [ "$blocked" = readonly.tsv ] && [ -w "$OUTCOMES/$blocked" ]; then
      printf 'SKIP: read-only outcome check requires an unprivileged service user\n'
      continue
    fi
    rc_good=0; rc_bad=0
    for destination in good bad; do
      outcome_file="$OUTCOMES/append.tsv"
      [ "$destination" != bad ] || outcome_file="$OUTCOMES/$blocked"
      rc=0
      printf 'task\n' | "${outcome_env[@]}" STUB_CODEX_RESULT="$fixture" MMO_OUTCOMES_FILE="$outcome_file" \
        bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$outcome_repo" --timeout 10 \
        --out "$OUTCOMES/final" --stream-log "$OUTCOMES/stream" \
        >"$OUTCOMES/$destination.stdout" 2>"$OUTCOMES/$destination.stderr" || rc=$?
      if [ "$destination" = good ]; then rc_good="$rc"; else rc_bad="$rc"; fi
    done
    outcome_check "failed append ($blocked) preserves $fixture exit code" test "$rc_good" -eq "$rc_bad"
    outcome_check "failed append ($blocked) preserves $fixture stdout" cmp -s "$OUTCOMES/good.stdout" "$OUTCOMES/bad.stdout"
    outcome_check "failed append ($blocked) preserves $fixture stderr" cmp -s "$OUTCOMES/good.stderr" "$OUTCOMES/bad.stderr"
  done
done

# An exhausted T1 attempt and a successful T2 attempt each carry the selected tier.
printf 'T1\tagy\tgemini-3.8-flash\tlow\nT2\tagy\tgemini-3.8-flash\thigh\n' > "$OUTCOMES/tiers.tsv"
printf 'task\n' | "${outcome_env[@]}" MMO_POOL_TIERS="$OUTCOMES/tiers.tsv" \
  STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low MMO_OUTCOMES_FILE="$OUTCOMES/pool.tsv" \
  bash "$POOL" run --tier T1 --usage /dev/null --repo "$outcome_repo" --timeout 10 >/dev/null 2>&1
outcome_check 'pool fallback records two runner rows and their selected tiers' awk -F '\t' '
  NR == 2 {if ($3 != "T1" || $5 != "agy" || $9 != 75) exit 1}
  NR == 3 {if ($3 != "T2" || $5 != "agy" || $9 != 0) exit 1}
  END {if (NR != 3) exit 1}
' "$OUTCOMES/pool.tsv"

head_sha="$(git -C "$outcome_repo" rev-parse HEAD)"
for verdict in APPROVE NEEDS_WORK; do
  printf '%s\n' "$verdict" > "$OUTCOMES/review.txt"
  rc=0
  (cd "$outcome_repo" && MMO_OUTCOMES_FILE="$OUTCOMES/gate-$verdict.tsv" bash "$GATE" \
    --leg "codex=$OUTCOMES/review.txt") >/dev/null 2>&1 || rc=$?
  outcome_check "gate $verdict records its reviewed HEAD and combined verdict" awk -F '\t' -v head="$head_sha" -v verdict="$verdict" -v rc="$rc" '
    NR == 2 {if (NF != 13 || $4 != "gate" || $9 != rc || $12 != head || $13 != verdict) exit 1}
    END {if (NR != 2) exit 1}
  ' "$OUTCOMES/gate-$verdict.tsv"
done
for invalid in 2 3; do
  provider=codex; printf 'missing verdict\n' > "$OUTCOMES/review.txt"
  if [ "$invalid" -eq 3 ]; then provider=qwen; printf 'APPROVE\n' > "$OUTCOMES/review.txt"; fi
  rc=0
  (cd "$outcome_repo" && MMO_OUTCOMES_FILE="$OUTCOMES/gate-error-$invalid.tsv" bash "$GATE" \
    --leg "$provider=$OUTCOMES/review.txt") >/dev/null 2>&1 || rc=$?
  outcome_check "gate error $invalid records HEAD without a combined verdict" awk -F '\t' -v head="$head_sha" -v rc="$invalid" '
    NR == 2 {if (NF != 13 || $4 != "gate" || $9 != rc || $12 != head || $13 != "") exit 1}
    END {if (NR != 2) exit 1}
  ' "$OUTCOMES/gate-error-$invalid.tsv"
done
printf 'Outcome regressions: %s PASS, %s FAIL.\n' "$outcome_passes" "$outcome_failures"
[ "$outcome_failures" -eq 0 ] || exit 1

python3 "$PLUGIN_ROOT/tests/test-outcome-lifecycle.py" "$PLUGIN_ROOT/scripts" "$OUTCOMES/lifecycle" "$outcome_repo"
python3 "$PLUGIN_ROOT/tests/test-stop-signals.py" "$PLUGIN_ROOT/scripts" "$WORK/stop-signals"
python3 "$PLUGIN_ROOT/tests/test-runner-preservation.py" "$PLUGIN_ROOT/scripts"

printf 'All multi-model-orchestrator tests passed.\n'
