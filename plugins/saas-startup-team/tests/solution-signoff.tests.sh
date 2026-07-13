# Solution-signoff validation and linked-worktree refresh regressions.
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
  local sandbox source target other source_file target_file ec out before after checkout_line gate_line

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
  target="$sandbox/maintain"
  git init -q "$source"
  git -C "$source" config user.email test@example.com
  git -C "$source" config user.name Test
  printf '.startup/go-live/\n' > "$source/.gitignore"
  printf 'tracked\n' > "$source/app.txt"
  git -C "$source" add .gitignore app.txt
  git -C "$source" commit -qm base
  git -C "$source" worktree add -q --detach "$target" HEAD
  source_file="$source/.startup/go-live/solution-signoff.md"
  target_file="$target/.startup/go-live/solution-signoff.md"
  mkdir -p "$(dirname "$source_file")" "$(dirname "$target_file")"

  printf 'signed-v1\n' > "$source_file"
  printf 'stale\n' > "$target_file"
  before=$(git hash-object --stdin < "$source_file")
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  after=$(git hash-object --stdin < "$source_file")
  assert_exit_code "SG3: ignored signoff refresh succeeds" "$ec" 0
  assert_equals "SG4: fresh worktree receives source signoff" "$(cat "$target_file")" "signed-v1"
  assert_equals "SG5: source signoff content is unchanged" "$after" "$before"
  assert_equals "SG6: target worktree remains clean" "$(git -C "$target" status --porcelain)" ""

  printf 'signed-v2\n' > "$source_file"
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  assert_exit_code "SG7: reused worktree refresh succeeds" "$ec" 0
  assert_equals "SG8: reused worktree cannot retain stale content" "$(cat "$target_file")" "signed-v2"

  mkdir -p "$sandbox/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf partial > "$2"' 'exit 41' > "$sandbox/bin/cp"
  chmod +x "$sandbox/bin/cp"
  printf 'signed-v3\n' > "$source_file"
  ec=0; out=$(PATH="$sandbox/bin:$PATH" bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  assert_exit_code "SG9: interrupted copy fails closed" "$ec" 1
  assert_file_not_exists "SG10: interrupted copy removes stale target" "$target_file"
  assert_equals "SG11: interrupted copy leaves no temporary file" \
    "$(find "$(dirname "$target_file")" -maxdepth 1 -name 'solution-signoff.md.tmp.*' -print)" ""

  cat > "$sandbox/bin/cp" <<'SH'
#!/usr/bin/env bash
set -e
/bin/cp "$1" "$2"
printf 'replaced-during-copy\n' > "$RACE_SOURCE"
SH
  chmod +x "$sandbox/bin/cp"
  printf 'signed-race\n' > "$source_file"
  ec=0; out=$(RACE_SOURCE="$source_file" PATH="$sandbox/bin:$PATH" \
    bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  assert_exit_code "SG11a: concurrent source replacement fails closed" "$ec" 1
  assert_file_not_exists "SG11b: concurrent replacement removes copied target" "$target_file"
  assert_equals "SG11c: concurrent replacement leaves no temporary file" \
    "$(find "$(dirname "$target_file")" -maxdepth 1 -name 'solution-signoff.md.tmp.*' -print)" ""

  rm -f "$source_file"
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  assert_exit_code "SG12: absent source signoff fails" "$ec" 1
  assert_file_not_exists "SG13: absent source removes stale target" "$target_file"
  assert_equals "SG14: stale removal keeps target clean" "$(git -C "$target" status --porcelain)" ""

  printf 'outside\n' > "$sandbox/outside-signoff"
  ln -s "$sandbox/outside-signoff" "$source_file"
  printf 'stale-again\n' > "$target_file"
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  assert_exit_code "SG15: symlink source fails" "$ec" 1
  assert_file_not_exists "SG16: symlink source removes stale target" "$target_file"
  assert_equals "SG17: symlink source is not mutated" "$(readlink "$source_file")" "$sandbox/outside-signoff"

  rm -f "$source_file"
  printf 'signed-v4\n' > "$source_file"
  ec=0; out=$(bash "$script" --source-root "$source" 2>&1) || ec=$?
  assert_exit_code "SG18: validation-only mode accepts regular signoff" "$ec" 0

  other="$sandbox/other"
  git init -q "$other"
  git -C "$other" config user.email test@example.com
  git -C "$other" config user.name Test
  printf '.startup/go-live/\n' > "$other/.gitignore"
  printf 'other\n' > "$other/app.txt"
  git -C "$other" add .gitignore app.txt
  git -C "$other" commit -qm base
  mkdir -p "$other/.startup/go-live"
  printf 'other-stale\n' > "$other/.startup/go-live/solution-signoff.md"
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$other" 2>&1) || ec=$?
  assert_exit_code "SG19: unrelated target repository fails" "$ec" 1
  assert_equals "SG20: unrelated target is untouched" \
    "$(cat "$other/.startup/go-live/solution-signoff.md")" "other-stale"

  printf 'validated-target\n' > "$target_file"
  printf 'dirty\n' >> "$target/app.txt"
  ec=0; out=$(bash "$script" --source-root "$source" --target-root "$target" 2>&1) || ec=$?
  assert_exit_code "SG21: dirty target worktree fails" "$ec" 1
  assert_equals "SG22: dirty-target refusal preserves prior signoff" \
    "$(cat "$target_file")" "validated-target"
  git -C "$target" checkout -- app.txt

  assert_file_contains "SG23: maintain uses executable signoff gate" "$maintain" \
    'scripts/solution-signoff-gate.sh'
  checkout_line=$(grep -nF 'git checkout --detach "origin/$default"' "$maintain" | head -1 | cut -d: -f1)
  gate_line=$(grep -nF 'scripts/solution-signoff-gate.sh' "$maintain" | head -1 | cut -d: -f1)
  assert_equals "SG24: maintain gates immediately after worktree reset" \
    "$gate_line" "$((checkout_line + 1))"
  assert_file_contains "SG25: maintain pins invocation source and target" "$maintain" \
    '--source-root "$REPO_ROOT" --target-root "$WT"'
  assert_file_contains "SG26: goal-deliver uses executable signoff gate" "$goal" \
    'scripts/solution-signoff-gate.sh'
  assert_file_not_contains "SG27: goal-deliver has no bare signoff ls" "$goal" \
    'ls .startup/go-live/solution-signoff.md'
  assert_file_contains "SG28: improve uses executable signoff gate" "$improve" \
    'scripts/solution-signoff-gate.sh'
  assert_file_not_contains "SG29: improve has no bare signoff ls" "$improve" \
    'ls .startup/go-live/solution-signoff.md'

  rm -rf "$sandbox"
}

test_solution_signoff_gate
