# Sourced by run-tests.sh — shared auto-file helper (lesson #195).
# Uses harness assert_* helpers and make_workdir. Mocks `gh` on PATH.
test_issue_file() {
  echo -e "\n${CYAN}Suite: issue-file.sh (#195)${NC}"
  local script="$PLUGIN_ROOT/scripts/issue-file.sh"
  local wd bindir ec out

  # Mock gh: logs every argv to $GH_LOG; `issue list` returns $GH_LIST_JSON,
  # `issue create` echoes $GH_CREATE_URL, `repo view` echoes a repo.
  install_mock_gh() {
    bindir="$1/bin"; mkdir -p "$bindir"
    cat > "$bindir/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "issue list")   printf '%s' "${GH_LIST_JSON:-[]}" ;;
  "issue create") echo "${GH_CREATE_URL:-https://github.com/o/r/issues/123}" ;;
  "issue comment") : ;;
  "repo view")    echo "o/r" ;;
esac
exit 0
EOF
    chmod +x "$bindir/gh"
  }

  # IF1: no existing match → creates issue, prints the created URL.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  ec=0
  out=$(GH_LOG="$wd/gh.log" GH_LIST_JSON='[]' PATH="$bindir:$PATH" \
        bash "$script" --repo o/r --title "Checkout 500 on retry" --body "stack trace" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "IF1: no match exits 0" "$ec" 0
  assert_output_contains "IF1b: prints created URL" "$out" "https://github.com/o/r/issues/123"
  assert_file_contains "IF1c: gh issue create was called" "$wd/gh.log" "issue create"

  # IF2: existing open match (same normalized title) → comments, does NOT create.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  ec=0
  out=$(GH_LOG="$wd/gh.log" PATH="$bindir:$PATH" \
        GH_LIST_JSON='[{"number":7,"title":"Checkout 500 on retry!!","url":"https://github.com/o/r/issues/7"}]' \
        bash "$script" --repo o/r --title "Checkout 500 on retry" --body "more evidence" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "IF2: match exits 0" "$ec" 0
  assert_output_contains "IF2b: prints existing issue URL" "$out" "https://github.com/o/r/issues/7"
  assert_file_contains "IF2c: comments on the match" "$wd/gh.log" "issue comment 7"
  assert_file_not_contains "IF2d: does NOT create a duplicate" "$wd/gh.log" "issue create"

  # IF3: body with a secret-shaped string → parked, zero gh mutations, human-task written.
  # Assemble the token at runtime so the contiguous secret never appears in this file
  # (the lessons-deliver firewall greps the diff with the same pii-gate).
  local blob; blob="sk-""$(printf '%s' abcdefghij0123456789xy)"
  wd="$(make_workdir)"; install_mock_gh "$wd"
  ec=0
  out=$(GH_LOG="$wd/gh.log" PATH="$bindir:$PATH" \
        bash "$script" --repo o/r --title "Payment error" \
        --body "leaked value $blob" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "IF3: sensitive content exits 3 (parked)" "$ec" 3
  assert_file_exists "IF3b: human-tasks entry written" "$wd/docs/human-tasks.md"
  assert_file_contains "IF3c: parked under a reviewable task" "$wd/docs/human-tasks.md" "Review sensitive defect before filing"
  assert_file_not_exists "IF3d: no gh call at all on sensitive content" "$wd/gh.log"

  # IF4: --dry-run → zero gh mutations (no create, no comment).
  wd="$(make_workdir)"; install_mock_gh "$wd"
  ec=0
  out=$(GH_LOG="$wd/gh.log" GH_LIST_JSON='[]' PATH="$bindir:$PATH" \
        bash "$script" --repo o/r --title "Some defect" --body "x" --root "$wd" --dry-run 2>&1) || ec=$?
  assert_exit_code "IF4: dry-run exits 0" "$ec" 0
  assert_file_not_exists "IF4b: dry-run makes no gh call" "$wd/gh.log"

  # IF5: filing appends one digest line for /digest to surface.
  wd="$(make_workdir)"; install_mock_gh "$wd"
  GH_LOG="$wd/gh.log" GH_LIST_JSON='[]' PATH="$bindir:$PATH" \
    bash "$script" --repo o/r --title "Login loop" --body "x" --root "$wd" \
    --digest-file "$wd/.startup/monitor/runs/run-1.md" >/dev/null 2>&1 || true
  assert_file_contains "IF5: digest line appended for filed issue" \
    "$wd/.startup/monitor/runs/run-1.md" "Filed issue #123"

  # IF6: dedup search failure fails CLOSED — no create (review fix #1).
  install_mock_gh_fail() {
    bindir="$1/bin"; mkdir -p "$bindir"
    cat > "$bindir/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
[ "$1 ${2:-}" = "issue list" ] && exit 1   # search fails
case "$1 ${2:-}" in "issue create") echo "https://github.com/o/r/issues/9" ;; esac
exit 0
EOF
    chmod +x "$bindir/gh"
  }
  wd="$(make_workdir)"; install_mock_gh_fail "$wd"
  ec=0
  out=$(GH_LOG="$wd/gh.log" PATH="$bindir:$PATH" \
        bash "$script" --repo o/r --title "Defect" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "IF6: dedup search failure fails closed" "$ec" 1
  assert_file_not_contains "IF6b: no create when dedup unavailable" "$wd/gh.log" "issue create"

  # IF7: PII in the TITLE is withheld from the parked entry (review fix #2), and a
  # human-tasks.md WITHOUT a Pending header still gets the entry (review fix #3).
  local tkey; tkey="sk-""$(printf '%s' zyxwvutsrq9876543210ab)"
  wd="$(make_workdir)"; install_mock_gh "$wd"; mkdir -p "$wd/docs"
  printf '# Human Tasks\n\nno pending header here\n' > "$wd/docs/human-tasks.md"
  ec=0
  out=$(GH_LOG="$wd/gh.log" PATH="$bindir:$PATH" \
        bash "$script" --repo o/r --title "leak $tkey" --body "context" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "IF7: sensitive title parks (exit 3)" "$ec" 3
  assert_file_contains "IF7b: entry appended even without Pending header" \
    "$wd/docs/human-tasks.md" "Review sensitive defect before filing"
  assert_file_contains "IF7c: sensitive title withheld from doc" \
    "$wd/docs/human-tasks.md" "title contains sensitive content"
  assert_file_not_exists "IF7d: no gh call on sensitive title" "$wd/gh.log"
}
test_issue_file
