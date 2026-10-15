# Extracted monitor engine and nightly workflow regressions.
# ---------------------------------------------------------------------------
# Suite W: monitor-dedup.sh
# ---------------------------------------------------------------------------

test_monitor_dedup() {
  echo -e "\n${CYAN}Suite W: monitor-dedup.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/monitor-dedup.sh"
  local workdir ec output state mins

  # W1: first run (no state) → 1440-minute window, exit 0
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W1: window first-run exits 0" "$ec" 0
  assert_output_contains "W1: first-run window is 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  # W2: recent last_run_at (30m ago) → window between 1 and 60
  workdir=$(make_workdir); state="$workdir/state.json"
  printf '{"version":1,"last_run_at":"%s","patterns":{}}' "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$state" 2>&1) || ec=$?
  mins=$(printf '%s\n' "$output" | sed -n 's/^MONITOR_SINCE_MINUTES=//p')
  assert_exit_code "W2: window exits 0" "$ec" 0
  assert_equals "W2: ~30m window within (1,60]" "$([ "$mins" -ge 1 ] && [ "$mins" -le 60 ] && echo ok)" "ok"

  # W3: old last_run_at → capped at 2880, exit 0
  workdir=$(make_workdir); state="$workdir/state.json"
  printf '{"version":1,"last_run_at":"%s","patterns":{}}' "$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$state" 2>&1) || ec=$?
  assert_exit_code "W3: window exits 0" "$ec" 0
  assert_output_contains "W3: capped at 2880" "$output" "MONITOR_SINCE_MINUTES=2880"

  # W4: corrupt JSON state → first-run window
  workdir=$(make_workdir); echo 'not json {{{' > "$workdir/state.json"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W4: corrupt state exits 0" "$ec" 0
  assert_output_contains "W4: corrupt → 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  # W4b: valid JSON but unparseable last_run_at → first-run window (must not crash under set -e)
  workdir=$(make_workdir)
  printf '{"version":1,"last_run_at":"not-a-date","patterns":{}}' > "$workdir/state.json"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W4b: bad timestamp exits 0" "$ec" 0
  assert_output_contains "W4b: bad timestamp → 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  local L  # gh calls log path, per-test

  # W5: new pattern → CREATE; --repo present on every gh call; state records issue
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-1","title":"[Monitor] err","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=142 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W5: create exits 0" "$ec" 0
  assert_output_contains "W5: action create" "$output" '"action":"create"'
  assert_file_contains "W5: gh issue create called" "$L" "issue create"
  assert_equals "W5: every gh call carries --repo" "$(grep -c -- '--repo o/r' "$L")" "$(wc -l < "$L" | tr -d ' ')"
  assert_equals "W5: state records 142" "$(jq -c '.patterns["pipeline:err:categorize"].gh_issue' "$state")" "142"

  # W6: same (entity,pattern) in state → SKIP, NO gh calls at all
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W6: action skip" "$output" '"action":"skip"'
  # reconciliation may `gh issue view` to confirm the stored issue is still open, but
  # an already-seen (entity,pattern) must never create or comment.
  assert_file_not_contains "W6: no create" "$L" "issue create"
  assert_file_not_contains "W6: no comment" "$L" "issue comment"

  # W7: known pattern, NEW entity → COMMENT; entity appended (sessions length 2)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-2","title":"T","body":"B","summary":"recurred"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W7: action comment" "$output" '"action":"comment"'
  assert_file_contains "W7: commented on 142" "$L" "issue comment 142"
  assert_equals "W7: 2 sessions" "$(jq -c '.patterns["pipeline:err:categorize"].sessions|length' "$state")" "2"

  # W8: same entity, DIFFERENT pattern → CREATE (not collapsed)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:timeout:narrative","severity":"high","entity":"S-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=143 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W8: action create" "$output" '"action":"create"'
  assert_output_not_contains "W8: not a comment" "$output" '"action":"comment"'
  assert_equals "W8: new pattern stored" "$(jq -c '.patterns["pipeline:timeout:narrative"].gh_issue' "$state")" "143"

  # W9: two findings, same pattern, different entity, ONE run → 1 create + 1 comment, both entities stored
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n%s\n' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=150 GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_equals "W9: one create" "$(grep -c 'issue create' "$L")" "1"
  assert_equals "W9: one comment" "$(grep -c 'issue comment' "$L")" "1"
  assert_equals "W9: both entities stored" "$(jq -c '.patterns["payment:stuck"].sessions|length' "$state")" "2"

  # W9b: empty stdin → exit 0, state initialized, last_run_at advanced (non-null)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r < /dev/null 2>&1) || ec=$?
  assert_exit_code "W9b: empty stdin exits 0" "$ec" 0
  assert_file_exists "W9b: state written" "$state"
  assert_output_not_contains "W9b: last_run_at advanced" "$(jq -r '.last_run_at' "$state")" "null"

  # W10: stored issue CLOSED → CREATE fresh (sessions fixture uses "" for null entity)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:llm-gap:failure":{"gh_issue":99,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"ops:llm-gap:failure","severity":"high","entity":null,"title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=CLOSED GH_CREATE_NUMBER=200 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W10: closed → create" "$output" '"action":"create"'
  assert_equals "W10: now issue 200" "$(jq -c '.patterns["ops:llm-gap:failure"].gh_issue' "$state")" "200"

  # W10b: stored issue, gh view FAILS → conservative: treat as OPEN → COMMENT, not create
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:llm-gap:failure":{"gh_issue":99,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"ops:llm-gap:failure","severity":"high","entity":"E-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue view" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W10b: view-fail → comment" "$output" '"action":"comment"'
  assert_file_not_contains "W10b: no duplicate create" "$L" "issue create"

  # W11: lost state, an existing open issue whose body embeds the markers → adopt/COMMENT
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:failed","severity":"high","entity":"P-9","title":"T","body":"B","summary":"again"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    GH_SEARCH_JSON='[{"number":321}]' GH_VIEW_BODY='**Pattern:** `payment:failed`
**Entity:** `P-9`' \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W11: recovered → comment" "$output" '"action":"comment"'
  assert_file_contains "W11: commented on 321" "$L" "issue comment 321"
  assert_file_contains "W11: recovery search is colon-tokenized" "$L" "payment failed"
  assert_file_not_contains "W11: no duplicate create" "$L" "issue create"

  # W11b: search hit but body lacks the entity marker → do NOT adopt → CREATE
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:failed","severity":"high","entity":"P-9","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=500 \
    GH_SEARCH_JSON='[{"number":777}]' GH_VIEW_BODY='**Pattern:** `payment:failed`
**Entity:** `SOMEONE-ELSE`' \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W11b: mismatch → create" "$output" '"action":"create"'
  assert_file_not_contains "W11b: did not comment on 777" "$L" "issue comment 777"

  # W12: malformed line → tracking issue + non-zero, BUT the window ADVANCES.
  # Malformed input is NOT a transient op failure — it is already escalated via the
  # tracking issue, and re-emits every run; freezing last_run_at on it causes silent
  # window degradation (issue #85). Only real gh op failures may freeze the window.
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n' 'this is not json' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=400 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12: malformed → non-zero" "$ec" 1
  assert_file_contains "W12: monitor-input:malformed filed" "$L" "monitor-input:malformed"
  assert_output_not_contains "W12: window advanced past frozen ts" "$(jq -r '.last_run_at' "$state")" "2026-06-01T00:00:00Z"

  # W12b: multiple malformed lines → exactly ONE tracking issue
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n%s\n' 'garbage one' 'garbage two' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=401 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_equals "W12b: one malformed issue" "$(grep -c 'monitor-input:malformed' "$L")" "1"

  # W12c: an OPEN malformed-input tracking issue already in state → do NOT file a duplicate,
  # but DO append the new malformed lines as a recurrence comment (recurring signal, #85),
  # and the window still ADVANCES (malformed is not a transient op failure).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:monitor-input:malformed":{"gh_issue":300,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' 'garbage' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_CREATE_NUMBER=301 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12c: malformed run still non-zero" "$ec" 1
  assert_file_not_contains "W12c: no duplicate malformed issue created" "$L" "issue create"
  assert_file_contains "W12c: recurrence comment appended to open tracking issue" "$L" "issue comment 300"
  assert_output_not_contains "W12c: window advanced (null→ts)" "$(jq -r '.last_run_at' "$state")" "null"

  # W12e: a malformed line PLUS a real gh op failure → op_failed freezes the window.
  # Proves the window advances ONLY when there is no transient op failure (#85): the
  # malformed line alone would advance it, but the failed create must still freeze it.
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-02T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n%s\n' 'not json' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=420 GH_FAIL_ON="issue create" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12e: op failure → non-zero" "$ec" 1
  assert_equals "W12e: window frozen on op failure" "$(jq -r '.last_run_at' "$state")" "2026-06-02T00:00:00Z"

  # W13: gh create fails → not in state, non-zero, window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue create" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W13: gh fail → non-zero" "$ec" 1
  assert_equals "W13: not in state" "$(jq -c '.patterns["payment:stuck"] // "absent"' "$state")" '"absent"'
  assert_equals "W13: window unchanged" "$(jq -r '.last_run_at' "$state")" "2026-06-01T00:00:00Z"

  # W13b: comment fails on known new entity → non-zero, entity NOT appended, window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{"payment:stuck":{"gh_issue":50,"sessions":["P-1"],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_FAIL_ON="issue comment" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W13b: comment fail → non-zero" "$ec" 1
  assert_equals "W13b: entity not appended" "$(jq -c '.patterns["payment:stuck"].sessions|length' "$state")" "1"

  # W14: --dry-run → exit 0, no state file, no gh calls
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14: dry-run exits 0" "$ec" 0
  assert_file_not_exists "W14: no state written" "$state"
  assert_file_not_exists "W14: no gh calls" "$L"
  assert_output_contains "W14: would create" "$output" '"action":"create"'

  # W14d: --dry-run WITHOUT --repo must not call `gh repo view` to resolve the repo (offline-safe)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14d: dry-run without --repo exits 0" "$ec" 0
  assert_file_not_exists "W14d: no gh calls (no repo resolution)" "$L"
  assert_output_contains "W14d: would create" "$output" '"action":"create"'

  # W14e: dry-run previews within-batch dedup — two same-pattern/different-entity findings → 1 create + 1 comment, not 2 creates
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n%s\n' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14e: dry-run exits 0" "$ec" 0
  assert_equals "W14e: one create previewed" "$(printf '%s' "$output" | grep -c '"action":"create"')" "1"
  assert_equals "W14e: one comment previewed" "$(printf '%s' "$output" | grep -c '"action":"comment"')" "1"

  # W15: invalid pattern_key → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"BAD KEY!!","severity":"high","entity":"X","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=402 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W15: invalid key → non-zero" "$ec" 1
  assert_output_contains "W15: action malformed" "$output" '"action":"malformed"'

  # W15b: missing required field (no body) → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"X","title":"T"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=403 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15b: missing body → malformed" "$output" '"action":"malformed"'

  # W15c: entity wrong type (object) → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":{"x":1},"title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=404 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15c: bad entity type → malformed" "$output" '"action":"malformed"'

  # W15d: entity containing a backtick → malformed (would corrupt markers / inject markdown)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"a`b","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=410 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15d: backtick entity → malformed" "$output" '"action":"malformed"'

  # W20: legacy unversioned state with a compatible patterns shape → UPGRADE in place,
  # back up the original first, and preserve existing mappings — no data loss, no duplicate
  # issues for already-tracked patterns (#88).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"last_run_at":"2026-05-01T00:00:00Z","patterns":{"payment:stuck":{"gh_issue":77,"sessions":["P-1"],"first_seen":"2026-05-01T00:00:00Z","last_seen":"2026-05-01T00:00:00Z"}}}' > "$state"
  cp "$state" "$workdir/orig.json"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20: legacy-state commit exits 0" "$ec" 0
  assert_output_contains "W20: existing mapping recognized → skip" "$output" '"action":"skip"'
  assert_file_not_contains "W20: no duplicate issue created" "$L" "issue create"
  assert_file_exists "W20: original backed up" "$state.pre-v1.bak"
  assert_equals "W20: backup preserves original bytes" "$(cat "$state.pre-v1.bak")" "$(cat "$workdir/orig.json")"
  assert_json_field "W20: upgraded to version 1" "$state" ".version" "1"
  assert_equals "W20: mapping preserved" "$(jq -c '.patterns["payment:stuck"].gh_issue' "$state")" "77"

  # W20b: existing-but-incompatible state (valid JSON, no patterns object) → back up + warn,
  # then start fresh and proceed — never a silent overwrite (#88).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"hello":"world","reported_cids":[1,2,3]}' > "$state"
  cp "$state" "$workdir/orig.json"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=88 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20b: incompatible-state commit exits 0" "$ec" 0
  assert_output_contains "W20b: warns about incompatible state" "$output" "WARNING"
  assert_file_exists "W20b: original backed up" "$state.pre-v1.bak"
  assert_equals "W20b: backup preserves original bytes" "$(cat "$state.pre-v1.bak")" "$(cat "$workdir/orig.json")"
  assert_output_contains "W20b: filed the new finding" "$output" '"action":"create"'
  assert_json_field "W20b: upgraded to version 1" "$state" ".version" "1"

  # W20c: a healthy v1 state file must NOT spawn a .pre-v1.bak (no needless backup every run).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r < /dev/null 2>&1) || ec=$?
  assert_exit_code "W20c: v1 state commit exits 0" "$ec" 0
  assert_file_not_exists "W20c: no backup for healthy v1 state" "$state.pre-v1.bak"

  # W20d: dry-run must not mutate — no backup written even for a legacy state file.
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20d: dry-run legacy exits 0" "$ec" 0
  assert_file_not_exists "W20d: dry-run writes no backup" "$state.pre-v1.bak"

  # W20e: legacy state with a malformed pattern entry → the upgrade DROPS schema-incompatible
  # entries (must be an object with numeric gh_issue + array sessions) so downstream commit
  # never crashes indexing them; the dropped key is re-created cleanly (#88 robustness).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"patterns":{"good:one":{"gh_issue":55,"sessions":["E-1"],"first_seen":"2026-05-01T00:00:00Z","last_seen":"2026-05-01T00:00:00Z"},"bad:two":"not-an-object"}}' > "$state"
  printf '%s\n' '{"pattern_key":"bad:two","severity":"high","entity":"E-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_CREATE_NUMBER=66 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W20e: malformed-entry legacy commit exits 0" "$ec" 0
  assert_output_contains "W20e: dropped bad entry → fresh create" "$output" '"action":"create"'
  assert_equals "W20e: compatible entry preserved" "$(jq -c '.patterns["good:one"].gh_issue' "$state")" "55"
  assert_equals "W20e: bad:two re-created cleanly" "$(jq -c '.patterns["bad:two"].gh_issue' "$state")" "66"

  # W20g: if the .pre-v1.bak backup cannot be written, ABORT before any gh op or overwrite —
  # never silently destroy the original (the core #88 guarantee; codex review).
  workdir=$(make_workdir); make_mock_gh "$workdir"; L="$workdir/gh.log"
  mkdir -p "$workdir/ro"; printf '{"patterns":{}}' > "$workdir/ro/state.json"; cp "$workdir/ro/state.json" "$workdir/orig.json"
  chmod 555 "$workdir/ro"
  printf '%s\n' '{"pattern_key":"x:y","severity":"high","entity":"E","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=9 \
    bash "$script" commit --state "$workdir/ro/state.json" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  chmod 755 "$workdir/ro"
  assert_exit_code "W20g: backup-failure aborts non-zero" "$ec" 1
  assert_file_not_contains "W20g: aborted before any gh create" "$L" "issue create"
  assert_equals "W20g: original state untouched" "$(cat "$workdir/ro/state.json")" "$(cat "$workdir/orig.json")"

  # W21: a non-canonical severity ("High") is normalized to lowercase — no junk grey label (#86).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"High","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=86 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W21: normalized-severity commit exits 0" "$ec" 0
  assert_file_contains "W21: applies canonical 'high' label" "$L" ",high"
  assert_file_not_contains "W21: no capitalized 'High' label" "$L" "High"

  # W21b: an unsupported severity ("critical") maps to the default "medium" with a warning (#86).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"critical","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=87 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W21b: unknown-severity commit exits 0" "$ec" 0
  assert_output_contains "W21b: warns about unsupported severity" "$output" "unsupported severity"
  assert_file_contains "W21b: applies default 'medium' label" "$L" ",medium"
  assert_file_not_contains "W21b: no junk 'critical' label" "$L" "critical"

  # W21c: a canonical severity passes through unchanged, no warning (regression guard).
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"feedback:got","severity":"low","entity":"F-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=89 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_file_contains "W21c: applies 'low' label" "$L" ",low"
  assert_output_not_contains "W21c: no warning for canonical severity" "$output" "unsupported severity"

  local cmd="$PLUGIN_ROOT/skills/monitor-nightly/SKILL.md"
  # W16: command exists, right frontmatter, calls engine, uses flock, parses config — and NEVER calls gh
  assert_file_exists "W16: command exists" "$cmd"
  assert_file_contains "W16: argument-hint" "$cmd" 'argument-hint'
  assert_file_contains "W16: defines engine path" "$cmd" 'scripts/monitor-dedup.sh'
  assert_file_contains "W16: runs engine commit" "$cmd" '"$ENGINE" commit'
  assert_file_contains "W16: runs engine window" "$cmd" '"$ENGINE" window'
  assert_file_contains "W16: flock" "$cmd" 'flock'
  assert_file_contains "W16: reads .local.md" "$cmd" 'saas-startup-team.local.md'
  # the command must NOT call gh itself (engine owns all gh). Match a gh word-boundary command form.
  assert_file_not_contains "W16: no gh issue calls" "$cmd" 'gh issue'
  assert_file_not_contains "W16: no gh repo calls" "$cmd" 'gh repo'
  assert_file_not_contains "W16: no gh label calls" "$cmd" 'gh label'
  assert_file_not_contains "W16: no gh auth calls" "$cmd" 'gh auth'
  # W16e: the engine is invoked DIRECTLY (executable + shebang), never via `bash "$ENGINE"`,
  # so an injection-sensitive cron can scope --allowedTools to the engine path and drop the
  # full-shell `Bash(bash:*)` grant (#89); a hardened narrow-scope cron is documented.
  assert_file_not_contains "W16e: engine invoked directly, not via bash (#89)" "$cmd" 'bash "$ENGINE"'
  assert_file_contains "W16e: documents hardened narrow tool-scope" "$cmd" "Hardened cron"

  # W17: extracted collect block writes a JSONL finding per marker (sanitized kind) to $STATE_FILE.findings
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  printf '2026-06-21 02:00:00 UTC ocr-api down\nconnection refused\n' > "$workdir/.monitor/ocr-api-last-failure.txt"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W17: collect exits 0" "$ec" 0
  assert_file_contains "W17: pattern key from filename" "$workdir/state.json.findings" '"pattern_key":"ops:ocr-api:failure"'
  assert_json_valid "W17: emits valid JSON" "$workdir/state.json.findings"

  # W17b: messy marker filename → sanitized to a valid pattern_key (dot/space/case → dashes)
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  printf 'boom\n' > "$workdir/.monitor/OCR Api.Bad-last-failure.txt"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_file_contains "W17b: sanitized kind" "$workdir/state.json.findings" '"pattern_key":"ops:ocr-api-bad:failure"'
  assert_equals "W17b: key valid per regex" \
    "$(jq -r '.pattern_key' "$workdir/state.json.findings" | grep -cE '^[a-z0-9][a-z0-9:_-]*$')" "1"

  # W18: no markers, no custom-checks → empty findings file, exit 0
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W18: empty collect exits 0" "$ec" 0
  assert_equals "W18: no findings" "$(tr -d '[:space:]' < "$workdir/state.json.findings")" ""

  # W18b: custom-checks script output is merged into the findings file
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  cat > "$workdir/checks.sh" <<'CC'
#!/usr/bin/env bash
echo '{"pattern_key":"feedback:received","severity":"low","entity":"fb-7","title":"T","body":"B"}'
CC
  chmod +x "$workdir/checks.sh"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/checks.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_file_contains "W18b: custom-checks merged" "$workdir/state.json.findings" '"pattern_key":"feedback:received"'

  # W18c: custom-checks exits non-zero → keeps its emitted findings AND appends a tracking finding; collect still exits 0
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  cat > "$workdir/checks.sh" <<'CC'
#!/usr/bin/env bash
echo '{"pattern_key":"feedback:received","severity":"low","entity":"fb-9","title":"T","body":"B"}'
exit 3
CC
  chmod +x "$workdir/checks.sh"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/checks.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W18c: collect survives failing custom-checks" "$ec" 0
  assert_file_contains "W18c: keeps emitted finding" "$workdir/state.json.findings" '"pattern_key":"feedback:received"'
  assert_file_contains "W18c: appends checks-failure finding" "$workdir/state.json.findings" '"pattern_key":"ops:monitor-checks:failure"'

  # W22: the config parser strips YAML-style inline comments (the shipped example uses them)
  # and converts a literal \n escape to a real newline, instead of silently corrupting the
  # value (broken paths / literal `|`) — issue #87.
  workdir=$(make_workdir); mkdir -p "$workdir/.claude"
  cat > "$workdir/.claude/saas-startup-team.local.md" <<'CFG'
---
monitor:
  repo: owner/name                 # default via gh repo view
  state_file: .data/monitor.json   # keep co-located
  labels: [monitor, customer-issue]   # base labels
  repro_recipe: "curl -s https://api/{entity}\necho done"
---
CFG
  extract_md_bash "$cmd" "## Configuration" > "$workdir/cfg.sh"
  printf '\nprintf "REPO=[%%s]\\nSTATE=[%%s]\\nRECIPE<<%%s>>\\n" "$REPO" "$STATE_FILE" "$REPRO_RECIPE"\n' >> "$workdir/cfg.sh"
  ec=0; output=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/cfg.sh" 2>&1) || ec=$?
  assert_exit_code "W22: config block runs" "$ec" 0
  assert_output_contains "W22: repo inline comment stripped" "$output" "REPO=[owner/name]"
  assert_output_contains "W22: state_file inline comment stripped" "$output" "STATE=[.data/monitor.json]"
  assert_output_contains "W22: repro recipe first line" "$output" "curl -s https://api/{entity}"
  assert_output_contains "W22: repro recipe second line kept" "$output" "echo done"
  assert_output_not_contains "W22: \\n converted to a real newline" "$output" 'api/{entity}\necho'
  rm -rf "$workdir"

  # W22b: a QUOTED value preserves an inner ` #` — inline-comment stripping applies to unquoted
  # values only, so a `#` inside quotes is real content, not a comment (#87; codex review).
  workdir=$(make_workdir); mkdir -p "$workdir/.claude"
  cat > "$workdir/.claude/saas-startup-team.local.md" <<'CFG'
---
monitor:
  repro_recipe: "run probe #42 for {entity}"
---
CFG
  extract_md_bash "$cmd" "## Configuration" > "$workdir/cfg.sh"
  printf '\nprintf "RECIPE=[%%s]\\n" "$REPRO_RECIPE"\n' >> "$workdir/cfg.sh"
  ec=0; output=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/cfg.sh" 2>&1) || ec=$?
  assert_output_contains "W22b: quoted inner # preserved" "$output" "RECIPE=[run probe #42 for {entity}]"
  rm -rf "$workdir"

  # W19: config example, README, and versions are consistent
  assert_file_contains "W19: example has monitor block" "$PLUGIN_ROOT/saas-operations.local.md.example" "monitor:"
  assert_file_contains "W19: README documents command" "$PLUGIN_ROOT/README.md" "/monitor-nightly"
  assert_file_contains "W19: README custom-checks contract" "$PLUGIN_ROOT/README.md" "monitor-checks.sh"
  assert_file_contains "W19: README documents repro_recipe" "$PLUGIN_ROOT/README.md" "repro_recipe"
  # the dropped `severities` key must not reappear in either doc
  assert_file_not_contains "W19: no severities in example" "$PLUGIN_ROOT/saas-operations.local.md.example" "severities"
  assert_file_not_contains "W19: no severities in README" "$PLUGIN_ROOT/README.md" "severities"
  local pv mv
  pv="$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  mv="$(jq -r '.plugins[] | select(.name=="saas-operations") | .version' "$PLUGIN_ROOT/../../.claude-plugin/marketplace.json")"
  assert_equals "W19: plugin/marketplace versions match" "$pv" "$mv"
}

test_monitor_dedup
