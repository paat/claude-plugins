# Sourced by run-tests.sh — reliability floor (#197): disk preflight + auto-prune,
# poll-gate.sh backoff probe, check-stop circuit breaker, check-idle.sh removed.
# Uses the harness assert_* helpers and make_workdir.
test_reliability_floor() {
  echo -e "\n${CYAN}Suite: reliability floor (#197)${NC}"
  local preflight="$PLUGIN_ROOT/scripts/health-preflight.sh"
  local pollgate="$PLUGIN_ROOT/scripts/poll-gate.sh"
  local checkstop="$PLUGIN_ROOT/scripts/check-stop.sh"
  local wd bindir ec out status

  # --- check-idle.sh is gone (dead code removed; idle handling is the host's) ---
  assert_file_not_exists "RF0: check-idle.sh removed" "$PLUGIN_ROOT/scripts/check-idle.sh"
  assert_file_exists "RF0b: poll-gate.sh present" "$pollgate"

  # Mock df on PATH: emits a POSIX table whose Available column (KB) is picked by
  # a call counter so we can simulate space freed by a prune. DF_FREE_BEFORE for
  # calls < DF_FLIP_AT, DF_FREE_AFTER from DF_FLIP_AT onward.
  install_mock_df() {
    bindir="$1/bin"; mkdir -p "$bindir"
    cat > "$bindir/df" <<'EOF'
#!/bin/bash
CNT="${DF_COUNT_FILE:-/dev/null}"
n=0; [ -f "$CNT" ] && n=$(cat "$CNT" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$CNT" 2>/dev/null || true
if [ "$n" -ge "${DF_FLIP_AT:-999999}" ]; then free="${DF_FREE_AFTER:-5242880}"; else free="${DF_FREE_BEFORE:-5242880}"; fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/sda1 104857600 1 $free 1% /"
EOF
    chmod +x "$bindir/df"
  }
  disk_status() {  # $1=workdir → prints the disk:free check status from --json
    out=$(PATH="$bindir:$PATH" bash "$preflight" --json "$@" \
          --repo-root "$wd" --plugin-root "$PLUGIN_ROOT" 2>/dev/null)
    printf '%s' "$out" | jq -r '.checks[] | select(.check=="disk:free") | .status'
  }

  # RF1: free well above threshold → ok
  wd="$(make_workdir)"; install_mock_df "$wd"
  status=$(DF_COUNT_FILE="$wd/c1" DF_FREE_BEFORE=5242880 SAAS_MIN_FREE_GB=2 disk_status)
  assert_equals "RF1: 5GB free (min 2) → ok" "$status" "ok"

  # RF2: free below threshold, no --self-repair → blocker
  wd="$(make_workdir)"; install_mock_df "$wd"
  status=$(DF_COUNT_FILE="$wd/c2" DF_FREE_BEFORE=1048576 SAAS_MIN_FREE_GB=2 disk_status)
  assert_equals "RF2: 1GB free (min 2) → blocker" "$status" "blocker"

  # RF3: below threshold, --self-repair, prune frees space (df flips) → auto-fixed
  wd="$(make_workdir)"; install_mock_df "$wd"
  status=$(DF_COUNT_FILE="$wd/c3" DF_FREE_BEFORE=1048576 DF_FREE_AFTER=5242880 DF_FLIP_AT=2 \
           SAAS_MIN_FREE_GB=2 disk_status --self-repair)
  assert_equals "RF3: self-repair frees space → auto-fixed" "$status" "auto-fixed"

  # RF4: below threshold, --self-repair, prune does not help → still blocker
  wd="$(make_workdir)"; install_mock_df "$wd"
  status=$(DF_COUNT_FILE="$wd/c4" DF_FREE_BEFORE=1048576 SAAS_MIN_FREE_GB=2 disk_status --self-repair)
  assert_equals "RF4: self-repair can't free enough → blocker" "$status" "blocker"

  # Mock gh on PATH: emits canned stdout/stderr/exit from env so poll-gate can be
  # exercised without a network.
  install_mock_gh() {
    bindir="$1/bin"; mkdir -p "$bindir"
    cat > "$bindir/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_STDERR:-}" ] && printf '%s\n' "$GH_STDERR" >&2
[ -n "${GH_STDOUT:-}" ] && printf '%s' "$GH_STDOUT"
exit "${GH_EXIT:-0}"
EOF
    chmod +x "$bindir/gh"
  }
  probe() { PATH="$bindir:$PATH" bash "$pollgate" "$@"; }

  wd="$(make_workdir)"; install_mock_gh "$wd"

  # RF5: all checks pass (pass + skipping) → green
  ec=0; out=$(GH_STDOUT='[{"bucket":"pass"},{"bucket":"skipping"}]' probe --pr 1) || ec=$?
  assert_equals "RF5: PR all-pass → green" "$out" "green"; assert_exit_code "RF5b: green exit 0" "$ec" 0

  # RF6: any failed → red
  ec=0; out=$(GH_STDOUT='[{"bucket":"pass"},{"bucket":"fail"}]' probe --pr 1) || ec=$?
  assert_equals "RF6: PR any-fail → red" "$out" "red"; assert_exit_code "RF6b: red exit 0" "$ec" 0

  # RF7: any in-progress → pending
  ec=0; out=$(GH_STDOUT='[{"bucket":"pass"},{"bucket":"pending"}]' probe --pr 1) || ec=$?
  assert_equals "RF7: PR in-progress → pending" "$out" "pending"; assert_exit_code "RF7b: pending exit 0" "$ec" 0

  # RF7c: unrecognized/missing bucket never reads green (whitelist, review fix)
  ec=0; out=$(GH_STDOUT='[{"bucket":"pass"},{"bucket":"unknown"}]' probe --pr 1) || ec=$?
  assert_equals "RF7c: unknown bucket → pending" "$out" "pending"
  ec=0; out=$(GH_STDOUT='[{}]' probe --pr 1) || ec=$?
  assert_equals "RF7d: missing bucket → pending" "$out" "pending"
  ec=0; out=$(GH_STDOUT='[{"bucket":"skipping"}]' probe --pr 1) || ec=$?
  assert_equals "RF7e: all-skipping, no real pass → pending" "$out" "pending"

  # RF8: empty check array → pending (no CI is never green)
  ec=0; out=$(GH_STDOUT='[]' probe --pr 1) || ec=$?
  assert_equals "RF8: PR no checks (empty) → pending" "$out" "pending"; assert_exit_code "RF8b: exit 0" "$ec" 0

  # RF9: gh 'no checks reported' (exit 1, stderr) → pending, exit 0
  ec=0; out=$(GH_STDOUT='' GH_STDERR='no checks reported on the main branch' GH_EXIT=1 probe --pr 1) || ec=$?
  assert_equals "RF9: 'no checks reported' → pending" "$out" "pending"; assert_exit_code "RF9b: exit 0" "$ec" 0

  # RF10: gh error (auth/network) → fail-closed pending, exit 3
  ec=0; out=$(GH_STDOUT='' GH_STDERR='error: could not connect' GH_EXIT=1 probe --pr 1) || ec=$?
  assert_equals "RF10: gh error → pending (fail-closed)" "$out" "pending"; assert_exit_code "RF10b: gh error exit 3" "$ec" 3

  # RF11: run mode — completed+success → green
  ec=0; out=$(GH_STDOUT='{"status":"completed","conclusion":"success"}' probe --run 9) || ec=$?
  assert_equals "RF11: run success → green" "$out" "green"; assert_exit_code "RF11b: exit 0" "$ec" 0

  # RF12: run completed+failure → red
  ec=0; out=$(GH_STDOUT='{"status":"completed","conclusion":"failure"}' probe --run 9) || ec=$?
  assert_equals "RF12: run failure → red" "$out" "red"

  # RF13: run still in progress → pending
  ec=0; out=$(GH_STDOUT='{"status":"in_progress","conclusion":null}' probe --run 9) || ec=$?
  assert_equals "RF13: run in-progress → pending" "$out" "pending"

  # RF14: run gh error → pending, exit 3
  ec=0; out=$(GH_STDOUT='' GH_EXIT=1 probe --run 9) || ec=$?
  assert_equals "RF14: run gh error → pending" "$out" "pending"; assert_exit_code "RF14b: exit 3" "$ec" 3

  # RF15: usage errors → exit 2
  ec=0; out=$(probe 2>/dev/null) || ec=$?; assert_exit_code "RF15: no args → exit 2" "$ec" 2
  ec=0; out=$(probe --pr 2>/dev/null) || ec=$?; assert_exit_code "RF15b: --pr without value → exit 2" "$ec" 2
  ec=0; out=$(probe --pr 1 --workflow deploy 2>/dev/null) || ec=$?
  assert_exit_code "RF15c: --workflow outside --deploy-sha → exit 2" "$ec" 2

  # deploy-sha mode: the watch is bound to the exact merge commit (#248) — an
  # unrelated latest run must never determine the delivery outcome.
  sha="1111111111111111111111111111111111111111"
  # RF15d: only an unrelated newer successful run exists → pending, not green
  ec=0; out=$(GH_STDOUT='[{"databaseId":9,"headSha":"2222222222222222222222222222222222222222","status":"completed","conclusion":"success"}]' probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15d: unrelated success is not our green" "$out" "pending"; assert_exit_code "RF15d2: exit 0" "$ec" 0
  # RF15e: matching run still pending while unrelated is green → pending
  ec=0; out=$(GH_STDOUT='[{"databaseId":9,"headSha":"2222222222222222222222222222222222222222","status":"completed","conclusion":"success"},{"databaseId":8,"headSha":"1111111111111111111111111111111111111111","status":"in_progress","conclusion":null}]' probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15e: matching in-progress → pending" "$out" "pending"
  # RF15f: matching run failed while unrelated is green → red
  ec=0; out=$(GH_STDOUT='[{"databaseId":9,"headSha":"2222222222222222222222222222222222222222","status":"completed","conclusion":"success"},{"databaseId":8,"headSha":"1111111111111111111111111111111111111111","status":"completed","conclusion":"failure"}]' probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15f: matching failure → red" "$out" "red"
  # RF15g: matching run succeeded → green (unrelated failure is ignored)
  ec=0; out=$(GH_STDOUT='[{"databaseId":9,"headSha":"2222222222222222222222222222222222222222","status":"completed","conclusion":"failure"},{"databaseId":8,"headSha":"1111111111111111111111111111111111111111","status":"completed","conclusion":"success"}]' probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15g: matching success → green" "$out" "green"
  # RF15h: no runs at all yet → pending (never falls back to latest)
  ec=0; out=$(GH_STDOUT='[]' probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15h: no matching run yet → pending" "$out" "pending"; assert_exit_code "RF15h2: exit 0" "$ec" 0
  # RF15i: all matching runs skipped, no real success → pending, not green
  ec=0; out=$(GH_STDOUT='[{"databaseId":8,"headSha":"1111111111111111111111111111111111111111","status":"completed","conclusion":"skipped"}]' probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15i: skipped-only → pending" "$out" "pending"
  # RF15j: gh error → fail-closed pending, exit 3
  ec=0; out=$(GH_STDOUT='' GH_EXIT=1 probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15j: gh error → pending" "$out" "pending"; assert_exit_code "RF15j2: exit 3" "$ec" 3
  # RF15k: gh nonzero exit with plausible JSON still fails closed
  ec=0; out=$(GH_STDOUT='[{"databaseId":8,"headSha":"1111111111111111111111111111111111111111","status":"completed","conclusion":"success"}]' GH_EXIT=1 probe --deploy-sha "$sha") || ec=$?
  assert_equals "RF15k: gh error with JSON → pending" "$out" "pending"; assert_exit_code "RF15k2: exit 3" "$ec" 3

  # --- check-stop.sh circuit breaker ---
  # RF16: 25 identical-state blocks opens the breaker (allow stop) with a message.
  wd="$(make_workdir)"
  (cd "$wd" && git init -q && mkdir -p .startup/go-live .startup/handoffs)
  echo '{"iteration": 3, "phase": "implementation"}' > "$wd/.startup/state.json"
  local i
  for i in $(seq 1 24); do (cd "$wd" && bash "$checkstop" < /dev/null) >/dev/null 2>&1 || true; done
  ec=0; out=$( (cd "$wd" && bash "$checkstop" < /dev/null) 2>&1 ) || ec=$?
  assert_exit_code "RF16: 25th identical block opens breaker (allow stop)" "$ec" 0
  assert_output_contains "RF16b: breaker announces itself" "$out" "circuit breaker"

  # RF17: a state change resets the consecutive-block counter (still blocks, count=1).
  wd="$(make_workdir)"
  (cd "$wd" && git init -q && mkdir -p .startup/go-live .startup/handoffs)
  echo '{"iteration": 3, "phase": "implementation"}' > "$wd/.startup/state.json"
  for i in 1 2 3 4 5; do (cd "$wd" && bash "$checkstop" < /dev/null) >/dev/null 2>&1 || true; done
  # change the fingerprint (handoff count) → counter must reset
  echo "h" > "$wd/.startup/handoffs/001-business-to-tech.md"
  ec=0; (cd "$wd" && bash "$checkstop" < /dev/null) >/dev/null 2>&1 || ec=$?
  assert_exit_code "RF17: state change → still blocks (not near 25)" "$ec" 2
  local n
  n=$(sed -n '2p' "$wd/.startup/.stop-block-count" 2>/dev/null || echo X)
  assert_equals "RF17b: counter reset to 1 on fingerprint change" "$n" "1"
}
test_reliability_floor
