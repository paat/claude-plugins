#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

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
# One argument per line: both flags must belong to `codex exec`, before -C and the prompt.
[ "$(sed -n 1,3p "$WORK/codex.args" | tr '\n' ' ')" = 'exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust ' ] \
  || fail 'Codex leg passes the hook-trust bypass to codex exec'
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
