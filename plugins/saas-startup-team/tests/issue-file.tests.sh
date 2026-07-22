# Sourced by run-tests.sh — shared auto-file helper (lesson #195, #326).
# Uses harness assert_* helpers and make_workdir. Mocks `gh` on PATH.
test_issue_file() {
  echo -e "\n${CYAN}Suite: issue-file.sh (#195 / #326)${NC}"
  local script="$PLUGIN_ROOT/scripts/issue-file.sh"
  local wd bindir ec out stdout stderr

  # Mock gh: logs every argv to $GH_LOG; `issue list` returns $GH_LIST_JSON,
  # `issue create` echoes $GH_CREATE_URL (or $GH_CREATE_RAW), captures body-file
  # path contents to $GH_BODY_CAPTURE when set, `repo view` echoes a repo.
  # Per-repo overrides (for #328 source escalate): when --repo is set,
  # GH_LIST_JSON__owner_name and GH_CREATE_URL__owner_name (slash → underscore)
  # take precedence if defined.
  install_mock_gh() {
    bindir="$1/bin"; mkdir -p "$bindir"
    cat > "$bindir/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
# Capture --body-file contents when requested
if [ -n "${GH_BODY_CAPTURE:-}" ]; then
  i=1
  while [ $i -le $# ]; do
    eval "a=\${$i}"
    if [ "$a" = "--body-file" ]; then
      eval "bf=\${$((i+1))}"
      cat "$bf" > "$GH_BODY_CAPTURE" 2>/dev/null || true
      break
    fi
    i=$((i+1))
  done
fi
repo_arg=""
i=1
while [ $i -le $# ]; do
  eval "a=\${$i}"
  if [ "$a" = "--repo" ]; then
    eval "repo_arg=\${$((i+1))}"
    break
  fi
  i=$((i+1))
done
repo_key=""
if [ -n "$repo_arg" ]; then
  repo_key=$(printf '%s' "$repo_arg" | tr '/' '_')
fi
case "$1 ${2:-}" in
  "issue list")
    if [ -n "${GH_LIST_FAIL:-}" ]; then exit 1; fi
    if [ -n "${GH_LIST_RAW:-}" ]; then printf '%s' "$GH_LIST_RAW"; exit 0; fi
    if [ -n "$repo_key" ]; then
      eval "isset=\${GH_LIST_JSON__${repo_key}+x}"
      if [ -n "$isset" ]; then
        eval "printf '%s' \"\$GH_LIST_JSON__${repo_key}\""
        exit 0
      fi
    fi
    printf '%s' "${GH_LIST_JSON:-[]}"
    ;;
  "issue create")
    if [ -n "${GH_CREATE_FAIL:-}" ]; then exit 1; fi
    if [ -n "${GH_CREATE_RAW+x}" ]; then printf '%s' "$GH_CREATE_RAW"; exit 0; fi
    if [ -n "$repo_key" ]; then
      eval "isset=\${GH_CREATE_URL__${repo_key}+x}"
      if [ -n "$isset" ]; then
        eval "echo \"\$GH_CREATE_URL__${repo_key}\""
        exit 0
      fi
    fi
    echo "${GH_CREATE_URL:-https://github.com/o/r/issues/123}"
    ;;
  "issue comment")
    if [ -n "${GH_COMMENT_FAIL:-}" ]; then exit 1; fi
    :
    ;;
  "issue view")
    if [ -n "${GH_VIEW_FAIL:-}" ]; then exit 1; fi
    if [ -n "${GH_VIEW_BODY:-}" ]; then
      jq -nc --arg b "$GH_VIEW_BODY" '{body:$b}'
    else
      printf '%s' "${GH_VIEW_JSON:-{\"body\":\"\"}}"
    fi
    ;;
  "issue edit")
    if [ -n "${GH_EDIT_FAIL:-}" ]; then exit 1; fi
    if [ -n "${GH_EDIT_CAPTURE:-}" ]; then
      i=1
      while [ $i -le $# ]; do
        eval "a=\${$i}"
        if [ "$a" = "--body-file" ]; then
          eval "bf=\${$((i+1))}"
          cat "$bf" > "$GH_EDIT_CAPTURE" 2>/dev/null || true
          break
        fi
        i=$((i+1))
      done
    fi
    :
    ;;
  "repo view") echo "o/r" ;;
esac
exit 0
EOF
    chmod +x "$bindir/gh"
  }

  run_if() {
    # Leading KEY=VAL become env; first --* starts script args.
    # Captures stdout/stderr separately into files under $wd.
    local outf errf env_args=() script_args=()
    outf="$wd/stdout.txt"; errf="$wd/stderr.txt"
    : >"$outf"; : >"$errf"
    while [ $# -gt 0 ]; do
      case "$1" in
        --*) script_args+=("$@"); break ;;
        *=*) env_args+=("$1"); shift ;;
        *) script_args+=("$@"); break ;;
      esac
    done
    ec=0
    env PATH="$bindir:$PATH" GH_LOG="$wd/gh.log" "${env_args[@]}" \
      bash "$script" "${script_args[@]}" >"$outf" 2>"$errf" || ec=$?
    stdout="$(cat "$outf")"
    stderr="$(cat "$errf")"
    out="$stdout"$'\n'"$stderr"
  }

  # IF1: no existing match → creates issue, prints the created URL.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' --repo o/r --title "Checkout 500 on retry" --body "stack trace" --root "$wd"
  assert_exit_code "IF1: no match exits 0" "$ec" 0
  assert_output_contains "IF1b: prints created URL" "$stdout" "https://github.com/o/r/issues/123"
  assert_file_contains "IF1c: gh issue create was called" "$wd/gh.log" "issue create"
  assert_output_contains "IF1d: status=created on stderr" "$stderr" "status=created"

  # IF2: existing open match (same normalized title) → comments, does NOT create.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[{"number":7,"title":"Checkout 500 on retry!!","url":"https://github.com/o/r/issues/7"}]' \
    --repo o/r --title "Checkout 500 on retry" --body "more evidence" --root "$wd"
  assert_exit_code "IF2: match exits 0" "$ec" 0
  assert_output_contains "IF2b: prints existing issue URL" "$stdout" "https://github.com/o/r/issues/7"
  assert_file_contains "IF2c: comments on the match" "$wd/gh.log" "issue comment 7"
  assert_file_not_contains "IF2d: does NOT create a duplicate" "$wd/gh.log" "issue create"
  assert_output_contains "IF2e: status=reused" "$stderr" "status=reused"

  # IF3: body with a secret-shaped string → parked, zero gh mutations, human-task written.
  local blob; blob="sk-""$(printf '%s' abcdefghij0123456789xy)"
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "Payment error" --body "leaked value $blob" --root "$wd"
  assert_exit_code "IF3: sensitive content exits 3 (parked)" "$ec" 3
  assert_file_exists "IF3b: human-tasks entry written" "$wd/docs/human-tasks.md"
  assert_file_contains "IF3c: parked under a reviewable task" "$wd/docs/human-tasks.md" "Review sensitive defect before filing"
  assert_file_not_exists "IF3d: no gh call at all on sensitive content" "$wd/gh.log"
  assert_output_contains "IF3e: status=parked" "$stderr" "status=parked"

  # IF4: --dry-run → zero gh mutations (no create, no comment).
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' --repo o/r --title "Some defect" --body "x" --root "$wd" --dry-run
  assert_exit_code "IF4: dry-run exits 0" "$ec" 0
  assert_file_not_exists "IF4b: dry-run makes no gh call" "$wd/gh.log"
  assert_output_contains "IF4c: status=dry-run" "$stderr" "status=dry-run"

  # IF5: filing appends one digest line for /digest to surface.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' --repo o/r --title "Login loop" --body "x" --root "$wd" \
    --digest-file "$wd/.startup/monitor/runs/run-1.md"
  assert_file_contains "IF5: digest line appended for filed issue" \
    "$wd/.startup/monitor/runs/run-1.md" "Filed issue #123"

  # IF6: dedup search failure fails CLOSED — no create.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_FAIL=1 --repo o/r --title "Defect" --body "x" --root "$wd"
  assert_exit_code "IF6: dedup search failure fails closed" "$ec" 1
  assert_file_not_contains "IF6b: no create when dedup unavailable" "$wd/gh.log" "issue create"
  assert_output_contains "IF6c: precheck_failed" "$stderr" "status=precheck_failed"

  # IF7: PII in the TITLE is withheld from the parked entry.
  local tkey; tkey="sk-""$(printf '%s' zyxwvutsrq9876543210ab)"
  wd="$(make_workdir)"; install_mock_gh "$wd"; mkdir -p "$wd/docs"
  printf '# Human Tasks\n\nno pending header here\n' > "$wd/docs/human-tasks.md"
  run_if --repo o/r --title "leak $tkey" --body "context" --root "$wd"
  assert_exit_code "IF7: sensitive title parks (exit 3)" "$ec" 3
  assert_file_contains "IF7b: entry appended even without Pending header" \
    "$wd/docs/human-tasks.md" "Review sensitive defect before filing"
  assert_file_contains "IF7c: sensitive title withheld from doc" \
    "$wd/docs/human-tasks.md" "title contains sensitive content"
  assert_file_not_exists "IF7d: no gh call on sensitive title" "$wd/gh.log"

  # --- #326 pattern-key cases ---

  # IF8: pattern-key miss → create; body includes exactly one Pattern marker; status=created
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' GH_BODY_CAPTURE="$wd/create-body.txt" \
    --repo o/r --title "Pipeline overpay" --body "evidence A" --root "$wd" \
    --pattern-key "ops:pipeline:overpay"
  assert_exit_code "IF8: key miss exits 0" "$ec" 0
  assert_output_contains "IF8b: URL on stdout" "$stdout" "https://github.com/o/r/issues/123"
  assert_output_contains "IF8c: status=created" "$stderr" "status=created"
  assert_file_contains "IF8d: create called" "$wd/gh.log" "issue create"
  # assert_file_contains uses regex grep — avoid unescaped '*'; check key + fixed-string count.
  assert_file_contains "IF8e: marker key in create body" "$wd/create-body.txt" 'ops:pipeline:overpay'
  local mc
  mc="$(grep -cF '**Pattern:** `ops:pipeline:overpay`' "$wd/create-body.txt" || true)"
  assert_equals "IF8f: exactly one Pattern marker line" "$mc" "1"
  # no post-create list after create: list then create only (title path does one list)
  local list_n create_n
  list_n="$(grep -c 'issue list' "$wd/gh.log" || true)"
  create_n="$(grep -c 'issue create' "$wd/gh.log" || true)"
  assert_equals "IF8g: one create" "$create_n" "1"
  # key miss does pattern list then may do title adopt list; both before create
  # ensure no list after create in log order
  if ! awk '/issue create/{c=1} c && /issue list/{exit 1}' "$wd/gh.log"; then
    assert_exit_code "IF8h: no list after create" 1 0
  else
    assert_exit_code "IF8h: no list after create" 0 0
  fi

  # IF9: pattern-key hit → comment only
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_BODY_CAPTURE="$wd/comment-body.txt" \
    GH_LIST_JSON='[{"number":9,"title":"Other","url":"https://github.com/o/r/issues/9","body":"x\n\n**Pattern:** `ops:pipeline:overpay`\n"}]' \
    --repo o/r --title "Pipeline overpay" --body "more" --root "$wd" \
    --pattern-key "ops:pipeline:overpay"
  assert_exit_code "IF9: key hit exits 0" "$ec" 0
  assert_output_contains "IF9b: reused URL" "$stdout" "https://github.com/o/r/issues/9"
  assert_output_contains "IF9c: status=reused" "$stderr" "status=reused"
  assert_file_contains "IF9d: comment" "$wd/gh.log" "issue comment 9"
  assert_file_not_contains "IF9e: no create" "$wd/gh.log" "issue create"

  # IF10: multi marker match → exit 1; no create/comment
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if \
    GH_LIST_JSON='[{"number":1,"title":"A","url":"https://github.com/o/r/issues/1","body":"**Pattern:** `ops:x`"},{"number":2,"title":"B","url":"https://github.com/o/r/issues/2","body":"**Pattern:** `ops:x`"}]' \
    --repo o/r --title "A" --body "e" --root "$wd" --pattern-key "ops:x"
  assert_exit_code "IF10: multi-match exit 1" "$ec" 1
  assert_output_contains "IF10b: status=ambiguous" "$stderr" "status=ambiguous"
  assert_file_not_contains "IF10c: no create" "$wd/gh.log" "issue create"
  assert_file_not_contains "IF10d: no comment" "$wd/gh.log" "issue comment"

  # IF11: create succeeds without post-create issue list (regression)
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' --repo o/r --title "Plain" --body "x" --root "$wd"
  assert_exit_code "IF11: create ok" "$ec" 0
  if ! awk '/issue create/{c=1} c && /issue list/{exit 1}' "$wd/gh.log"; then
    assert_exit_code "IF11b: no post-create list" 1 0
  else
    assert_exit_code "IF11b: no post-create list" 0 0
  fi

  # IF12: invalid pattern-key → usage exit 2
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" --pattern-key "Ops:Bad"
  assert_exit_code "IF12: invalid key exit 2" "$ec" 2
  assert_file_not_exists "IF12b: no gh" "$wd/gh.log"

  # IF13: dry-run + pattern-key → no gh
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" --pattern-key "ops:y" --dry-run
  assert_exit_code "IF13: dry-run+key exit 0" "$ec" 0
  assert_file_not_exists "IF13b: no gh" "$wd/gh.log"
  assert_output_contains "IF13c: dry-run status" "$stderr" "status=dry-run"

  # IF14: conflicting Pattern in body vs key → exit 2
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body $'hello\n\n**Pattern:** `ops:other`\n' --root "$wd" \
    --pattern-key "ops:mine"
  assert_exit_code "IF14: conflict exit 2" "$ec" 2
  assert_file_not_exists "IF14b: no gh" "$wd/gh.log"

  # IF15: body-then-PII — clean body, secret-shaped key injected into marker → park, no gh
  # Key must match regex (lowercase) but still trip pii-gate when placed in body.
  blob="sk-""$(printf '%s' abcdefghij0123456789xy)"
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "clean evidence" --root "$wd" --pattern-key "$blob"
  assert_exit_code "IF15: secret-shaped key parks after inject" "$ec" 3
  assert_file_not_exists "IF15b: no gh" "$wd/gh.log"
  assert_output_contains "IF15c: status=parked" "$stderr" "status=parked"

  # IF16: legacy single same-title unmarked → adopt, backfill marker via edit, comment, no create
  wd="$(make_workdir)"; install_mock_gh "$wd"
  # Pattern list returns unmarked title match (0 whole-line marker hits); title adopt
  # reuses same list mock and finds the title → backfill + comment.
  run_if \
    GH_LIST_JSON='[{"number":42,"title":"Legacy bug","url":"https://github.com/o/r/issues/42","body":"old body no marker"}]' \
    GH_VIEW_BODY='old body no marker' \
    GH_EDIT_CAPTURE="$wd/edit-body.txt" \
    --repo o/r --title "Legacy bug" --body "new evidence" --root "$wd" \
    --pattern-key "ops:legacy:bug"
  assert_exit_code "IF16: legacy adopt exit 0" "$ec" 0
  assert_output_contains "IF16b: adopted URL" "$stdout" "https://github.com/o/r/issues/42"
  assert_output_contains "IF16c: status=reused" "$stderr" "status=reused"
  assert_file_contains "IF16d: comment" "$wd/gh.log" "issue comment 42"
  assert_file_contains "IF16e: backfill edit" "$wd/gh.log" "issue edit 42"
  assert_file_not_contains "IF16f: no create" "$wd/gh.log" "issue create"
  local emc
  emc="$(grep -cF '**Pattern:** `ops:legacy:bug`' "$wd/edit-body.txt" || true)"
  assert_equals "IF16g: backfill body has marker" "$emc" "1"

  # IF17: search JSON malformed → precheck_failed, no create
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_RAW='not-json' --repo o/r --title "T" --body "b" --root "$wd" --pattern-key "ops:m"
  assert_exit_code "IF17: malformed list exit 1" "$ec" 1
  assert_output_contains "IF17b: precheck_failed" "$stderr" "status=precheck_failed"
  assert_file_not_contains "IF17c: no create" "$wd/gh.log" "issue create"

  # IF18: digest unwritable → still exit 0 after successful create
  wd="$(make_workdir)"; install_mock_gh "$wd"
  # digest path is a directory so append fails
  mkdir -p "$wd/digest-as-dir"
  run_if GH_LIST_JSON='[]' --repo o/r --title "T" --body "b" --root "$wd" \
    --digest-file "$wd/digest-as-dir"
  assert_exit_code "IF18: create ok despite bad digest" "$ec" 0
  assert_output_contains "IF18b: URL printed" "$stdout" "https://github.com/o/r/issues/123"
  assert_output_contains "IF18c: status=created" "$stderr" "status=created"

  # IF19: unparseable create output → unknown, mutation_possible
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' GH_CREATE_RAW='no-url-here' \
    --repo o/r --title "T" --body "b" --root "$wd"
  assert_exit_code "IF19: unparseable create exit 1" "$ec" 1
  assert_output_contains "IF19b: status=unknown" "$stderr" "status=unknown"
  assert_output_contains "IF19c: mutation_possible" "$stderr" "mutation_possible=true"

  # IF20: embedded (non whole-line) marker does not count as hit → create
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_BODY_CAPTURE="$wd/create-body.txt" \
    GH_LIST_JSON='[{"number":5,"title":"X","url":"https://github.com/o/r/issues/5","body":"see **Pattern:** `ops:embed` inline"}]' \
    --repo o/r --title "Different title" --body "e" --root "$wd" --pattern-key "ops:embed"
  assert_exit_code "IF20: embedded marker does not reuse" "$ec" 0
  assert_file_contains "IF20b: create" "$wd/gh.log" "issue create"
  assert_file_not_contains "IF20c: no comment" "$wd/gh.log" "issue comment"

  # IF21: multiline pattern-key → usage
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" --pattern-key $'ops:a\nops:b'
  assert_exit_code "IF21: multiline key exit 2" "$ec" 2
  assert_output_contains "IF21b: status=usage" "$stderr" "status=usage"
  assert_file_not_exists "IF21c: no gh" "$wd/gh.log"

  # IF22: title-only multi normalized match → ambiguous
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if \
    GH_LIST_JSON='[{"number":1,"title":"Same Title!!","url":"https://github.com/o/r/issues/1"},{"number":2,"title":"same title","url":"https://github.com/o/r/issues/2"}]' \
    --repo o/r --title "Same Title" --body "e" --root "$wd"
  assert_exit_code "IF22: title multi-match exit 1" "$ec" 1
  assert_output_contains "IF22b: status=ambiguous" "$stderr" "status=ambiguous"
  assert_file_not_contains "IF22c: no create" "$wd/gh.log" "issue create"
  assert_file_not_contains "IF22d: no comment" "$wd/gh.log" "issue comment"

  # IF23: marker hit with missing url → precheck_failed schema
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if \
    GH_LIST_JSON='[{"number":3,"title":"T","url":"","body":"**Pattern:** `ops:badurl`"}]' \
    --repo o/r --title "T" --body "e" --root "$wd" --pattern-key "ops:badurl"
  assert_exit_code "IF23: missing url exit 1" "$ec" 1
  assert_output_contains "IF23b: precheck_failed" "$stderr" "status=precheck_failed"
  assert_file_not_contains "IF23c: no create" "$wd/gh.log" "issue create"

  # --- #328 source-repo escalate ---

  # IF24: source miss → local create + source create once (no second source create)
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if \
    GH_LIST_JSON__o_r='[]' \
    GH_LIST_JSON__plugin_src='[]' \
    GH_CREATE_URL__o_r='https://github.com/o/r/issues/200' \
    GH_CREATE_URL__plugin_src='https://github.com/plugin/src/issues/50' \
    --repo o/r --title "Plugin-caused crash" --body "evidence" --root "$wd" \
    --pattern-key "plugin:saas:crash" \
    --source-repo plugin/src --source-escalate comment
  assert_exit_code "IF24: source miss exits 0" "$ec" 0
  assert_output_contains "IF24b: local URL on stdout" "$stdout" "https://github.com/o/r/issues/200"
  assert_output_contains "IF24c: local status=created" "$stderr" "status=created"
  assert_output_contains "IF24d: source_escalate=created" "$stderr" "source_escalate=created"
  assert_file_contains "IF24e: local create" "$wd/gh.log" "issue create --repo o/r"
  assert_file_contains "IF24f: source create" "$wd/gh.log" "issue create --repo plugin/src"
  create_n="$(grep -c 'issue create --repo plugin/src' "$wd/gh.log" || true)"
  assert_equals "IF24g: exactly one source create" "$create_n" "1"
  assert_file_not_contains "IF24h: no source comment on miss" "$wd/gh.log" "issue comment"

  # IF25: source hit → local create + source comment only (no source create)
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if \
    GH_LIST_JSON__o_r='[]' \
    GH_LIST_JSON__plugin_src='[{"number":77,"title":"Existing","url":"https://github.com/plugin/src/issues/77","body":"x\n\n**Pattern:** `plugin:saas:crash`\n"}]' \
    GH_CREATE_URL__o_r='https://github.com/o/r/issues/201' \
    --repo o/r --title "Plugin-caused crash" --body "more" --root "$wd" \
    --pattern-key "plugin:saas:crash" \
    --source-repo plugin/src --source-escalate comment
  assert_exit_code "IF25: source hit exits 0" "$ec" 0
  assert_output_contains "IF25b: local URL" "$stdout" "https://github.com/o/r/issues/201"
  assert_output_contains "IF25c: status=created local" "$stderr" "status=created"
  assert_output_contains "IF25d: source_escalate=reused" "$stderr" "source_escalate=reused"
  assert_file_contains "IF25e: source comment" "$wd/gh.log" "issue comment 77 --repo plugin/src"
  assert_file_not_contains "IF25f: no source create" "$wd/gh.log" "issue create --repo plugin/src"
  assert_file_contains "IF25g: local create still happens" "$wd/gh.log" "issue create --repo o/r"

  # IF26: no-duplicate source — local reuse + source reuse; neither creates
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if \
    GH_LIST_JSON__o_r='[{"number":9,"title":"X","url":"https://github.com/o/r/issues/9","body":"**Pattern:** `plugin:saas:crash`"}]' \
    GH_LIST_JSON__plugin_src='[{"number":77,"title":"Y","url":"https://github.com/plugin/src/issues/77","body":"**Pattern:** `plugin:saas:crash`"}]' \
    --repo o/r --title "Plugin-caused crash" --body "again" --root "$wd" \
    --pattern-key "plugin:saas:crash" \
    --source-repo plugin/src --source-escalate comment
  assert_exit_code "IF26: dual reuse exits 0" "$ec" 0
  assert_output_contains "IF26b: local reused URL" "$stdout" "https://github.com/o/r/issues/9"
  assert_output_contains "IF26c: status=reused" "$stderr" "status=reused"
  assert_output_contains "IF26d: source_escalate=reused" "$stderr" "source_escalate=reused"
  assert_file_not_contains "IF26e: no create anywhere" "$wd/gh.log" "issue create"
  assert_file_contains "IF26f: local comment" "$wd/gh.log" "issue comment 9 --repo o/r"
  assert_file_contains "IF26g: source comment" "$wd/gh.log" "issue comment 77 --repo plugin/src"

  # IF27: dry-run + source escalate → zero gh
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" \
    --pattern-key "ops:y" --source-repo plugin/src --source-escalate comment --dry-run
  assert_exit_code "IF27: dry-run source escalate exit 0" "$ec" 0
  assert_file_not_exists "IF27b: no gh" "$wd/gh.log"
  assert_output_contains "IF27c: dry-run status" "$stderr" "status=dry-run"
  assert_output_contains "IF27d: dry-run mentions source" "$stdout" "source-escalate"
  assert_output_contains "IF27e: dry-run source_repo in status" "$stderr" "source_repo=plugin/src"

  # IF28: --source-escalate without --source-repo → usage
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" \
    --pattern-key "ops:y" --source-escalate comment
  assert_exit_code "IF28: escalate without source-repo exit 2" "$ec" 2
  assert_file_not_exists "IF28b: no gh" "$wd/gh.log"

  # IF29: --source-repo without escalate mode → usage
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" \
    --pattern-key "ops:y" --source-repo plugin/src
  assert_exit_code "IF29: source-repo without escalate exit 2" "$ec" 2
  assert_file_not_exists "IF29b: no gh" "$wd/gh.log"

  # IF30: source escalate without pattern-key → usage
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if --repo o/r --title "T" --body "b" --root "$wd" \
    --source-repo plugin/src --source-escalate comment
  assert_exit_code "IF30: escalate without key exit 2" "$ec" 2
  assert_file_not_exists "IF30b: no gh" "$wd/gh.log"

  # IF31: default escalate none → no source repo calls even if not requested
  wd="$(make_workdir)"; install_mock_gh "$wd"
  run_if GH_LIST_JSON='[]' GH_CREATE_URL='https://github.com/o/r/issues/123' \
    --repo o/r --title "Plain" --body "x" --root "$wd" --pattern-key "ops:z"
  assert_exit_code "IF31: default no escalate exit 0" "$ec" 0
  assert_output_not_contains "IF31b: no source_escalate status" "$stderr" "source_escalate="
  list_repos="$(grep 'issue list' "$wd/gh.log" | grep -c 'plugin/src' || true)"
  assert_equals "IF31c: no plugin/src list" "$list_repos" "0"
}
test_issue_file
