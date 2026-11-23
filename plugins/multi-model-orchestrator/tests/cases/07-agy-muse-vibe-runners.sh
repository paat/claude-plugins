#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

# --- run-agy.sh against a stub agy ---
mmo_ensure_agy_stub

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
neon_n="$(find "$AG/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'bounded task\n' | "${agy_env[@]}" bash "$AGY_RUN" --mode implement --model gemini-4-neon --effort high --repo "$AR" --timeout 30 >/dev/null 2>"$AG/err" \
  || fail "run-agy accepts Neon: $(cat "$AG/err")"
exact_line "$AG/calls/call.${neon_n}.args" 'gemini-4-neon-high' 'Neon model and effort reach the CLI'
pass 'run-agy: Neon is an accepted model'

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
mmo_ensure_muse_stub

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

# ASK-76: the dropped provider has no runner.
[ ! -e "$PLUGIN_ROOT/scripts/run-$gone_provider.sh" ] || fail "run-$gone_provider.sh is removed"
pass 'dropped provider has no runner'

# --- run-vibe.sh against a stub vibe (stream and export shapes of vibe 3.1.3) ---
mmo_ensure_vibe_stub

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
[ "$(grep -Fx -A1 -- '--max-price' "$VB/calls/call.2.args" | sed -n 2p)" = '0' ] \
  || fail 'vibe review caps price at 0 immediately after --max-price'
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
[ "$(grep -Fx -A1 -- '--max-price' "$VB/calls/call.3.args" | sed -n 2p)" = '0' ] \
  || fail 'vibe advise caps price at 0 immediately after --max-price'
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

