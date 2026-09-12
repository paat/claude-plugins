#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/tmp"
export TMPDIR="$WORK/tmp"
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
printf '%s\n' "$@" > "$STUB_CODEX_ARGS"
out=""
: > "$STUB_CODEX_CWD"
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  [ "$1" = -C ] && { printf '%s\n' "$2" > "$STUB_CODEX_CWD"; shift 2; continue; }
  shift
done
cat > "$STUB_CODEX_PROMPT"
case "${STUB_CODEX_RESULT:-ok}" in
  error) exit 23 ;;
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
printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
# Record the working directory the runner actually placed us in.
pwd > "$STUB_CLAUDE_CWD"
cat > "$STUB_CLAUDE_PROMPT"
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
    *) printf 'claude findings\nAPPROVE\n' ;;
  esac
}
if [ "$format" = stream-json ]; then
  case "${STUB_CLAUDE_RESULT:-ok}" in
    error) exit 23 ;;
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
    progress) printf 'I will inspect the diff.\n' ;;
    approved) printf 'claude findings\nAPPROVED\n' ;;
    needs_work_space) printf 'claude findings\nNEEDS WORK\n' ;;
    template) printf '**VERDICT:** APPROVE\nREADY TO MERGE — nothing further coming.\n' ;;
    prose_approve) printf 'I cannot approve this change because tests fail.\n' ;;
    *) printf 'claude findings\nAPPROVE\n' ;;
  esac
fi
STUB
cat > "$WORK/bin/grok" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_GROK_ARGS"
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
if [ -n "$debug_file" ]; then
  case "${STUB_GROK_DEBUG:-applied}" in
    absent) ;;
    empty) : > "$debug_file" ;;
    applied) printf '%s\n' "$allowlist_applied" > "$debug_file" ;;
    info) printf '%s\n' "${allowlist_applied/ DEBUG / INFO }" > "$debug_file" ;;
    trailing_field) printf '%s duration_ms=3\n' "$allowlist_applied" > "$debug_file" ;;
    no_agent) printf '%s\n' "${allowlist_applied/ agent=grok-build-plan/}" > "$debug_file" ;;
    no_span) printf '%s\n' "${allowlist_applied/session.spawn\{session_id=fixture client_type=Generic start_type=\"new\"\}: /}" > "$debug_file" ;;
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
case "${STUB_GROK_RESULT:-ok}" in
  error) exit 23 ;;
  empty) exit 0 ;;
  # Unlink --out while the runner's redirect FD is still open so the path is
  # missing after the subshell closes (shell > always creates the file first).
  missing) [ -n "${STUB_UNLINK_OUT:-}" ] && rm -f "$STUB_UNLINK_OUT"; exit 0 ;;
  timeout) exit 124 ;;
  progress) printf 'Let me inspect the files.\n' ;;
  approved) printf 'grok findings\nAPPROVED\n' ;;
  needs_work_space) printf 'grok findings\nNEEDS WORK\n' ;;
  prose_approve) printf 'This section still needs work before ship.\n' ;;
  *) printf 'grok findings\nAPPROVE\n' ;;
esac
STUB
chmod +x "$WORK/bin/codex" "$WORK/bin/claude" "$WORK/bin/grok"
export PATH="$WORK/bin:$PATH"
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

for drift_case in info trailing_field no_agent no_span reordered_allowed; do
  drift_rc=0
  printf 'repo advice\n' | STUB_GROK_DEBUG="$drift_case" "$PLUGIN_ROOT/scripts/run-grok.sh" \
    --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-$drift_case.err" \
    || drift_rc=$?
  [ "$drift_rc" -eq 0 ] || fail "Grok rejects applied allowlist variant $drift_case with exit $drift_rc"
done

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

out="$(printf 'bounded review\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" --effort ultra --timeout 5 2> "$WORK/codex.err")"
[ "$out" = $'codex findings\nAPPROVE' ] || fail 'Codex final output'
contains "$WORK/codex.args" 'gpt-6-astra' 'Codex model pin'
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
if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-5.6-terra --effort ultra >/dev/null 2>&1; then
  fail 'Ultra on non-Astra model rejected'
fi
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
pass 'Verdict-format rejection preserves body in --out and stdout'
pass 'Prose containing approve/needs work mid-sentence still rejected'

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
  --model claude-haiku-4-5 --out "$WORK/out-dest/claude-final.txt" --timeout 5 \
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
    --model claude-haiku-4-5 --out claude-relative.txt --timeout 5 \
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
  --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --out /dev/stdout --timeout 5 \
  > "$WORK/out-dest/claude-dev.stdout" 2> "$WORK/out-dest/claude-dev.err" || true
contains "$WORK/out-dest/claude-dev.err" 'log=/dev/stdout' 'Claude preserves /dev/stdout output path'
printf 'dev codex out\n' | STUB_CODEX_RESULT=error "$PLUGIN_ROOT/scripts/run-codex.sh" \
  --mode review --dir "$WORK/repo" --out /dev/stdout \
  --stream-log "$WORK/out-dest/codex-dev.stream" --timeout 5 \
  > "$WORK/out-dest/codex-dev.stdout" 2> "$WORK/out-dest/codex-dev.err" || true
exact_line "$WORK/codex.args" '/dev/stdout' 'Codex preserves /dev/stdout output path'
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
contains "$WORK/claude.args" 'claude-opus-5' 'Claude Opus 5 model pin'
contains "$WORK/claude.args" 'xhigh' 'Opus effort pin'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude YOLO posture'
contains "$WORK/claude.args" 'Bash,Write,Edit,NotebookEdit,Task,WebFetch,WebSearch' 'Opus mutation tools disabled'
contains "$WORK/claude.prompt" 'acceptance criterion' 'Opus review task'
contains "$WORK/claude.prompt" '+after' 'Opus receives diff'
pass 'Claude review is current-model pinned, bounded, and diff-aware'

printf 'new file\n' > "$WORK/repo/new.txt"
printf 'review new file\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode review --repo "$WORK/repo" --base HEAD --timeout 5 >/dev/null 2> "$WORK/opus-untracked.err"
contains "$WORK/claude.prompt" 'new.txt' 'Opus receives untracked file diff'
contains "$WORK/claude.args" 'claude-opus-5' 'Compatibility wrapper pins Opus 5'
pass 'Opus compatibility wrapper uses Opus 5 and includes untracked files'

printf 'architecture question\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-advice.err"
contains "$WORK/claude.prompt" 'architecture question' 'Opus advice prompt'
contains "$WORK/claude.prompt" 'Do not implement' 'Opus advice no-write contract'
pass 'Claude advice stays bounded and read-only'

printf 'implementation task\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$WORK/repo" --model claude-sonnet-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-implement.err"
contains "$WORK/claude.args" 'Read,Glob,Grep,Bash,Write,Edit' 'Claude implementation tools enabled'
contains "$WORK/claude.args" 'Task,WebFetch,WebSearch,NotebookEdit' 'Claude implementation fan-out and network tools disabled'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude implementation YOLO posture'
contains "$WORK/claude.prompt" 'implementation task' 'Claude implementation task packet'
pass 'Claude implementation is writable, single-agent, and unrestricted'

printf 'quick file map\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --timeout 5 >/dev/null 2> "$WORK/haiku.err"
contains "$WORK/claude.args" 'claude-haiku-4-5' 'Haiku current model pin'
absent "$WORK/claude.args" '--effort' 'Haiku must omit unsupported effort flag'
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --effort low >/dev/null 2>&1; then
  fail 'explicit Haiku effort rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus-4-8 >/dev/null 2>&1; then
  fail 'earlier Claude model rejected'
fi
pass 'Claude runner enforces the current catalog and Haiku effort compatibility'

out="$(printf 'bounded implementation\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode implement --repo "$WORK/repo" --model grok-4.5 --effort medium --timeout 5 2> "$WORK/grok.err")"
[ "$out" = $'grok findings\nAPPROVE' ] || fail 'Grok final output'
contains "$WORK/grok.args" 'grok-4.5' 'Grok 4.5 model pin'
contains "$WORK/grok.args" '--reasoning-effort' 'Grok effort flag'
contains "$WORK/grok.args" 'medium' 'Grok medium effort pin'
contains "$WORK/grok.args" '--no-subagents' 'Grok worker fan-out disabled'
contains "$WORK/grok.args" '--max-turns' 'Grok turn cap flag'
contains "$WORK/grok.args" '30' 'Grok default turn cap'
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
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4 >/dev/null 2>&1; then
  fail 'earlier Grok model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --effort xhigh >/dev/null 2>&1; then
  fail 'unsupported Grok effort rejected'
fi
pass 'Grok runner pins 4.5 and enforces low-to-high effort'

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
contains "$WORK/claude.args" 'claude-opus-5' 'Legacy Opus alias maps to Opus 5'
pass 'Legacy Opus alias maps only to the current model'

printf 'primary config\n' | MMO_CLAUDE_MODEL=claude-sonnet-5 MMO_CLAUDE_EFFORT=xhigh "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/primary-config.err"
contains "$WORK/claude.args" 'claude-sonnet-5' 'Compatibility wrapper preserves primary model config'
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
contains "$META_CMD" 'skills/meta-orchestration/SKILL.md' 'Meta command loads the meta-orchestration skill'
contains "$META_CMD" '--resume' 'Meta command documents resume'
contains "$META_CMD" 'mission brief' 'Meta command takes a free-form what-to-achieve brief'
contains "$META_SKILL" 'HOW is yours' 'Meta skill owns the how; the brief owns the what'
contains "$META_SKILL" 'READY TO MERGE — nothing further coming.' 'Meta skill pins the literal merge signal'
contains "$META_SKILL" 'route-model-task' 'Meta skill routes via route-model-task'
contains "$META_SKILL" 'any research memo for the item' 'Meta skill feeds research memos into the worker packet'
contains "$META_SKILL" 'tribunal-review:closing-tribunal-loop' 'Meta skill chains the tribunal close-out'
contains "$META_SKILL" '124' 'Meta skill keeps the exit-124 salvage rule'
contains "$META_SKILL" 'not a liveness check' 'Meta skill keeps the transcript-mtime liveness rule'
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
contains "$META_SKILL" 'immediately before dispatch' 'Meta skill commits the handoff immediately before dispatch'
[ "$(grep -cF 'immediately before dispatch' "$META_SKILL")" -eq 1 ] || fail 'Meta skill states immediately before dispatch exactly once'
absent "$META_SKILL" 'task/job id' 'Meta skill does not record a session-local task/job id'
contains "$META_SKILL" '-- <handoff>' 'Meta skill requires a path-limited handoff commit'
contains "$META_SKILL" 'git add <handoff>' 'Meta skill stages the handoff before the path-limited commit'
contains "$META_SKILL" 'literal resume command' 'Meta skill requires the literal resume command in the handoff'
contains "$META_SKILL" 'announcing a dispatch without that committed artifact is a defect' 'Meta skill forbids announced-but-uncommitted dispatches'
contains "$META_SKILL" 'unless the brief explicitly waives it' 'Meta skill requires an explicit tribunal waiver'
[ "$(grep -cF '# optional' "$META_SKILL")" -eq 5 ] || fail 'Meta skill YAML example keeps exactly five # optional markers'
contains "$META_SKILL" 'reconcile; do not overwrite it' 'Meta skill refuses conflicting concurrent handoff overwrites'
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
[ "$(grep -cF 'tree-independent item' "$META_SKILL")" -eq 1 ] || fail 'Meta skill mentions tree-independent item exactly once'
contains "$META_SKILL" 'Do not burn the session on preflight beyond the Fresh-start checks' 'Meta skill bounds preflight to the Fresh-start checks'
contains "$META_SKILL" 'CLAUDE_PLUGIN_ROOT}/scripts/' 'Meta skill names the plugin scripts directory for runners'
absent "$META_SKILL" 'Poll ' 'Meta skill removes unactionable polling guidance'
absent "$META_SKILL" 'preflight.sh' 'Meta skill references tribunal instead of duplicating its preflight'
absent "$META_SKILL" 'tribunal-round' 'Meta skill references tribunal instead of duplicating its round protocol'
absent "$META_SKILL" 'as soon as real work starts' 'Meta skill no longer triggers the handoff on vague real-work start'
contains "$META_REFS/handoff-template.md" 'Stop here first' 'Handoff template keeps the single next action'
contains "$META_REFS/handoff-template.md" 'do not re-litigate' 'Handoff template keeps ratified decisions'
contains "$META_REFS/handoff-template.md" 'remain in force verbatim' 'Handoff template keeps delta inheritance'
contains "$META_REFS/handoff-template.md" 'In-flight legs:' 'Handoff template records dispatched legs'
contains "$META_REFS/handoff-template.md" 'runner + mode + model' 'In-flight legs identify their runner configuration'
contains "$META_REFS/handoff-template.md" 'output path' 'In-flight legs identify their output'
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
contains "$META_REFS/review-prompts.md" 'READY TO MERGE — nothing further coming.' 'Review templates request the merge signal on final APPROVE'
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
  --model claude-haiku-4-5 --timeout 5 >/dev/null 2> "$WORK/syn-claude-dir.err" \
  || fail 'Claude accepts --dir as --repo synonym'
exact_line "$WORK/claude.cwd" "$repo_top" 'Claude --dir places the stub in the supplied repo'
printf 'synonym claude repo\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-4-5 --timeout 5 >/dev/null 2> "$WORK/syn-claude-repo.err" \
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
  --model claude-haiku-4-5 --out "$WORK/flag-dest/claude-final.txt" \
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
  --model claude-haiku-4-5 --max-turns 3 --timeout 5 >/dev/null 2> "$WORK/flag-dest/claude-turns.err" \
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
  --model claude-haiku-4-5 --max-turns notanumber --timeout 5 \
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

# Regression: under --stream-log, provider failure must surface as the provider's
# rc (PIPESTATUS[0]), not tee's always-success rc (PIPESTATUS[1]). Assert the
# final, stream, and ${out}.stderr artifacts still exist.
mkdir -p "$WORK/stream-fail"
set +e
printf 'claude stream fail\n' | STUB_CLAUDE_RESULT=error \
  "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" \
  --model claude-haiku-4-5 \
  --out "$WORK/stream-fail/claude-final.txt" \
  --stream-log "$WORK/stream-fail/claude.stream" --timeout 5 \
  >/dev/null 2> "$WORK/stream-fail/claude-run.err"
claude_stream_fail_rc=$?
set -e
[ "$claude_stream_fail_rc" -eq 23 ] || fail "Claude --stream-log provider failure rc=$claude_stream_fail_rc want 23 (provider), not tee"
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
[ "$grok_stream_fail_rc" -eq 23 ] || fail "Grok --stream-log provider failure rc=$grok_stream_fail_rc want 23 (provider), not tee"
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
  --model claude-haiku-4-5 \
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
  --model claude-haiku-4-5 --out "$WORK/523/a-final.txt" \
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
  --model claude-haiku-4-5 --out "$WORK/523/b-final.txt" \
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
  --model claude-haiku-4-5 --out "$WORK/523/c-final.txt" \
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
  --model claude-haiku-4-5 --out "$WORK/523/d-final.txt" --timeout 5 \
  >/dev/null 2> "$WORK/523/d.err" \
  || fail '523d: run without --stream-log succeeds'
exact_line "$WORK/claude.args" 'text' '523d: without --stream-log uses --output-format text'
absent "$WORK/claude.args" 'stream-json' '523d: without --stream-log omits stream-json'
absent "$WORK/claude.args" '--verbose' '523d: without --stream-log omits --verbose'
pass '#523d: without --stream-log invocation stays text mode'

# (e) review mode with --stream-log: verdict gate reads extracted final message.
printf 'claude 523e\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" \
  --base HEAD --model claude-haiku-4-5 --out "$WORK/523/e-final.txt" \
  --stream-log "$WORK/523/e.stream" --timeout 5 \
  >/dev/null 2> "$WORK/523/e.err" \
  || fail '523e: review with --stream-log must pass on APPROVE'
contains "$WORK/523/e-final.txt" 'APPROVE' '523e: --out holds extracted APPROVE verdict'
pass '#523e: review --stream-log verdict gate reads extracted final message'

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
  --model claude-haiku-4-5 --out "$WORK/empty-claude.txt" --timeout 5 \
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
  --model claude-haiku-4-5 --out "$WORK/missing-claude.txt" --timeout 5 \
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

printf 'All multi-model-orchestrator tests passed.\n'
