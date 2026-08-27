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
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  shift
done
cat > "$STUB_CODEX_PROMPT"
case "${STUB_CODEX_RESULT:-ok}" in
  empty) : > "$out" ;;
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
cat > "$STUB_CLAUDE_PROMPT"
case "${STUB_CLAUDE_RESULT:-ok}" in
  empty) exit 0 ;;
  progress) printf 'I will inspect the diff.\n' ;;
  approved) printf 'claude findings\nAPPROVED\n' ;;
  needs_work_space) printf 'claude findings\nNEEDS WORK\n' ;;
  template) printf '**VERDICT:** APPROVE\nREADY TO MERGE — nothing further coming.\n' ;;
  prose_approve) printf 'I cannot approve this change because tests fail.\n' ;;
  *) printf 'claude findings\nAPPROVE\n' ;;
esac
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
while [ "$#" -gt 0 ]; do
  [ "$1" = --prompt-file ] && { prompt="$2"; shift 2; continue; }
  [ "$1" = --debug-file ] && { debug_file="$2"; shift 2; continue; }
  shift
done
[ -n "$prompt" ] && cat "$prompt" > "$STUB_GROK_PROMPT"
allowlist_applied='2026-08-27T07:16:41.995595Z DEBUG session.spawn{session_id=fixture client_type=Generic start_type="new"}: xai_grok_agent::builder: tools allowlist applied agent=grok-build-plan allowed=["read_file", "list_dir", "grep"]'
if [ -n "$debug_file" ]; then
  case "${STUB_GROK_DEBUG:-applied}" in
    absent) ;;
    applied) printf '%s\n' "$allowlist_applied" > "$debug_file" ;;
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
  empty) exit 0 ;;
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
export STUB_CODEX_ARGS="$WORK/codex.args" STUB_CODEX_PROMPT="$WORK/codex.prompt"
export STUB_CLAUDE_ARGS="$WORK/claude.args" STUB_CLAUDE_PROMPT="$WORK/claude.prompt"
export STUB_GROK_ARGS="$WORK/grok.args" STUB_GROK_PROMPT="$WORK/grok.prompt"
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

absent_rc=0
printf 'repo advice\n' | STUB_GROK_DEBUG=absent "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-allowlist-absent.err" \
  || absent_rc=$?
[ "$absent_rc" -ne 0 ] || fail 'Grok accepts a missing allowlist debug file'
contains "$WORK/grok-allowlist-absent.err" 'allowlist not enforced by the installed grok CLI' \
  'Grok missing debug file does not name allowlist enforcement failure'

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
contains "$WORK/codex.args" 'gpt-5.6-sol' 'Codex model pin'
contains "$WORK/codex.args" 'model_reasoning_effort="ultra"' 'Codex Ultra pin'
contains "$WORK/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'Codex unrestricted posture'
contains "$WORK/codex.prompt" 'bounded review' 'Codex stdin prompt'
contains "$WORK/codex.prompt" 'semantically read-only reviewer' 'Codex review mode prepends the no-write contract'
codex_review_root="$(awk 'previous == "-C" { print; exit } { previous = $0 }' "$WORK/codex.args")"
[ "$codex_review_root" = "$WORK/repo" ] || fail 'Codex review uses the repo working root'
pass 'Codex runner pins Sol Ultra and stdin prompt'

if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --effort extreme >/dev/null 2>&1; then
  fail 'invalid Codex effort rejected'
fi
pass 'Codex runner rejects unknown effort'

if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-5.5 >/dev/null 2>&1; then
  fail 'earlier Codex model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-5.6-terra --effort ultra >/dev/null 2>&1; then
  fail 'Ultra on non-Sol model rejected'
fi
pass 'Codex runner enforces the GPT-5.6 catalog and Sol-only Ultra'

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
); then
  fail 'Claude relative --out invocation succeeds from caller cwd'
fi
[ -f "$WORK/out-dest/claude-relative.txt" ] || fail 'Claude relative --out resolves at caller cwd'
[ -f "$WORK/out-dest/claude-relative.txt.stderr" ] || fail 'Claude relative --out stderr resolves at caller cwd'
[ ! -e "$WORK/repo/claude-relative.txt" ] || fail 'Claude relative --out stays outside reviewed repo'
[ ! -e "$WORK/repo/claude-relative.txt.stderr" ] || fail 'Claude relative --out stderr stays outside reviewed repo'
pass 'Claude relative --out resolves at caller cwd outside the reviewed repo'

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
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$sol_pid"' 'Orchestration checks Codex reviewer status'
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
contains "$META_SKILL" 'At the start of every turn, before anything else' 'Meta skill reads unread leg output at turn start'
contains "$META_SKILL" 'resume at the gate' 'Meta skill resumes completed legs at their gate'
contains "$META_SKILL" 'a defect, not a wait' 'Meta skill rejects ending a turn with an unarranged live leg'
contains "$META_SKILL" 'record it in the handoff' 'Meta skill records live legs before ending a turn'
absent "$META_SKILL" 'Poll long-running legs on a ~30-minute cadence; no tight loops.' 'Meta skill removes unactionable polling guidance'
absent "$META_SKILL" 'preflight.sh' 'Meta skill references tribunal instead of duplicating its preflight'
absent "$META_SKILL" 'tribunal-round' 'Meta skill references tribunal instead of duplicating its round protocol'
contains "$META_REFS/handoff-template.md" 'Stop here first' 'Handoff template keeps the single next action'
contains "$META_REFS/handoff-template.md" 'do not re-litigate' 'Handoff template keeps ratified decisions'
contains "$META_REFS/handoff-template.md" 'remain in force verbatim' 'Handoff template keeps delta inheritance'
contains "$META_REFS/handoff-template.md" 'In-flight legs:' 'Handoff template records dispatched legs'
contains "$META_REFS/handoff-template.md" 'runner + mode + model' 'In-flight legs identify their runner configuration'
contains "$META_REFS/handoff-template.md" 'output path' 'In-flight legs identify their output'
contains "$META_REFS/handoff-template.md" 'dispatch time (UTC)' 'In-flight legs record UTC dispatch time'
contains "$META_REFS/handoff-template.md" 'how completion will be observed' 'In-flight legs record their completion path'
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
contains "$META_REFS/worker-prompt.md" 'the orchestrator commits' 'Worker template reconciles commits with no-commit leg contracts'
absent "$META_REFS/review-prompts.md" 'REQUEST_CHANGES' 'Review template does not reintroduce the unsupported verdict token'
[ -f "$META_REFS/research-leg.md" ] || fail 'Research leg reference exists'
contains "$META_REFS/research-leg.md" 'Do not trigger' 'Research leg reference keeps the negative trigger rules'
[ "$(wc -l < "$META_SKILL")" -le 150 ] || fail 'meta-orchestration SKILL.md exceeds the 150-line budget'
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

printf 'All multi-model-orchestrator tests passed.\n'
