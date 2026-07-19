# Solution-signoff validation (primary-only; no second trees).
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "solution-signoff.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_solution_signoff_gate() {
  echo -e "\n${CYAN}Suite SG: solution signoff gate${NC}"
  local script="$PLUGIN_ROOT/scripts/solution-signoff-gate.sh"
  local maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  local goal="$PLUGIN_ROOT/references/workflows/goal-deliver.md"
  local improve="$PLUGIN_ROOT/references/workflows/improve.md"
  local sandbox source linked source_file ec out other

  assert_file_exists "SG1: signoff gate exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} SG2: signoff gate is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} SG2: signoff gate is executable"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("SG2: signoff gate is not executable")
  fi

  sandbox=$(mktemp -d)
  source="$sandbox/source"
  git init -q "$source"
  git -C "$source" config user.email test@example.com
  git -C "$source" config user.name Test
  printf '.startup/go-live/\n' > "$source/.gitignore"
  printf 'tracked\n' > "$source/app.txt"
  git -C "$source" add .gitignore app.txt
  git -C "$source" commit -qm base
  source_file="$source/.startup/go-live/solution-signoff.md"
  mkdir -p "$(dirname "$source_file")"
  printf 'signed-v1\n' > "$source_file"

  ec=0; out=$(bash "$script" --source-root "$source" 2>&1) || ec=$?
  assert_exit_code "SG3: validation-only accepts regular signoff" "$ec" 0
  assert_equals "SG4: output is the source path" "$out" "$source_file"

  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$source" 2>&1) || ec=$?
  assert_exit_code "SG5: same-tree target validates" "$ec" 0

  other="$sandbox/other"
  git init -q "$other"
  git -C "$other" config user.email test@example.com
  git -C "$other" config user.name Test
  printf 'x\n' > "$other/app.txt"
  git -C "$other" add app.txt && git -C "$other" commit -qm base
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$other" 2>&1) || ec=$?
  assert_exit_code "SG6: distinct target is rejected" "$ec" 1

  linked="$sandbox/linked"
  git -C "$source" worktree add -q --detach "$linked" HEAD
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$linked" 2>&1) || ec=$?
  assert_exit_code "SG7: linked worktree target is rejected" "$ec" 1
  git -C "$source" worktree remove --force "$linked" >/dev/null

  rm -f "$source_file"
  printf 'outside\n' > "$sandbox/outside-signoff"
  ln -s "$sandbox/outside-signoff" "$source_file"
  ec=0; out=$(bash "$script" --source-root "$source" 2>&1) || ec=$?
  assert_exit_code "SG8: symlink source fails" "$ec" 1

  assert_file_contains "SG9: maintain uses executable signoff gate" "$maintain" \
    'scripts/solution-signoff-gate.sh'
  assert_file_contains "SG10: maintain pins source and target" "$maintain" \
    '--source-root "$REPO_ROOT" --target-root "$WT"'
  assert_file_contains "SG11: goal-deliver uses executable signoff gate" "$goal" \
    'scripts/solution-signoff-gate.sh'
  assert_file_contains "SG12: improve uses executable signoff gate" "$improve" \
    'scripts/solution-signoff-gate.sh'

  rm -rf "$sandbox"
}
