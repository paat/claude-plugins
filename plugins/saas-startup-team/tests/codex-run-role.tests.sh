# Codex launcher terminal-proof and bounded-output regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "codex-run-role.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_codex_run_role_terminal_safety() {
  echo -e "\n${CYAN}Suite CR: Codex role terminal safety${NC}"
  local repo bin script ec out logs events called guard_dir oldest auth snapshot receipt victim moved_logs
  local predicted special linked_parent real_parent started elapsed evidence_bytes
  local eval_dir observed target_size namespace_prompt args_capture ambient_home product_file
  local signal child_pid signal_seen signal_out runner_pid holder_pid
  local attempt stress_ok completed target expected i parent_run
  repo=$(mktemp -d); bin=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf 'review this\n' > "$repo/task.md"
  printf '%s\n' 'Review literal $(touch namespace-injected) and TOKEN=fixture-secret.' \
    > "$repo/namespace-task.md"
  git -C "$repo" add task.md namespace-task.md; git -C "$repo" commit -qm base
  script="$PLUGIN_ROOT/scripts/codex-run-role.sh"
  logs="$repo/.startup/test-codex"; events="$repo/.startup/test-events.jsonl"
  called="$repo/fake-called"
cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_CALLED:-}" ] || : > "$FAKE_CALLED"
[ -z "${FAKE_ARGS_CAPTURE:-}" ] || printf '%s\n' "$*" > "$FAKE_ARGS_CAPTURE"
exec 7>&-
emit_message() {
  jq -cn --arg text "$1" \
    '{type:"item.completed",item:{type:"agent_message",text:$text}}'
}
if [ -n "${FAKE_PROMPT_CAPTURE:-}" ]; then
  cat > "$FAKE_PROMPT_CAPTURE"
else
  cat >/dev/null
fi
[ -z "${FAKE_STATE_APPEND:-}" ] || printf x >> "$CODEX_HOME/state_5.sqlite"
[ -z "${FAKE_PRODUCT_FILE:-}" ] \
  || dd if=/dev/zero of="$FAKE_PRODUCT_FILE" bs=2048 count=1 status=none
case "${FAKE_CODEX_MODE:-valid}" in
  valid)
    emit_message $'verdict one\033[31m\001\nverdict two\n'
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  no-terminal)
    emit_message 'unproven result'
    ;;
  no-message)
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  fail)
    emit_message 'partial verdict'
    printf 'failure stderr\033[2J\002\n' >&2
    printf '%s\n' '{"type":"turn.failed","error":{"message":"failed"}}'
    exit 7
    ;;
  malformed)
    emit_message 'unproven malformed result'
    printf '%s\n' '{malformed'
    ;;
  oversized-json)
    emit_message 'must not be reported as success'
    head -c 65536 /dev/zero | tr '\0' x
    printf '\n%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  oversized-stderr)
    emit_message 'must not be reported as success'
    head -c 65536 /dev/zero | tr '\0' x >&2
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  oversized-message)
    message=$(head -c 65536 /dev/zero | tr '\0' x)
    emit_message "$message"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  replace-race)
    case "${FAKE_REPLACE_SLOT:-}" in
      jsonl)
        target=$(find -P "${FAKE_EVIDENCE_DIR:?}" -maxdepth 1 \
          -type f -name '.codex-jsonl.*' -print -quit) || exit 9
        [ -n "$target" ] || exit 9
        rm -f -- "$target" || exit 9
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":99,"output_tokens":99,"cached_input_tokens":0}}' > "$target" || exit 9
        emit_message 'real message'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
        ;;
      stderr)
        target=$(find -P "${FAKE_EVIDENCE_DIR:?}" -maxdepth 1 \
          -type f -name '.codex-stderr.*' -print -quit) || exit 9
        [ -n "$target" ] || exit 9
        rm -f -- "$target" || exit 9
        printf 'forged diagnostic\n' > "$target" || exit 9
        emit_message 'real message'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
        ;;
      last-message)
        target=$(find -P "${FAKE_EVIDENCE_DIR:?}" -maxdepth 1 \
          -type f -name '.codex-last-message.*' -print -quit) || exit 9
        [ -n "$target" ] || exit 9
        rm -f -- "$target" || exit 9
        printf 'forged message\n' > "$target" || exit 9
        emit_message 'real message'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
        ;;
      *) exit 9 ;;
    esac
    ;;
  rapid-output)
    emit_message 'bounded failure'
    dd if=/dev/zero bs=1048576 count=32 status=none || true
    stat -Lc '%s' -- "/proc/$$/fd/1" > "${FAKE_OBSERVED_SIZE:?}" || exit 9
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  hang)
    trap '' TERM
    while :; do sleep 1; done
    ;;
  signal-hang)
    printf '%s\n' "$$" > "${FAKE_CHILD_PID:?}"
    trap 'printf HUP > "$FAKE_SIGNAL_SEEN"; exit 129' HUP
    trap 'printf INT > "$FAKE_SIGNAL_SEEN"; exit 130' INT
    trap 'printf TERM > "$FAKE_SIGNAL_SEEN"; exit 143' TERM
    while :; do sleep 1; done
    ;;
  inherited-writer)
    (trap '' HUP INT TERM; while :; do sleep 1; done) &
    printf '%s\n' "$!" > "${FAKE_HOLDER_PID:?}"
    emit_message 'worker exited but descendant retained evidence writers'
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  immediate-signal)
    printf '%s\n' "$$" > "${FAKE_CHILD_PID:?}"
    trap 'printf TERM > "$FAKE_SIGNAL_SEEN"; exit 143' TERM
    while [ ! -s "${FAKE_SIGNAL_TARGET:?}" ]; do :; done
    kill -TERM "$(cat "$FAKE_SIGNAL_TARGET")"
    while :; do :; done
    ;;
esac
SH
  cat > "$bin/chmod" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_CHMOD_CODEX_FAIL:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in */.codex-*) exit 1 ;; esac
  done
fi
exec /bin/chmod "$@"
SH
  cat > "$bin/truncate" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_TRUNCATE_FAIL:-0}" != 1 ] || [ "${2:-}" = 0 ] || exit 1
exec /usr/bin/truncate "$@"
SH
  chmod +x "$bin/codex" "$bin/chmod" "$bin/truncate"

  ln -s task.md "$repo/task-link.md"; rm -f "$called"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=input-link \
    bash "$script" --role qa --profile deep --task-file task-link.md 2>&1) || ec=$?
  assert_exit_code "CR0a: symlinked task input is rejected" "$ec" 4
  assert_file_not_exists "CR0b: symlinked task input never launches Codex" "$called"

  mkdir "$repo/eval-real"; printf 'absolute evaluation task\n' > "$repo/eval-real/task.md"
  ln -s eval-real "$repo/eval-link"; rm -f "$called"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=input-parent-link \
    bash "$script" --role qa --profile deep --task-file "$repo/eval-link/task.md" 2>&1) || ec=$?
  assert_exit_code "CR0c: task input with a symlinked ancestor is rejected" "$ec" 4
  assert_file_not_exists "CR0d: unsafe input ancestor never launches Codex" "$called"

  eval_dir=$(mktemp -d); printf 'external evaluation task\n' > "$eval_dir/task.md"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=absolute-input \
    bash "$script" --role qa --profile deep --task-file "$eval_dir/task.md" 2>&1) || ec=$?
  assert_exit_code "CR0e: safe absolute evaluation task input remains supported" "$ec" 0
  rm -rf -- "$eval_dir"

  namespace_prompt="$bin/pid-namespace.prompt"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_PROMPT_CAPTURE="$namespace_prompt" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" \
    SAAS_RUN_ID=pid-namespace unshare --user --map-current-user --pid --fork \
      --kill-child=KILL -- bash "$script" --role qa --profile deep \
      --task-file namespace-task.md 2>&1) || ec=$?
  assert_exit_code "CR0i: inherited task and evidence FDs survive a PID namespace" "$ec" 0
  assert_file_contains "CR0j: namespace launch passes task bytes literally over stdin" \
    "$namespace_prompt" 'Review literal $(touch namespace-injected) and TOKEN=fixture-secret.'
  assert_file_not_exists "CR0k: namespace task text cannot become a shell path injection" \
    "$repo/namespace-injected"
  assert_output_not_contains "CR0l: namespace task secret is not copied to terminal evidence" \
    "$out" 'fixture-secret'

  dd if=/dev/zero of="$repo/oversized-task.md" bs=2048 count=1 status=none
  rm -f "$called"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_CODEX_TASK_INPUT_MAX_BYTES=1024 SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=oversized-input \
    bash "$script" --role qa --profile deep --task-file oversized-task.md 2>&1) || ec=$?
  assert_exit_code "CR0f: oversized task input is rejected" "$ec" 4
  assert_output_contains "CR0g: oversized task input failure is explicit" "$out" \
    'task input changed, is unsafe, or exceeds its byte budget'
  assert_file_not_exists "CR0h: oversized task input never launches Codex" "$called"

  args_capture="$repo/npm-shim-args"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_ARGS_CAPTURE="$args_capture" \
    SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=valid-run \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR1: valid terminal event plus role message succeeds" "$ec" 0
  assert_file_not_contains "CR1a: npm-style descriptor closure needs no last-message FD" \
    "$args_capture" '--output-last-message'
  assert_output_contains "CR2: terminal output names the retained full log" "$out" 'full-log='
  assert_output_contains "CR3: every surfaced verdict line has a worker prefix" "$out" 'codex-worker: verdict two'
  if [[ "$out" == *$'\033'* ]]; then
    assert_equals "CR4: worker controls are removed from terminal output" present absent
  else
    assert_equals "CR4: worker controls are removed from terminal output" absent absent
  fi

  assert_equals "CR4a: absent parent preserves unparented events" \
    "$(jq -s '.[-2:] | length == 2 and all(.[]; .parent_run_id == null)' "$events")" true
  parent_run=run-11111111111111111111111111111111
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=parented-child \
    SAAS_PARENT_RUN_ID="$parent_run" \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR4b: canonical parent is accepted" "$ec" 0
  assert_equals "CR4c: every parented helper event carries the root" \
    "$(jq -s --arg parent "$parent_run" \
      '.[-2:] | length == 2 and all(.[]; .parent_run_id == $parent)' "$events")" true
  rm -f "$called"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" \
    SAAS_RUN_ID=invalid-parent SAAS_PARENT_RUN_ID=not-canonical \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR4d: invalid parent is rejected" "$ec" 2
  assert_file_not_exists "CR4e: invalid parent never launches Codex" "$called"
  rm -f "$called"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" \
    SAAS_RUN_ID="$parent_run" SAAS_PARENT_RUN_ID="$parent_run" \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR4f: parent equal to child is rejected" "$ec" 2
  assert_file_not_exists "CR4g: equal parent never launches Codex" "$called"

  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=no-terminal \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=no-terminal \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR5: zero CLI status without terminal proof is failure" "$ec" 1
  assert_output_contains "CR6: missing terminal proof is preserved on stderr" "$out" \
    'successful CLI exit lacked a valid terminal turn.completed event'

  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=no-message \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=no-message \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR7: terminal event without final role message is failure" "$ec" 1
  assert_output_contains "CR8: missing final message diagnostic is retained" "$out" \
    'successful CLI exit produced no final role message'

  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=fail \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=failed-run \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR9: worker failure status propagates" "$ec" 7
  assert_output_contains "CR10: failure stderr is shown even with a last message" "$out" \
    'codex-worker: failure stderr'

  victim="$repo/output-victim"; printf 'outside-safe\n' > "$victim"
  for special in jsonl stderr last-message; do
    predicted="$logs/unsafe-$special-qa-1.jsonl"
    case "$special" in
      stderr) predicted="$predicted.stderr" ;;
      last-message) predicted="$predicted.last-message" ;;
    esac
    mkdir -p "$logs"; ln -s "$victim" "$predicted"; rm -f "$called"
    ec=0
    out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
      SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" \
      SAAS_RUN_ID="unsafe-$special" \
      bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
    assert_exit_code "CR10a/$special: predictable evidence symlink is rejected before Codex" "$ec" 4
    assert_file_not_exists "CR10b/$special: unsafe evidence leaf never launches Codex" "$called"
    assert_equals "CR10c/$special: evidence symlink target is untouched" \
      "$(cat "$victim")" outside-safe
    rm -f -- "$predicted"
  done

  for special in jsonl stderr last-message; do
    predicted="$logs/replaced-$special-qa-1.jsonl"
    rm -f "$called"; ec=0
    out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
      FAKE_CODEX_MODE=replace-race FAKE_REPLACE_SLOT="$special" \
      FAKE_EVIDENCE_DIR="$logs" SAAS_AGENT_EVENTS_FILE="$events" \
      SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID="replaced-$special" \
      bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
    assert_exit_code "CR10d/$special: replaced evidence inode is rejected" "$ec" 4
    assert_output_contains "CR10e/$special: evidence replacement failure is explicit" "$out" \
      'Codex evidence slot became unsafe'
    assert_file_not_exists "CR10f/$special: replaced evidence is never published" "$predicted"
  done

  predicted="$logs/unsafe-fifo-qa-1.jsonl.stderr"
  mkfifo "$predicted"; rm -f "$called"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=unsafe-fifo \
    timeout 3s bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10d: special-file stderr slot fails without blocking" "$ec" 4
  assert_file_not_exists "CR10e: special-file evidence slot never launches Codex" "$called"
  rm -f -- "$predicted"

  real_parent="$repo/real-log-parent"; linked_parent="$repo/linked-log-parent"
  mkdir "$real_parent"; ln -s "$real_parent" "$linked_parent"; rm -f "$called"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_FILE="$linked_parent/result.jsonl" \
    SAAS_RUN_ID=unsafe-parent \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10f: symlinked explicit-log parent is rejected" "$ec" 4
  assert_file_not_exists "CR10g: unsafe explicit-log parent never launches Codex" "$called"
  assert_equals "CR10h: unsafe explicit-log parent receives no output" \
    "$(find "$real_parent" -mindepth 1 -print -quit)" ""
  rm -f -- "$linked_parent"; rmdir "$real_parent"

  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=malformed \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=malformed \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10i: malformed zero-exit JSONL cannot prove success" "$ec" 1
  assert_output_contains "CR10j: malformed JSONL failure is explicit" "$out" \
    'lacked a valid terminal turn.completed event'

  for special in oversized-json oversized-stderr oversized-message; do
    ec=0
    out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE="$special" \
      SAAS_CODEX_JSONL_MAX_BYTES=1024 SAAS_CODEX_STDERR_MAX_BYTES=1024 \
      SAAS_CODEX_LAST_MESSAGE_MAX_BYTES=1024 SAAS_CODEX_LOG_RETENTION_BYTES=8192 \
      SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID="$special" \
      bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
    assert_exit_code "CR10k/$special: oversized evidence cannot produce success" "$ec" 1
    assert_output_contains "CR10l/$special: byte-budget failure is explicit" "$out" \
      'exceeded its bounded byte budget'
    predicted="$logs/$special-qa-1.jsonl"
    assert_equals "CR10m/$special: JSONL evidence stays within budget" \
      "$(test "$(stat -c %s "$predicted")" -le 1024 && echo yes || echo no)" yes
    assert_equals "CR10n/$special: stderr evidence stays within budget" \
      "$(test "$(stat -c %s "$predicted.stderr")" -le 1024 && echo yes || echo no)" yes
    assert_equals "CR10o/$special: last-message evidence stays within budget" \
      "$(test "$(stat -c %s "$predicted.last-message")" -le 1024 && echo yes || echo no)" yes
  done

  observed="$repo/rapid-observed"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=rapid-output \
    FAKE_OBSERVED_SIZE="$observed" SAAS_CODEX_JSONL_MAX_BYTES=8192 \
    SAAS_CODEX_STDERR_MAX_BYTES=1024 SAAS_CODEX_LAST_MESSAGE_MAX_BYTES=1024 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=rapid-output \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_equals "CR10p: rapid producer cannot report success" \
    "$([ "$ec" -ne 0 ] && echo yes || echo no)" yes
  assert_file_exists "CR10q: rapid producer observes the kernel file ceiling" "$observed"
  target_size=$(cat "$observed")
  assert_equals "CR10r: kernel ceiling bounds rapid output before polling" \
    "$([ "$target_size" -le 8192 ] && echo yes || echo no)" yes
  assert_output_contains "CR10s: rapid-output byte-budget failure is explicit" "$out" \
    'exceeded its bounded byte budget'
  assert_equals "CR10t: published rapid-output JSONL is within its declared cap" \
    "$([ "$(stat -c %s "$logs/rapid-output-qa-1.jsonl")" -le 8192 ] && echo yes || echo no)" yes

  rm -f "$called"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    FAKE_CHMOD_CODEX_FAIL=1 SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=chmod-failure \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10u: evidence chmod failure fails closed" "$ec" 4
  assert_file_not_exists "CR10v: evidence chmod failure prevents Codex launch" "$called"
  assert_file_not_exists "CR10w: chmod failure cannot publish evidence" \
    "$logs/chmod-failure-qa-1.jsonl"

  rm -f "$called"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    FAKE_CODEX_MODE=oversized-json FAKE_TRUNCATE_FAIL=1 \
    SAAS_CODEX_JSONL_MAX_BYTES=1500 SAAS_CODEX_STDERR_MAX_BYTES=1024 \
    SAAS_CODEX_LAST_MESSAGE_MAX_BYTES=1024 SAAS_CODEX_LOG_RETENTION_BYTES=16384 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=truncate-failure \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10x: evidence truncate failure fails closed" "$ec" 4
  assert_file_exists "CR10y: truncate regression reaches the Codex producer" "$called"
  assert_output_contains "CR10z: evidence truncate failure is explicit" "$out" \
    'could not truncate Codex evidence safely'
  assert_file_not_exists "CR10aa: truncate failure cannot publish evidence" \
    "$logs/truncate-failure-qa-1.jsonl"

  started=$(date +%s); ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=hang \
    SAAS_CODEX_ROLE_TIMEOUT=1s SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=hanging \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  elapsed=$(($(date +%s) - started))
  assert_equals "CR10p: hanging Codex run cannot succeed" \
    "$([ "$ec" -ne 0 ] && echo yes || echo no)" yes
  assert_output_contains "CR10q: hanging Codex deadline is explicit" "$out" 'exceeded the 1s deadline'
  assert_equals "CR10r: hanging Codex run is killed within a fixed grace period" \
    "$([ "$elapsed" -le 5 ] && echo yes || echo no)" yes

  ambient_home="$repo/ambient-codex"; mkdir "$ambient_home"
  truncate -s 9437184 "$ambient_home/state_5.sqlite"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" CODEX_HOME="$ambient_home" \
    FAKE_STATE_APPEND=1 SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=large-sqlite \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10r1: evidence bounds do not cap a shared Codex SQLite file" "$ec" 0
  assert_equals "CR10r2: a pre-existing SQLite file remains writable past 8 MiB" \
    "$(stat -c %s "$ambient_home/state_5.sqlite")" 9437185

  product_file="$repo/generated-large.bin"; ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_PRODUCT_FILE="$product_file" \
    SAAS_CODEX_JSONL_MAX_BYTES=1024 SAAS_CODEX_STDERR_MAX_BYTES=1024 \
    SAAS_CODEX_LAST_MESSAGE_MAX_BYTES=1024 SAAS_CODEX_LOG_RETENTION_BYTES=8192 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=large-product \
    bash "$script" --role tech-founder --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10r3: evidence bounds do not cap product files" "$ec" 0
  assert_equals "CR10r4: source writer can create a file larger than an evidence cap" \
    "$(stat -c %s "$product_file")" 2048

  for signal in HUP INT TERM; do
    child_pid="$repo/signal-$signal.pid"; signal_seen="$repo/signal-$signal.seen"
    signal_out="$repo/signal-$signal.out"
    (cd "$repo" && exec env PATH="$bin:$PATH" FAKE_CODEX_MODE=signal-hang \
      FAKE_CHILD_PID="$child_pid" FAKE_SIGNAL_SEEN="$signal_seen" \
      SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" \
      SAAS_RUN_ID="signal-${signal,,}" bash "$script" \
      --role qa --profile deep --task-file task.md > "$signal_out" 2>&1) &
    runner_pid=$!
    for ((i=0; i<100; i++)); do
      [ -s "$child_pid" ] && break
      kill -0 "$runner_pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -s "$signal" "$runner_pid" 2>/dev/null || true
    ec=0; wait "$runner_pid" || ec=$?
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    assert_exit_code "CR10r5/$signal: runner preserves signal exit status" "$ec" "$expected"
    assert_file_contains "CR10r6/$signal: runner forwards the signal to Codex" \
      "$signal_seen" "$signal"
    if [ -s "$child_pid" ] && kill -0 "$(cat "$child_pid")" 2>/dev/null; then
      assert_equals "CR10r7/$signal: signaled Codex child is reaped" live reaped
    else
      assert_equals "CR10r7/$signal: signaled Codex child is reaped" reaped reaped
    fi
    assert_equals "CR10r8/$signal: signal cleanup leaves no relay or temporary evidence" \
      "$(find "$logs" -maxdepth 1 \( -name '.codex-*' -o -name '*.codex-relay.*' \) -print -quit)" ""
  done

  holder_pid="$repo/inherited-writer.pid"; started=$(date +%s); ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_MODE=inherited-writer \
    FAKE_HOLDER_PID="$holder_pid" SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=inherited-writer \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  elapsed=$(($(date +%s) - started))
  assert_exit_code "CR10r9: inherited evidence writer fails closed" "$ec" 4
  assert_output_contains "CR10r10: stalled relay drain is explicit" "$out" \
    'Codex evidence relays did not drain after worker exit'
  assert_equals "CR10r11: inherited writer cannot block the runner indefinitely" \
    "$([ "$elapsed" -le 6 ] && echo yes || echo no)" yes
  for ((i=0; i<40; i++)); do
    [ -s "$holder_pid" ] && ! kill -0 "$(cat "$holder_pid")" 2>/dev/null && break
    sleep 0.05
  done
  if [ -s "$holder_pid" ] && kill -0 "$(cat "$holder_pid")" 2>/dev/null; then
    assert_equals "CR10r12: inherited evidence writer is terminated" live terminated
    kill -KILL "$(cat "$holder_pid")" 2>/dev/null || true
  else
    assert_equals "CR10r12: inherited evidence writer is terminated" terminated terminated
  fi
  assert_equals "CR10r13: stalled drain cleanup removes private evidence slots" \
    "$(find "$logs" -maxdepth 1 -name '.codex-*' -print -quit)" ""

  stress_ok=1; completed=0
  for ((attempt=1; attempt<=20; attempt++)); do
    target="$repo/immediate-$attempt.target"; child_pid="$repo/immediate-$attempt.pid"
    signal_seen="$repo/immediate-$attempt.seen"; signal_out="$repo/immediate-$attempt.out"
    (cd "$repo" && exec env PATH="$bin:$PATH" FAKE_CODEX_MODE=immediate-signal \
      FAKE_CHILD_PID="$child_pid" FAKE_SIGNAL_SEEN="$signal_seen" \
      FAKE_SIGNAL_TARGET="$target" SAAS_AGENT_EVENTS_FILE="$events" \
      SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID="immediate-$attempt" \
      bash "$script" --role qa --profile deep --task-file task.md > "$signal_out" 2>&1) &
    runner_pid=$!
    printf '%s\n' "$runner_pid" > "$target"
    ec=0; wait "$runner_pid" || ec=$?
    [ "$ec" -eq 143 ] || stress_ok=0
    for ((i=0; i<40; i++)); do
      [ -s "$child_pid" ] && ! kill -0 "$(cat "$child_pid")" 2>/dev/null && break
      sleep 0.025
    done
    if [ ! -s "$signal_seen" ] || [ "$(cat "$signal_seen")" != TERM ]; then
      stress_ok=0
    fi
    if [ -s "$child_pid" ] && kill -0 "$(cat "$child_pid")" 2>/dev/null; then
      stress_ok=0
      kill -KILL "$(cat "$child_pid")" 2>/dev/null || true
    fi
    [ -z "$(find "$logs" -maxdepth 1 -name '.codex-*' -print -quit)" ] || stress_ok=0
    completed=$attempt
  done
  assert_equals "CR10r14: immediate-signal launch stress completes every iteration" \
    "$completed" 20
  assert_equals "CR10r15: launch-boundary signals preserve status and leave no child" \
    "$stress_ok" 1

  dd if=/dev/zero of="$logs/old-large-a.jsonl" bs=4096 count=1 status=none
  dd if=/dev/zero of="$logs/old-large-b.jsonl" bs=4096 count=1 status=none
  touch -d @1 "$logs/old-large-a.jsonl"; touch -d @2 "$logs/old-large-b.jsonl"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" \
    SAAS_CODEX_JSONL_MAX_BYTES=1024 SAAS_CODEX_STDERR_MAX_BYTES=1024 \
    SAAS_CODEX_LAST_MESSAGE_MAX_BYTES=1024 SAAS_CODEX_LOG_RETENTION_BYTES=8192 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=byte-retention \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR10s: byte-bounded retention preserves a valid current result" "$ec" 0
  evidence_bytes=$(find -P "$logs" -maxdepth 1 -type f \
    \( -name '*.jsonl' -o -name '*.jsonl.stderr' -o -name '*.jsonl.last-message' \) \
    -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')
  assert_equals "CR10t: retained Codex evidence has a total byte budget" \
    "$([ "$evidence_bytes" -le 8192 ] && echo yes || echo no)" yes

  mkdir -p "$logs"
  for oldest in 1 2 3; do
    printf 'old\n' > "$logs/old-$oldest.jsonl"
    touch -d "@$oldest" "$logs/old-$oldest.jsonl"
  done
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_CODEX_LOG_RETENTION_FILES=1 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=retained-run \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR11: log pruning does not affect the current result" "$ec" 0
  assert_file_not_exists "CR12: retention prunes the oldest full log" "$logs/old-1.jsonl"
  assert_file_exists "CR13: retention preserves the current full event log" \
    "$logs/retained-run-qa-1.jsonl"

  victim="$repo/victim.jsonl"; printf 'outside\n' > "$victim"
  printf 'hostile\n' > "$logs/old-newline"$'\n'"victim.jsonl"
  printf 'hostile\n' > "$logs/old-tab"$'\t'"entry.jsonl"
  touch -d '@1' "$logs/old-newline"$'\n'"victim.jsonl"
  touch -d '@2' "$logs/old-tab"$'\t'"entry.jsonl"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_CODEX_LOG_RETENTION_FILES=1 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=hostile-name \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR14: NUL-safe retention accepts control characters in log names" "$ec" 0
  assert_file_exists "CR15: retention cannot inject an out-of-directory deletion" "$victim"

  ln -s "$victim" "$logs/unsafe.jsonl"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_CODEX_LOG_RETENTION_FILES=1 \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=symlink-log \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR16: retention fails closed on a matching symlink" "$ec" 1
  assert_file_exists "CR17: rejected symlink target is untouched" "$victim"
  rm -f -- "$logs/unsafe.jsonl"

  moved_logs="$logs-real"; mv -- "$logs" "$moved_logs"; ln -s "$moved_logs" "$logs"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=symlink-dir \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR18: launcher rejects a symlink log directory" "$ec" 4
  rm -f -- "$logs"; mv -- "$moved_logs" "$logs"

  guard_dir="$(git -C "$repo" rev-parse --absolute-git-dir)/saas-startup-team"
  mkdir -p "$guard_dir"; printf 'forged\n' > "$guard_dir/forged.verified"; rm -f "$called"
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" FAKE_CALLED="$called" \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=forged-marker \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR19: terminal marker without active guard fails closed" "$ec" 4
  assert_file_not_exists "CR20: forged terminal marker cannot launch Codex" "$called"

  rm -f "$guard_dir/forged.verified"
  logs="$repo/.startup/runs/codex"; mkdir -p "$logs"
  for oldest in 1 2 3; do
    printf 'old\n' > "$logs/old-$oldest.jsonl"
    touch -d "@$oldest" "$logs/old-$oldest.jsonl"
  done
  auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  snapshot="$guard_dir/guarded-retention.json"
  (cd "$repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$snapshot" --auth-stdin --allow review.md <<<"$auth" >/dev/null)
  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_CODEX_LOG_RETENTION_FILES=1 \
    SAAS_RUN_ID=guarded-retention bash "$script" \
    --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR21: guarded role buffers a valid result" "$ec" 0
  receipt=$(find "$guard_dir" -maxdepth 1 -name 'guarded-retention.json.telemetry-*.json' -print -quit)
  assert_equals "CR22: guarded receipt preserves the requested retention" \
    "$(jq -r .log_retention_files "$receipt")" 1
  (cd "$repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --verify "$snapshot" --auth-stdin <<<"$auth" >/dev/null)
  assert_file_not_exists "CR23: guarded import prunes the oldest historical log" \
    "$logs/old-1.jsonl"
  assert_file_not_exists "CR24: guarded import enforces the historical file bound" \
    "$logs/old-2.jsonl"
  assert_file_exists "CR25: guarded import retains the newest historical log" \
    "$logs/old-3.jsonl"
  assert_equals "CR26: guarded import retains the current full event log" \
    "$(find "$logs" -mindepth 2 -maxdepth 2 -name 'guarded-retention-qa-1.jsonl' | wc -l | tr -d ' ')" 1

  rm -rf "$repo" "$bin"
}

test_codex_run_role_terminal_safety
