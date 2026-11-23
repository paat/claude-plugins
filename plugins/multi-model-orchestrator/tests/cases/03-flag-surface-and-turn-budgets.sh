#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

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
# The turn-budget line moved to harness-adjustments.tsv; the prompt Grok receives is unchanged.
old_implement_prompt() {  # the pre-move mmo_implement_prompt REQUEST_FILE [EXTRA_LINE]
  printf '%s\n' 'You are one fresh, bounded implementation worker.'
  printf '%s\n' 'Obey the task acceptance, allowed files, and test exactly. Do not broaden scope or commit.'
  [ -z "${2:-}" ] || printf '%s\n' "$2"
  printf '%s\n' 'Inspect your diff, run the named test, and stop when acceptance passes.'
  printf '%s\n' 'Make reasonable assumptions, state them in your final message, and finish the task; do not stop to ask questions or propose next steps.'
  printf '%s\n' 'Never weaken, skip or special-case a test to make it pass; if a requirement cannot be met, say so in your final message.'
  printf '\n## Task packet\n'
  cat "$1"
}
printf 'implement thing\n' > "$WORK/grok-old.request"
old_implement_prompt "$WORK/grok-old.request" "You have at most 250 agent turns: make the edits early, keep dev-server, screenshot and exploration loops short, and leave room to run the named test and write your final message." > "$WORK/grok-old.prompt"
cmp -s "$WORK/grok-old.prompt" "$WORK/grok.prompt" || fail 'Grok implement prompt is byte-identical to the pre-adjustments prompt'
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
contains "$WORK/grok.prompt" 'Do not commit.' 'implement resume without worker-commits forbids commit'
: > "$STUB_GROK_CALLS"
rm -f "$STUB_GROK_TOUCH"
STUB_GROK_MAXTURNS_FIRST=1 MMO_WORKER_COMMITS=1 grok_mt "$WORK/mt-resume-own.err" --mode implement --max-turns 5
rm -f "$STUB_GROK_TOUCH"
[ "$mt_rc" -eq 0 ] || fail "worker-commits resume rc=$mt_rc want 0 ($(cat "$WORK/mt-resume-own.err"))"
contains "$WORK/grok.prompt" 'Commit your changes.' 'implement resume with worker-commits says to commit'
absent "$WORK/grok.prompt" 'Do not commit.' 'implement resume with worker-commits does not forbid commit'
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
printf 'review budget check\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --effort high --repo "$WORK/repo" \
  --base HEAD --out "$WORK/716/rev-default.out" >/dev/null 2> "$WORK/716/rev-default.err" \
  || fail '#716: default review run succeeds'
exact_line "$WORK/grok.args" '60' '#722: high-effort default-timeout review keeps 60 turns'
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
  --out "$WORK/716/adv-default.out" >/dev/null 2> "$WORK/716/adv-default.err" \
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

# A hard timeout with no report is marked and stays exit 124.
: > "$STUB_GROK_CALLS"
rc=0
printf 'review inspect timeout\n' | STUB_GROK_RESULT=timeout \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
  --out "$WORK/716/rev-timeout.out" --timeout 60 >/dev/null 2> "$WORK/716/rev-timeout.err" || rc=$?
[ "$rc" -eq 124 ] || fail "#716: review inspect timeout rc=$rc want 124 ($(cat "$WORK/716/rev-timeout.err"))"
[ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail '#716: review inspect timeout makes 1 grok call'
contains "$WORK/716/rev-timeout.err" 'truncated=timeout' '#722: empty hard timeout is marked'
[ ! -s "$WORK/716/rev-timeout.out" ] || fail '#722: empty timeout must not fabricate a report'
pass '#716: Grok review/advise turn budget, default .stream, read-only allowlist synthesis on cap, exit 78'

# #722: neither short timeouts nor high effort cut the review turn budget.
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --effort high --timeout 120 --repo "$WORK/repo" \
  >/dev/null 2>"$WORK/716/short.err" || fail '#722: short high-effort review succeeds'
exact_line "$WORK/grok.args" '60' '#722: 120 s high-effort review keeps 60 turns'
for mode in review advise; do
  : > "$STUB_GROK_CALLS"
  out="$WORK/716/$mode-timeout.out"
  rc=0
  printf x | STUB_GROK_RESULT=timeout STUB_GROK_PROGRESS='Inspection progress only.' \
    "$PLUGIN_ROOT/scripts/run-grok.sh" --mode "$mode" --repo "$WORK/repo" --timeout 240 --out "$out" \
    > "$out.stdout" 2> "$out.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "#722: $mode hard timeout rc=$rc want 124"
  [ "$(wc -l < "$STUB_GROK_CALLS")" -eq 1 ] || fail "#722: $mode timeout ends inspection without a resume"
  contains "$out.err" 'truncated=timeout' "#722: $mode timeout is marked"
  contains "$out.stream" 'Inspection progress only.' "#722: $mode stream retains progress"
  [ ! -s "$out.stdout" ] && [ ! -s "$out" ] || fail "#722: timed-out $mode has no report"
done
: > "$STUB_GROK_CALLS"
rc=0
printf 'slow synthesis\n' | STUB_GROK_RESULT=maxturns STUB_GROK_MAXTURNS_FIRST=1 \
  STUB_GROK_PROGRESS='Inspection progress only.' STUB_GROK_RESUME_RESULT=timeout \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 60 \
  --out "$WORK/716/resume-timeout.out" > "$WORK/716/resume-timeout.stdout" 2> "$WORK/716/resume-timeout.err" || rc=$?
[ "$rc" -eq 124 ] || fail "#722: synthesis timed out with rc=$rc"
contains "$WORK/716/resume-timeout.err" 'truncated=timeout' '#722: synthesis hard timeout is marked'
contains "$WORK/716/resume-timeout.out.stream" 'Inspection progress only.' '#722: stream retains inspection progress'
[ ! -s "$WORK/716/resume-timeout.stdout" ] && [ ! -s "$WORK/716/resume-timeout.out" ] || fail '#722: progress alone cannot become advice'
: > "$STUB_GROK_CALLS"
rc=0
printf 'slow inspect\n' | STUB_GROK_RESULT=slow_cap "$PLUGIN_ROOT/scripts/run-grok.sh" \
  --mode review --repo "$WORK/repo" --timeout 1 --out "$WORK/716/hard.out" \
  > "$WORK/716/hard.stdout" 2> "$WORK/716/hard.err" || rc=$?
[ "$rc" -eq 124 ] || fail "#722: a real deadline takes precedence over a turn-cap diagnostic (rc=$rc)"
contains "$WORK/716/hard.err" 'truncated=timeout' '#722: hard deadline is marked'
contains "$WORK/716/hard.out.stream" 'Inspection progress only.' '#722: partial text survives SIGTERM'
[ ! -s "$WORK/716/hard.stdout" ] || fail '#722: interrupted progress cannot pass as a review'
pass '#722: high-effort turn budgets and honest review/advise timeouts'

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

