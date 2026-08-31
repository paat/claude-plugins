# Hook root resolution: unavailable dispatch soft-skips; dispatched gates remain fail-closed.
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
  out=$(cd "$workdir" && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT= CODEX_PLUGIN_ROOT= \
    bash -c "$pre_write" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR1: pre-write unbound exits 0" "$ec" 0
  assert_output_contains "HR1b: pre-write unbound skip" "$out" 'plugin root unset'

  ec=0
  out=$(cd "$workdir" && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT= CODEX_PLUGIN_ROOT= \
    bash -c "$pre_bash" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR2: pre-bash unbound exits 0" "$ec" 0
  assert_output_contains "HR2b: pre-bash unbound skip" "$out" 'plugin root unset'

  # Bound root but missing dispatch → fail open (incomplete install recovery).
  local root mode command
  for root in CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT; do
    for mode in pre_write pre_bash; do
      command=${!mode}
      ec=0
      out=$(cd "$workdir" && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT= CODEX_PLUGIN_ROOT= \
        env "$root=$workdir/missing-root" bash -c "$command" </dev/null 2>&1) || ec=$?
      assert_exit_code "HR3: $root $mode missing exits 0" "$ec" 0
      assert_output_contains "HR3b: $root $mode unavailable skip" "$out" \
        'hook target unavailable'
    done
  done

  # A dispatcher without its gate is also an incomplete root and must fall through.
  local partial_root="$workdir/partial-root"
  mkdir -p "$partial_root/hooks"
  cp "$PLUGIN_ROOT/hooks/dispatch.sh" "$partial_root/hooks/dispatch.sh"
  for mode in pre_write pre_bash; do
    command=${!mode}
    ec=0
    out=$(cd "$workdir" && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT="$partial_root" CODEX_PLUGIN_ROOT= \
      bash -c "$command" </dev/null 2>&1) || ec=$?
    assert_exit_code "HR4: $mode dispatch without gate exits 0" "$ec" 0
    assert_output_contains "HR4b: $mode dispatch without gate unavailable skip" "$out" \
      'hook target unavailable'
  done

  # A gate without its mode dependency is also incomplete and must fall through.
  mkdir -p "$partial_root/scripts"
  cp "$PLUGIN_ROOT/scripts/gate.sh" "$partial_root/scripts/gate.sh"
  for mode in pre_write pre_bash; do
    command=${!mode}
    ec=0
    out=$(cd "$workdir" && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT="$partial_root" CODEX_PLUGIN_ROOT= \
      bash -c "$command" </dev/null 2>&1) || ec=$?
    assert_exit_code "HR5: $mode missing gate dependency exits 0" "$ec" 0
    assert_output_contains "HR5b: $mode missing gate dependency unavailable skip" "$out" \
      'hook target unavailable'
  done

  # A healthy alternate root is used before local/marketplace fallbacks.
  ec=0
  out=$(cd "$workdir" && printf '%s' '{"tool_input":{"file_path":"x.json","content":"{"}}' \
    | HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT="$workdir/missing-root" CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c "$pre_write" 2>&1) || ec=$?
  assert_exit_code "HR6: alternate root blocks invalid JSON" "$ec" 2
  assert_output_contains "HR6b: alternate root reached gate" "$out" 'JSON syntax error'

  # A source-checkout fallback runs the dispatcher and retains intentional blocks.
  ec=0
  out=$(cd "$PLUGIN_ROOT/../.." && printf '%s' '{"tool_input":{"file_path":"x.json","content":"{"}}' \
    | HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT="$workdir/missing-root" CODEX_PLUGIN_ROOT= bash -c "$pre_write" 2>&1) || ec=$?
  assert_exit_code "HR7: source fallback blocks invalid JSON" "$ec" 2
  assert_output_contains "HR7b: source fallback reached gate" "$out" 'JSON syntax error'

  ec=0
  out=$(cd "$PLUGIN_ROOT/../.." && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT="$workdir/missing-root" CODEX_PLUGIN_ROOT= \
    bash -c "$pre_bash" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR7c: source fallback runs pre-bash" "$ec" 0
  assert_output_not_contains "HR7d: source pre-bash does not skip" "$out" 'hook target unavailable'

  # A marketplace clone is also a usable fallback.
  local marketplace_root="$workdir/home/.claude/plugins/marketplaces/paat-plugins/plugins/saas-startup-team"
  mkdir -p "$marketplace_root/hooks" "$marketplace_root/scripts"
  cp "$PLUGIN_ROOT/hooks/dispatch.sh" "$marketplace_root/hooks/dispatch.sh"
  cp "$PLUGIN_ROOT/scripts/gate.sh" "$marketplace_root/scripts/gate.sh"
  cp "$PLUGIN_ROOT/scripts/pii-gate.sh" "$marketplace_root/scripts/pii-gate.sh"
  ec=0
  out=$(cd "$workdir" && printf '%s' '{"tool_input":{"file_path":"x.json","content":"{"}}' \
    | HOME="$workdir/home" CLAUDE_PLUGIN_ROOT="$workdir/missing-root" CODEX_PLUGIN_ROOT= bash -c "$pre_write" 2>&1) || ec=$?
  assert_exit_code "HR8: marketplace fallback blocks invalid JSON" "$ec" 2
  assert_output_contains "HR8b: marketplace fallback reached gate" "$out" 'JSON syntax error'

  local other_marketplace_root="$workdir/home/.claude/plugins/marketplaces/another/plugins/saas-startup-team"
  mkdir -p "$other_marketplace_root"
  cp -R "$marketplace_root/hooks" "$marketplace_root/scripts" "$other_marketplace_root/"
  ec=0
  out=$(cd "$workdir" && printf '%s' '{"tool_input":{"file_path":"x.json","content":"{"}}' \
    | HOME="$workdir/home" CLAUDE_PLUGIN_ROOT="$workdir/missing-root" CODEX_PLUGIN_ROOT= bash -c "$pre_write" 2>&1) || ec=$?
  assert_equals "HR8c: N>1 marketplace trees still reach gate" \
    "$ec:$([[ "$out" == *'JSON syntax error'* ]] && printf yes)" "2:yes"

  # Healthy root resolves and runs dispatch (empty stdin is ok for dispatch entry)
  ec=0
  out=$(cd "$workdir" && HOME="$workdir/no-home" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CODEX_PLUGIN_ROOT= \
    bash -c "$pre_write" </dev/null 2>&1) || ec=$?
  assert_exit_code "HR9: pre-write healthy root exits 0" "$ec" 0

  rm -rf "$workdir"
}

test_hooks_resolve
