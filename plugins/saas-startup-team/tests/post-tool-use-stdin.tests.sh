# PostToolUse handlers must consume large payloads before every exit path.
declare -F assert_equals >/dev/null 2>&1 || {
  echo "post-tool-use-stdin.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

post_tool_pipeline_statuses() {
  local workdir="$1" command="$2" plugin_root="${3:-}" statuses
  (
    set +e
    cd "$workdir" || exit 1
    if [ -n "$plugin_root" ]; then
      dd if=/dev/zero bs=65536 count=16 2>/dev/null \
        | CLAUDE_PLUGIN_ROOT="$plugin_root" CODEX_PLUGIN_ROOT= bash -c "$command" \
          >/dev/null 2>&1
    else
      dd if=/dev/zero bs=65536 count=16 2>/dev/null \
        | CLAUDE_PLUGIN_ROOT= CODEX_PLUGIN_ROOT= bash -c "$command" \
          >/dev/null 2>&1
    fi
    statuses=("${PIPESTATUS[@]}")
    printf '%s %s' "${statuses[0]}" "${statuses[1]}"
  )
}

test_post_tool_use_stdin_drain() {
  echo -e "\n${CYAN}Suite PTU: PostToolUse stdin draining${NC}"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json" workdir command handler statuses count=0

  workdir=$(mktemp -d)
  command=$(jq -r '.hooks.PostToolUse[]
    | select(any(.hooks[]; .command | contains("compact-state.sh")))
    | .hooks[0].command' "$hooks_file")
  statuses=$(post_tool_pipeline_statuses "$workdir" "$command" "$PLUGIN_ROOT")
  assert_equals "PTU1: compact-state drains a large payload" "$statuses" "0 0"

  while IFS= read -r command; do
    count=$((count + 1))
    handler=$(sed -n 's/.*p=\([^;]*\).*/\1/p' <<< "$command")
    statuses=$(post_tool_pipeline_statuses "$workdir" "$command")
    assert_equals "PTU2.$count: missing-root resolver drains stdin ($handler)" "$statuses" "0 0"
  done < <(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file")
  assert_equals "PTU3: every PostToolUse resolver was exercised" "$count" "13"
  rm -rf "$workdir"
}

test_post_tool_use_stdin_drain
