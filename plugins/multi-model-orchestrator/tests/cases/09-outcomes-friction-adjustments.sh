#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

mmo_ensure_outcome_repo
[ -f "$WORK/grok-old.request" ] || printf 'implement thing\n' > "$WORK/grok-old.request"

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
outcome_row() {
  local file="$1" provider="$2" expected_rc="$3"
  [ -f "$file" ] && awk -F '\t' -v p="$provider" -v rc="$expected_rc" '
    NR == 1 { if (NF != 13 || $1 != "utc_time" || $12 != "head_sha" || $13 != "verdict") exit 1 }
    NR == 2 { if (NF != 13 || $1 !~ /^[0-9][0-9][0-9][0-9]-.*Z$/ || $2 != "project" || $3 != "" || $4 != "implement" || $5 != p || $9 != rc || $10 !~ /^[0-9]+$/) exit 1 }
    END { if (NR != 2) exit 1 }
  ' "$file"
}
for provider in codex claude grok agy muse qwen; do
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
# T2 uses another model: since #740 the pool never retries the failed provider/model.
printf 'T1\tagy\tgemini-3.8-flash\tlow\nT2\tagy\tgemini-4-argon\thigh\n' > "$OUTCOMES/tiers.tsv"
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

# --- friction-report.sh: recurring friction per provider/model/effort/role from both records ---
FR="$WORK/friction"; mkdir -p "$FR"
FRICTION="$PLUGIN_ROOT/scripts/friction-report.sh"
fr_new="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
fr_mid="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
fr_old="$(date -u -d '-40 days' +%Y-%m-%dT%H:%M:%SZ)"
fr_o() {  # fr_o TIME ROLE PROVIDER REQUESTED SERVED EFFORT EXIT
  printf '%s\towner/app\tT2\t%s\t%s\t%s\t%s\t%s\t%s\t10\t\t\t\n' "$@"
}
fr_c() {  # fr_c TIME PROVIDER MODEL EFFORT CHECK DETAIL
  printf '%s\towner/app\t1\t0\tT2\t%s\t%s\t%s\t%s\t%s\tabc\t1\t5\n' "$@"
}
{
  printf 'utc_time\trepo\ttier\trole\tprovider\trequested_model\tserved_model\teffort\texit_code\tduration_seconds\ttokens\thead_sha\tverdict\n'
  fr_o "$fr_mid" review grok grok-4.7 '' high 124
  for rc in 124 124 0 7 6 5 75 77 127 2 129 42; do fr_o "$fr_new" review grok grok-4.7 '' high "$rc"; done
  fr_o "$fr_old" review grok grok-4.7 '' high 124
  fr_o "$fr_new" implement codex gpt-6.2-astra '' medium 1
  fr_o "$fr_new" implement codex gpt-6.2-astra '' medium 1
  fr_o "$fr_new" implement codex gpt-6.2-astra '' medium 0
  fr_o "$fr_new" implement claude sonnet claude-sonnet-5-5 medium 78
  fr_o "$fr_new" gate '' '' '' '' 6
  fr_o "$fr_new" review '' '' '' '' 124
} > "$FR/outcomes.tsv"
{
  printf 'utc_time\trepo\ttask\tcycle\ttier\tprovider\tmodel\teffort\tcheck\tdetail\thead_sha\tchanged_paths\tduration_seconds\n'
  fr_c "$fr_new" grok grok-4.7 high scope src/x
  fr_c "$fr_new" grok grok-4.7 high verify verify-exit=1
  fr_c "$fr_new" grok grok-4.7 high no_change ''
  fr_c "$fr_new" grok grok-4.7 high pass asks-to-continue
  fr_c "$fr_new" grok grok-4.7 high pass ''
  fr_c "$fr_old" grok grok-4.7 high scope src/y
  fr_c "$fr_new" '' '' '' scope src/z
} > "$FR/checks.tsv"
fr_rc() {  # fr_rc WANT OUTFILE ARGS...
  local want="$1" out="$2" got=0; shift 2
  bash "$FRICTION" "$@" >"$out" 2>"$FR/err" || got=$?
  [ "$got" -eq "$want" ] || fail "friction-report want $want got $got: $* -- $(cat "$FR/err")"
}
fr_header=$'provider\tmodel\teffort\trole\tkind\tcount\tlegs\trate_pct\tfirst_seen\tlast_seen\tflag'
fr_rc 0 "$FR/all" --outcomes "$FR/outcomes.tsv" --checks "$FR/checks.tsv"
[ "$(head -n 1 "$FR/all")" = "$fr_header" ] || fail 'friction report prints its header first'
g=$'grok\tgrok-4.7\thigh'
exact_line "$FR/all" "$g"$'\treview\ttimeout\t3\t8\t37.5\t'"$fr_mid"$'\t'"$fr_new"$'\tyes' 'timeouts in the window flag (count 3 of 8 runner exits; the 40-day-old row is out)'
for kind in guard_failed no_verdict empty_output exit_42; do
  exact_line "$FR/all" "$g"$'\treview\t'"$kind"$'\t1\t8\t12.5\t'"$fr_new"$'\t'"$fr_new"$'\tno' "friction kind $kind counted against runner exits"
done
for kind in unavailable auth cli_missing usage interrupted; do
  exact_line "$FR/all" "$g"$'\treview\t'"$kind"$'\t1\t13\t7.7\t'"$fr_new"$'\t'"$fr_new"$'\tinfo' "availability/usage kind $kind is informational over all exits"
done
exact_line "$FR/all" $'codex\tgpt-6.2-astra\tmedium\timplement\tprovider_error\t2\t3\t66.7\t'"$fr_new"$'\t'"$fr_new"$'\tno' 'provider errors below --min-count do not flag'
exact_line "$FR/all" $'claude\tclaude-sonnet-5-5\tmedium\timplement\tbudget_exhausted\t1\t1\t100.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' 'served model replaces the requested alias; 78 is an exhausted budget'
for kind in scope verify no_change asks-to-continue; do
  exact_line "$FR/all" "$g"$'\timplement\t'"$kind"$'\t1\t5\t20.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' "check kind $kind counted against the group's checks"
done
[ "$(wc -l < "$FR/all")" -eq 17 ] || fail "friction report row count $(wc -l < "$FR/all") want 17 (gate, provider-less and old rows left out)"
absent "$FR/all" 'gate' 'gate rows are left out'
awk -F '\t' 'NR > 2 && $8 + 0 > prev + 0 {exit 1} NR > 1 {prev = $8}' "$FR/all" || fail 'friction report sorts by rate descending'
fr_rc 0 "$FR/flags" --flags-only --outcomes "$FR/outcomes.tsv" --checks "$FR/checks.tsv"
[ "$(cat "$FR/flags")" = "$fr_header"$'\n'"$g"$'\treview\ttimeout\t3\t8\t37.5\t'"$fr_mid"$'\t'"$fr_new"$'\tyes' ] \
  || fail '--flags-only keeps the header and the flagged row only'
fr_rc 0 "$FR/low" --flags-only --min-count 1 --min-rate 20 --outcomes "$FR/outcomes.tsv" --checks "$FR/checks.tsv"
[ "$(awk 'END {print NR}' "$FR/low")" -eq 8 ] || fail '--min-count 1 --min-rate 20 flags timeout, provider_error, budget_exhausted and the four check kinds'
contains "$FR/low" $'provider_error\t2\t3\t66.7' '--min-count 1 flags the provider errors'
absent "$FR/low" 'guard_failed' '--min-rate 20 leaves a 12.5% kind unflagged'
fr_rc 0 "$FR/high" --flags-only --min-rate 50 --outcomes "$FR/outcomes.tsv" --checks "$FR/checks.tsv"
[ "$(cat "$FR/high")" = "$fr_header" ] || fail '--min-rate 50 leaves the 37.5% timeouts unflagged'
fr_rc 0 "$FR/window" --days 2 --outcomes "$FR/outcomes.tsv" --checks "$FR/checks.tsv"
exact_line "$FR/window" "$g"$'\treview\ttimeout\t2\t7\t28.6\t'"$fr_new"$'\t'"$fr_new"$'\tno' '--days 2 drops the 3-day-old row'
fr_rc 0 "$FR/wide" --days 60 --outcomes "$FR/outcomes.tsv" --checks "$FR/checks.tsv"
exact_line "$FR/wide" "$g"$'\treview\ttimeout\t4\t9\t44.4\t'"$fr_old"$'\t'"$fr_new"$'\tyes' '--days 60 keeps the 40-day-old row'
exact_line "$FR/wide" "$g"$'\timplement\tscope\t2\t6\t33.3\t'"$fr_old"$'\t'"$fr_new"$'\tno' '--days 60 keeps the old check row'
{ head -n 1 "$FR/outcomes.tsv"; fr_o "$fr_new" review grok grok-4.7 '' high 124; } > "$FR/outcomes-b.tsv"
fr_rc 0 "$FR/combined" --outcomes "$FR/outcomes.tsv" --outcomes "$FR/outcomes-b.tsv" --outcomes "$FR/missing.tsv" --checks "$FR/checks.tsv" --checks "$FR/missing-checks.tsv"
exact_line "$FR/combined" "$g"$'\treview\ttimeout\t4\t9\t44.4\t'"$fr_mid"$'\t'"$fr_new"$'\tyes' 'several outcome files combine; missing files are skipped'
exact_line "$FR/combined" "$g"$'\timplement\tscope\t1\t5\t20.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' 'check rows still counted once with a missing check file beside them'
MMO_OUTCOMES_FILE="$FR/outcomes.tsv" MMO_LEG_CHECKS_FILE="$FR/checks.tsv" fr_rc 0 "$FR/env"
cmp -s "$FR/all" "$FR/env" || fail 'friction report reads MMO_OUTCOMES_FILE and MMO_LEG_CHECKS_FILE by default'
fr_rc 0 "$FR/empty" --outcomes "$FR/missing.tsv" --checks "$FR/missing-checks.tsv"
[ "$(cat "$FR/empty")" = "$fr_header" ] || fail 'an empty report is the header alone, exit 0'
for bad in '--days 0' '--days x' '--min-count 0' '--min-rate 101' '--min-rate -1' '--bogus' '--days' '--outcomes'; do
  # shellcheck disable=SC2086
  fr_rc 2 "$FR/usage" $bad
  [ ! -s "$FR/usage" ] || fail "usage error $bad prints no report"
done
# Fix 2: the flag uses exact arithmetic; 62/207 = 29.95% displays 30.0 but is below 30.
{ head -n 1 "$FR/outcomes.tsv"
  for _ in $(seq 62); do fr_o "$fr_new" review muse muse-spark-1.3 '' medium 124; done
  for _ in $(seq 145); do fr_o "$fr_new" review muse muse-spark-1.3 '' medium 0; done; } > "$FR/round.tsv"
fr_rc 0 "$FR/round" --outcomes "$FR/round.tsv" --checks "$FR/missing-checks.tsv"
exact_line "$FR/round" $'muse\tmuse-spark-1.3\tmedium\treview\ttimeout\t62\t207\t30.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' '29.95% rounds to 30.0 for display but does not flag at 30'
fr_rc 0 "$FR/round" --min-rate 29 --outcomes "$FR/round.tsv" --checks "$FR/missing-checks.tsv"
contains "$FR/round" $'\t62\t207\t30.0\t' '62/207 is present'
exact_line "$FR/round" $'muse\tmuse-spark-1.3\tmedium\treview\ttimeout\t62\t207\t30.0\t'"$fr_new"$'\t'"$fr_new"$'\tyes' '29.95% flags at 29'
# Fixes 1, 3, 4, 7: evidence-faithful kinds, malformed/future timestamps, unknown check results,
# control characters, and the asks-to-continue note read only from pass/no_change rows.
fr_future="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
{ head -n 1 "$FR/outcomes.tsv"
  fr_o "$fr_new" review codex gpt-x '' medium 124
  fr_o '2026-11-19 10:00:00' review codex gpt-x '' medium 124
  fr_o 'yesterday' review codex gpt-x '' medium 124
  fr_o "$fr_future" review codex gpt-x '' medium 124
  fr_o "$fr_new" review codex $'gpt-\x1cx' '' medium 6
  fr_o "$fr_new" implement qwen default '' n/a 55; } > "$FR/v-outcomes.tsv"
{ head -n 1 "$FR/checks.tsv"
  fr_c "$fr_new" grok grok-4.7 high scope asks-to-continue
  fr_c "$fr_new" grok grok-4.7 high pass ''
  fr_c "$fr_new" grok grok-4.7 high no_change asks-to-continue
  fr_c "$fr_new" grok grok-4.7 high '' ''
  fr_c "$fr_new" grok grok-4.7 high weird asks-to-continue; } > "$FR/v-checks.tsv"
fr_rc 0 "$FR/valid" --outcomes "$FR/v-outcomes.tsv" --checks "$FR/v-checks.tsv"
exact_line "$FR/valid" $'codex\tgpt-x\tmedium\treview\ttimeout\t1\t2\t50.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' 'malformed and future timestamps are not counted or last_seen'
exact_line "$FR/valid" $'codex\tgpt-x\tmedium\treview\tno_verdict\t1\t2\t50.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' 'a 0x1c byte in a field is dropped, not a column break'
exact_line "$FR/valid" $'qwen\tdefault\tn/a\timplement\tbudget_exhausted\t1\t1\t100.0\t'"$fr_new"$'\t'"$fr_new"$'\tno' 'Qwen 55 (wall-time budget) is budget_exhausted'
for kind in scope no_change asks-to-continue; do
  exact_line "$FR/valid" $'grok\tgrok-4.7\thigh\timplement\t'"$kind"$'\t1\t3\t33.3\t'"$fr_new"$'\t'"$fr_new"$'\tno' "$kind over 3 checks: unknown results are not legs, a scope path named asks-to-continue is not the note"
done
[ "$(wc -l < "$FR/valid")" -eq 7 ] || fail "validated report has $(wc -l < "$FR/valid") lines, want 7"
awk -F '\t' 'NF != 11 {exit 1}' "$FR/valid" || fail 'every report line has 11 columns'
! grep -E 'readonly_write|step_cap' "$FR/all" "$FR/valid" >/dev/null || fail 'kinds no longer claim a write or a step cap'
pass 'friction-report kinds, thresholds, window, combined inputs and usage errors'

# --- harness-adjustments.tsv: provider prompt lines with evidence, matched by provider, model glob and mode ---
mmo_adjustment_rows check 2>"$FR/adj.err" || fail "shipped harness-adjustments.tsv is malformed: $(cat "$FR/adj.err")"
[ "$(grep -vc -E '^[[:space:]]*(#|$)' "$PLUGIN_ROOT/scripts/harness-adjustments.tsv")" -eq 2 ] \
  || fail 'harness-adjustments.tsv holds exactly the seeded Grok rows'
case "$(mmo_adjustment_lines grok grok-4.7 review 9 300)" in 'Your wall-clock limit is 300 seconds:'*) ;; *) fail 'the shipped Grok 4.7 review row answers its short-timeout friction' ;; esac
[ -z "$(mmo_adjustment_lines grok grok-4.7 review 9 2>"$FR/adj.err")" ] && [ ! -s "$FR/adj.err" ] \
  || fail 'the shipped Grok 4.7 short-review row stays out of a default-timeout review, silently'
for provider in claude codex grok muse agy vibe qwen; do
  for adj_mode in implement review research advise; do
    out="$(mmo_adjustment_lines "$provider" any-model "$adj_mode" 9)"
    if [ "$provider/$adj_mode" = grok/implement ]; then
      [ "$out" = 'You have at most 9 agent turns: make the edits early, keep dev-server, screenshot and exploration loops short, and leave room to run the named test and write your final message.' ] \
        || fail 'the shipped Grok row fills {budget}'
    else
      [ -z "$out" ] || fail "shipped table adds a line to $provider $adj_mode prompts: $out"
    fi
  done
done
printf '%s\n' '# comment' '' \
  $'grok\tgrok-4.*\treview\tR1\thttps://example.invalid/1\t2026-11-01' \
  $'grok\tgrok-4.7\timplement\tI1 {budget}\tdated observation 2026-11-01\t2026-11-01' \
  $'codex\t*\t*\tALL\tfriction-report row codex * * timeout\t2026-11-01' \
  $'claude\tclaude-opus-*\tadvise\tA1\tev\t2026-11-01' > "$FR/adj.tsv"
adj() { MMO_HARNESS_ADJUSTMENTS="$FR/adj.tsv" mmo_adjustment_lines "$@" 2>"$FR/adj.err"; }
[ "$(adj grok grok-4.6 review)" = R1 ] || fail 'model glob grok-4.* matches grok-4.6'
[ -z "$(adj grok grok-4.6 implement)" ] || fail 'an exact model id does not match another model'
[ "$(adj grok grok-4.7 implement 7)" = 'I1 7' ] || fail 'exact model id and mode match; {budget} filled'
[ -z "$(adj grok grok-4.7 advise)" ] || fail 'a mode-specific row does not match another mode'
[ "$(adj codex gpt-6.2-astra research)" = ALL ] && [ "$(adj codex default implement)" = ALL ] || fail 'mode * matches every mode'
[ "$(adj claude claude-opus-5-5 advise)" = A1 ] || fail 'claude glob row matches advise'
[ -z "$(adj claude claude-sonnet-5-5 advise)" ] && [ -z "$(adj muse muse-spark-1.3 implement)" ] || fail 'no matching row adds no line'
[ ! -s "$FR/adj.err" ] || fail "a valid table prints no warning: $(cat "$FR/adj.err")"
[ "$(cd "$WORK" && mmo_outcome_provider=codex model=gpt-6.2-astra MMO_HARNESS_ADJUSTMENTS="$FR/adj.tsv" mmo_implement_prompt "$WORK/grok-old.request" | sed -n 3p)" = ALL ] \
  || fail 'mmo_implement_prompt adds the matching rows after the scope line'
for bad_row in $'grok\t*\timplement\tL\tev' $'grok\t*\tprobe\tL\tev\t2026-11-01' $'grok\t*\timplement\tL\t\t2026-11-01' \
  $'grok\t*\timplement\tL\t \t2026-11-01' $'grok\t*\timplement\tL\tev\t2026-13-01' $'grok\t*\timplement\tL\tev\t11/20/2026' \
  $'grok\t*\timplement\tL\tev\t2026-11-01\textra'; do
  { cat "$FR/adj.tsv"; printf '%s\n' "$bad_row"; } > "$FR/adj-bad.tsv"
  ! MMO_HARNESS_ADJUSTMENTS="$FR/adj-bad.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check accepts malformed row: ${bad_row//$'\t'/|}"
  contains "$FR/adj.err" 'adj-bad.tsv:7:' "check names the malformed row's line: ${bad_row//$'\t'/|}"
  [ "$(MMO_HARNESS_ADJUSTMENTS="$FR/adj-bad.tsv" mmo_adjustment_lines grok grok-4.7 implement 7 2>"$FR/adj.err")" = 'I1 7' ] \
    || fail "runtime skips the malformed row and keeps the valid ones: ${bad_row//$'\t'/|}"
  contains "$FR/adj.err" 'adj-bad.tsv:7:' 'runtime warns about the skipped row'
done
contains "$FR/adj.err" 'want 6 tab-separated columns, got 7' 'column count is named'
printf '%s\n' $'grok\t*\timplement\tL\t\t2026-11-01' > "$FR/adj-ev.tsv"
! MMO_HARNESS_ADJUSTMENTS="$FR/adj-ev.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail 'missing evidence is rejected'
contains "$FR/adj.err" 'missing evidence' 'missing evidence is named'
printf '%s\t*\timplement\tL\tev\t2026-11-01\n' "$gone_provider" > "$FR/adj-gone.tsv"
! MMO_HARNESS_ADJUSTMENTS="$FR/adj-gone.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "a $gone_provider adjustment row is rejected"
contains "$FR/adj.err" "no runner $gone_provider takes mode implement" "the dropped provider has no runner for adjustments"
# Fix 6: {budget} is the leg's own cap, passed by the runner (Muse: --max-steps); no budget skips the line loudly.
printf '%s\n' $'muse\t*\timplement\tAt most {budget} steps.\tev\t2026-11-01' $'claude\t*\treview\tAt most {budget} turns.\tev\t2026-11-01' > "$FR/adj-budget.tsv"
mkdir -p "$FR/muse-calls"
printf 'budget task\n' | "${muse_env[@]}" STUB_MUSE_CALLS="$FR/muse-calls" MMO_HARNESS_ADJUSTMENTS="$FR/adj-budget.tsv" \
  bash "$MUSE_RUN" --mode implement --repo "$MR" --max-steps 7 --timeout 30 >/dev/null 2>"$FR/muse.err" || fail "run-muse budget leg: $(cat "$FR/muse.err")"
exact_line "$FR/muse-calls/call.0.prompt" 'At most 7 steps.' 'Muse renders {budget} from --max-steps'
[ -z "$(MMO_HARNESS_ADJUSTMENTS="$FR/adj-budget.tsv" mmo_adjustment_lines claude claude-opus-5-5 review '' 2>"$FR/adj.err")" ] \
  || fail 'a {budget} line is skipped when the leg has no budget'
contains "$FR/adj.err" 'has no turn or step budget' 'skipping a {budget} line warns'
for bad_row in $'codex\t*\timplement\tAt most {budget} turns.\tev\t2026-11-01' $'qwen\t*\treview\t{budget}\tev\t2026-11-01'; do
  printf '%s\n' "$bad_row" > "$FR/adj-nobudget.tsv"
  ! MMO_HARNESS_ADJUSTMENTS="$FR/adj-nobudget.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check accepts {budget} without a budget: ${bad_row//$'\t'/|}"
  contains "$FR/adj.err" 'has no turn or step budget for {budget}' 'the missing budget is named'
done
# A {timeout} row reaches only a Grok leg whose --timeout is below the 1200 s default.
for t in 300 1200; do
  printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD \
    --model grok-4.7 --effort high --timeout "$t" >/dev/null 2>"$FR/grok-t.err" || fail "run-grok review --timeout $t: $(cat "$FR/grok-t.err")"
  if [ "$t" = 300 ]; then
    grep -qF 'Your wall-clock limit is 300 seconds:' "$STUB_GROK_PROMPT" || fail 'a 300 s Grok 4.7 review gets the short-review line'
  else
    ! grep -qF 'Your wall-clock limit' "$STUB_GROK_PROMPT" || fail 'a default-timeout high-effort Grok 4.7 review omits the short-review line'
  fi
done
for bad_row in $'codex\t*\treview\tWithin {timeout} s.\tev\t2026-11-01' $'grok\t*\tresearch\tWithin {timeout} s.\tev\t2026-11-01'; do
  printf '%s\n' "$bad_row" > "$FR/adj-notimeout.tsv"
  ! MMO_HARNESS_ADJUSTMENTS="$FR/adj-notimeout.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check accepts {timeout} for a leg that passes none: ${bad_row//$'\t'/|}"
  contains "$FR/adj.err" 'passes no short timeout for {timeout}' 'the leg without {timeout} is named'
done
printf '%s\n' $'grok\t*\t*\tWithin {timeout} s.\tev\t2026-11-01' > "$FR/adj-timeout-any.tsv"
MMO_HARNESS_ADJUSTMENTS="$FR/adj-timeout-any.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check rejects a Grok * {timeout} row: $(cat "$FR/adj.err")"
# Fix 5: a row for a mode its runner does not take (or an unknown runner) can never apply.
for bad_row in $'codex\t*\tadvise\tL\tev\t2026-11-01' $'qwen\t*\tresearch\tL\tev\t2026-11-01' $'agy\t*\tadvise\tL\tev\t2026-11-01' $'grokk\t*\t*\tL\tev\t2026-11-01'; do
  printf '%s\n' "$bad_row" > "$FR/adj-mode.tsv"
  ! MMO_HARNESS_ADJUSTMENTS="$FR/adj-mode.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check accepts a row no runner takes: ${bad_row//$'\t'/|}"
  contains "$FR/adj.err" 'no runner' 'the unsupported runner/mode is named'
done
# Fix 8: as_of must be a calendar date.
for bad_date in 2026-02-31 2027-02-29 2026-04-31; do
  printf '%s\n' $'grok\t*\timplement\tL\tev\t'"$bad_date" > "$FR/adj-date.tsv"
  ! MMO_HARNESS_ADJUSTMENTS="$FR/adj-date.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check accepts $bad_date"
  contains "$FR/adj.err" 'is not a calendar date' "$bad_date is named as no calendar date"
done
printf '%s\n' $'grok\t*\timplement\tL\tev\t2028-02-29' $'grok\t*\timplement\tL\tev\t2000-02-29' > "$FR/adj-date.tsv"
MMO_HARNESS_ADJUSTMENTS="$FR/adj-date.tsv" mmo_adjustment_rows check 2>"$FR/adj.err" || fail "check rejects a leap day: $(cat "$FR/adj.err")"
pass 'harness adjustments: matching, {budget}, runner modes, calendar dates, shipped table, malformed rows rejected'

