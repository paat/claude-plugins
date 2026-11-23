#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

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
  '`jq` is required for `run-claude.sh --stream-log`, `run-agy.sh`, `run-muse.sh`, `run-vibe.sh`, and the local-Qwen route' \
  'README documents where jq is required'
pass 'README documents jq for Claude --stream-log, agy, Muse, Vibe, and local Qwen'

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

