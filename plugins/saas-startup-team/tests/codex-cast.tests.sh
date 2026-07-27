# Slim codex-cast adapter regressions (sourced by run-tests.sh).
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "codex-cast.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_codex_cast() {
  echo -e "\n${CYAN}Suite CC: codex-cast adapter${NC}"
  local cast="$PLUGIN_ROOT/scripts/codex-cast.sh"
  local route="$PLUGIN_ROOT/scripts/delivery-route.sh"
  local repo bin ec out jsonl last result

  assert_file_exists "CC0: codex-cast exists" "$cast"
  assert_file_not_exists "CC0b: codex-run-role removed" "$PLUGIN_ROOT/scripts/codex-run-role.sh"
  assert_file_not_exists "CC0c: codex-implement removed" "$PLUGIN_ROOT/scripts/codex-implement.sh"
  assert_file_not_exists "CC0d: tech-founder-codex agent removed" \
    "$PLUGIN_ROOT/agents/tech-founder-codex.md"
  assert_file_not_exists "CC0e: tech-founder-codex-maintain removed" \
    "$PLUGIN_ROOT/agents/tech-founder-codex-maintain.md"
  lines=$(wc -l < "$cast" | tr -d ' ')
  [ "$lines" -le 350 ] || {
    echo -e "  ${RED}FAIL${NC} CC0f: adapter LOC $lines exceeds 350"
    FAILURES+=("CC0f: adapter LOC $lines exceeds 350")
    return 0
  }
  echo -e "  ${GREEN}PASS${NC} CC0f: adapter LOC $lines <= 350"

  # ---- fixtures ----
  repo=$(mktemp -d)
  bin=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf 'base\n' > "$repo/app.txt"
  printf 'do the work\n' > "$repo/prompt.md"
  git -C "$repo" add app.txt prompt.md
  git -C "$repo" commit -qm base
  sha=$(git -C "$repo" rev-parse HEAD)

  cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
# Fake Codex CLI for adapter unit tests.
emit_message() {
  jq -cn --arg text "$1" \
    '{type:"item.completed",item:{type:"agent_message",text:$text}}'
}
# Consume prompt from stdin (or -).
if [ "${1:-}" = exec ] || true; then
  :
fi
prompt_sink=/dev/null
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output-last-message) LAST_OUT=$2; shift 2 ;;
    -C|--cd) CD=$2; shift 2 ;;
    -m|--model) MODEL=$2; shift 2 ;;
    -s|--sandbox) SANDBOX=$2; shift 2 ;;
    --dangerously-bypass-approvals-and-sandbox) BYPASS=1; shift ;;
    --json|--ephemeral) shift ;;
    -c) shift 2 ;;
    -) cat >/dev/null; shift ;;
    exec) shift ;;
    *) shift ;;
  esac
done
: "${CD:=.}"
case "${FAKE_CODEX_MODE:-valid}" in
  valid)
    msg='ok verdict'
    emit_message "$msg"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2,"cached_input_tokens":0}}'
    [ -n "${LAST_OUT:-}" ] && printf '%s\n' "$msg" > "$LAST_OUT"
    ;;
  mutate-review)
    printf 'mutated\n' > "$CD/app.txt"
    msg='I edited the tree'
    emit_message "$msg"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2,"cached_input_tokens":0}}'
    [ -n "${LAST_OUT:-}" ] && printf '%s\n' "$msg" > "$LAST_OUT"
    ;;
  hang)
    trap '' TERM
    while :; do sleep 1; done
    ;;
  malformed)
    printf '%s\n' '{not-json'
    [ -n "${LAST_OUT:-}" ] && printf 'partial\n' > "$LAST_OUT"
    ;;
  no-terminal)
    emit_message 'no complete event'
    [ -n "${LAST_OUT:-}" ] && printf 'no complete event\n' > "$LAST_OUT"
    ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$bin/codex"

  # CC1: happy path implement (workspace-write, never unrestricted by default)
  json_out=$(mktemp)
  PATH="$bin:$PATH" FAKE_CODEX_MODE=valid bash "$cast" \
    --worktree "$repo" --mode implement --provider openai \
    --model gpt-5.6-sol --effort high --timeout 30s \
    --prompt-file "$repo/prompt.md" --json-out "$json_out" \
    --env FAKE_CODEX_MODE >/dev/null 2>&1 || true
  out=$(cat "$json_out")
  assert_equals "CC1a: success outcome" "$(jq -r .outcome <<<"$out")" "success"
  assert_equals "CC1b: binds commit SHA" "$(jq -r .commit_sha <<<"$out")" "$sha"
  assert_equals "CC1c: binds worktree" "$(jq -r .worktree <<<"$out")" "$(cd "$repo" && pwd -P)"
  assert_equals "CC1d: binds provider" "$(jq -r .provider <<<"$out")" "openai"
  assert_equals "CC1e: unrestricted false by default" "$(jq -r .unrestricted <<<"$out")" "false"
  assert_equals "CC1f: timeout_outcome completed" "$(jq -r .timeout_outcome <<<"$out")" "completed"

  # CC2: worktree mismatch (subdir of repo)
  mkdir -p "$repo/sub"
  ec=0
  out=$(PATH="$bin:$PATH" bash "$cast" \
    --worktree "$repo/sub" --mode implement --provider openai \
    --model gpt-5.6-sol --effort high --timeout 30s \
    --prompt-file "$repo/prompt.md" 2>&1) || ec=$?
  assert_exit_code "CC2a: worktree mismatch exits 4" "$ec" 4
  assert_output_contains "CC2b: mismatch message" "$out" "worktree mismatch"

  # CC3: review mode rejects mutation
  git -C "$repo" checkout -q -- app.txt
  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_MODE=mutate-review bash "$cast" \
    --worktree "$repo" --mode review --provider openai \
    --model gpt-5.6-sol --effort medium --timeout 30s \
    --prompt-file "$repo/prompt.md" --json-out "$json_out" \
    --env FAKE_CODEX_MODE >/dev/null 2>&1 || ec=$?
  out=$(cat "$json_out")
  assert_exit_code "CC3a: mutated review fails" "$ec" 1
  assert_equals "CC3b: mutation_rejected true" "$(jq -r .mutation_rejected <<<"$out")" "true"
  assert_equals "CC3c: outcome mutation_rejected" "$(jq -r .outcome <<<"$out")" "mutation_rejected"
  # restore
  git -C "$repo" checkout -q -- app.txt

  # CC4: timeout
  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_MODE=hang bash "$cast" \
    --worktree "$repo" --mode implement --provider openai \
    --model gpt-5.6-sol --effort high --timeout 1s \
    --prompt-file "$repo/prompt.md" --json-out "$json_out" \
    --env FAKE_CODEX_MODE >/dev/null 2>&1 || ec=$?
  out=$(cat "$json_out")
  assert_equals "CC4a: timeout outcome" "$(jq -r .timeout_outcome <<<"$out")" "timed_out"
  assert_equals "CC4b: outcome timeout" "$(jq -r .outcome <<<"$out")" "timeout"
  [ "$ec" -eq 124 ] || [ "$ec" -eq 137 ] || [ "$ec" -eq 1 ] || {
    echo -e "  ${RED}FAIL${NC} CC4c: timeout exit expected 124/137/1 got $ec"
    FAILURES+=("CC4c: timeout exit $ec")
  }
  [ "$ec" -eq 124 ] || [ "$ec" -eq 137 ] || [ "$ec" -eq 1 ] \
    && echo -e "  ${GREEN}PASS${NC} CC4c: timeout exit $ec"

  # CC5: malformed output
  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_MODE=malformed bash "$cast" \
    --worktree "$repo" --mode implement --provider openai \
    --model gpt-5.6-sol --effort high --timeout 30s \
    --prompt-file "$repo/prompt.md" --json-out "$json_out" \
    --env FAKE_CODEX_MODE >/dev/null 2>&1 || ec=$?
  out=$(cat "$json_out")
  assert_exit_code "CC5a: malformed exits non-zero" "$ec" 1
  assert_equals "CC5b: malformed_output outcome" "$(jq -r .outcome <<<"$out")" "malformed_output"

  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_MODE=no-terminal bash "$cast" \
    --worktree "$repo" --mode implement --provider openai \
    --model gpt-5.6-sol --effort high --timeout 30s \
    --prompt-file "$repo/prompt.md" --json-out "$json_out" \
    --env FAKE_CODEX_MODE >/dev/null 2>&1 || ec=$?
  out=$(cat "$json_out")
  assert_exit_code "CC5c: no-terminal exits non-zero" "$ec" 1
  assert_equals "CC5d: no-terminal malformed" "$(jq -r .outcome <<<"$out")" "malformed_output"
  rm -f "$json_out"

  # CC6: risk floor (delivery-route) still escalates sensitive, not light routing
  task=$(mktemp)
  printf 'Fix the typo in docs/setup.md.\n' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "CC6a: non-sensitive is standard (no light route)" \
    "$(jq -r .profile <<<"$out")" "standard"

  printf 'Update the payment checkout flow.\n' > "$task"
  ec=0
  out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "CC6b: payment escalates" "$ec" 20
  assert_equals "CC6c: sensitive deep" "$(jq -r .profile <<<"$out")" "deep"
  assert_equals "CC6d: sensitive true" "$(jq -r .sensitive <<<"$out")" "true"

  printf 'Fix a bug in app.txt.\n' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "CC6e: routine stays standard" "$(jq -r .profile <<<"$out")" "standard"
  rm -f "$task"

  # CC7: static: unrestricted never implicit; no ignore-rules by default
  assert_file_contains "CC7a: unrestricted is explicit flag only" "$cast" '--unrestricted'
  assert_file_not_contains "CC7b: no default ignore-rules" "$cast" '--ignore-rules'
  assert_file_not_contains "CC7c: no default ignore-user-config" "$cast" '--ignore-user-config'
  assert_file_contains "CC7d: review uses read-only sandbox" "$cast" 'read-only'
  assert_file_contains "CC7e: implement uses workspace-write" "$cast" 'workspace-write'

  rm -rf "$repo" "$bin"
}

test_codex_cast
