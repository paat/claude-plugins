# Hook root resolution: unbound fail-open; bound-missing fail-closed (PreToolUse).
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "hooks-resolve.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_hooks_resolve() {
  echo -e "\n${CYAN}Suite HR: hook root resolve after marketplace refresh${NC}"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
  local pre_write pre_bash workdir ec out

  assert_file_exists "HR0: hooks.json" "$hooks_file"
  assert_file_contains "HR0b: unbound skip message" "$hooks_file" \
    'plugin root unset; skipping'
  assert_file_contains "HR0c: no PWD/.. fallback" "$hooks_file" 'plugin root unset'
  assert_file_not_contains "HR0d: removed parent-dir fallback" "$hooks_file" '"$PWD/.."'

  pre_write=$(jq -r '
    .hooks.PreToolUse[]
    | select(.matcher | test("Write"))
    | .hooks[0].command' "$hooks_file")
  pre_bash=$(jq -r '
    .hooks.PreToolUse[]
    | select(.matcher == "Bash")
    | .hooks[0].command' "$hooks_file")
  [ -n "$pre_write" ] && [ -n "$pre_bash" ]

  workdir=$(mktemp -d)

  # Unbound roots → fail open (recovery after marketplace refresh)
  ec=0
  out=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT= CODEX_PLUGIN_ROOT= \
    bash -c "$pre_write" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR1: pre-write unbound exits 0" "$ec" 0
  assert_output_contains "HR1b: pre-write unbound skip" "$out" 'plugin root unset'

  ec=0
  out=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT= CODEX_PLUGIN_ROOT= \
    bash -c "$pre_bash" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR2: pre-bash unbound exits 0" "$ec" 0
  assert_output_contains "HR2b: pre-bash unbound skip" "$out" 'plugin root unset'

  # Bound root but missing dispatch → fail closed (real install break)
  ec=0
  out=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$workdir" CODEX_PLUGIN_ROOT= \
    bash -c "$pre_write" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR3: pre-write bound-missing exits 2" "$ec" 2
  assert_output_contains "HR3b: pre-write critical not found" "$out" \
    'critical hook target not found'

  ec=0
  out=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$workdir" CODEX_PLUGIN_ROOT= \
    bash -c "$pre_bash" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR4: pre-bash bound-missing exits 2" "$ec" 2

  # Healthy root resolves and runs dispatch (empty stdin is ok for dispatch entry)
  ec=0
  out=$(cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CODEX_PLUGIN_ROOT= \
    bash -c "$pre_write" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR5: pre-write healthy root exits 0" "$ec" 0

  rm -rf "$workdir"
}

test_hooks_resolve
