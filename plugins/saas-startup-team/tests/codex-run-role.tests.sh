# Codex launcher terminal-proof and bounded-output regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "codex-run-role.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_codex_run_role_terminal_safety() {
  echo -e "\n${CYAN}Suite CR: Codex role terminal safety${NC}"
  local repo bin script ec out logs events called guard_dir oldest auth snapshot receipt victim moved_logs
  local predicted special linked_parent real_parent started elapsed evidence_bytes
  local eval_dir observed target_size namespace_prompt
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
last_message=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output-last-message ]; then last_message=$2; shift 2
  else shift
  fi
done
if [ -n "${FAKE_PROMPT_CAPTURE:-}" ]; then
  cat > "$FAKE_PROMPT_CAPTURE"
else
  cat >/dev/null
fi
case "${FAKE_CODEX_MODE:-valid}" in
  valid)
    printf 'verdict one\033[31m\001\nverdict two\n' > "$last_message"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  no-terminal)
    printf 'unproven result\n' > "$last_message"
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message"}}'
    ;;
  no-message)
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  fail)
    printf 'partial verdict\n' > "$last_message"
    printf 'failure stderr\033[2J\002\n' >&2
    printf '%s\n' '{"type":"turn.failed","error":{"message":"failed"}}'
    exit 7
    ;;
  malformed)
    printf 'unproven malformed result\n' > "$last_message"
    printf '%s\n' '{malformed'
    ;;
  oversized-json)
    printf 'must not be reported as success\n' > "$last_message"
    head -c 65536 /dev/zero | tr '\0' x
    printf '\n%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  oversized-stderr)
    printf 'must not be reported as success\n' > "$last_message"
    head -c 65536 /dev/zero | tr '\0' x >&2
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  oversized-message)
    head -c 65536 /dev/zero | tr '\0' x > "$last_message"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  replace-race)
    case "${FAKE_REPLACE_SLOT:-}" in
      jsonl)
        target=$(readlink "/proc/$$/fd/1") || exit 9
        rm -f -- "$target" || exit 9
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":99,"output_tokens":99,"cached_input_tokens":0}}' > "$target" || exit 9
        printf '%s\n' '{malformed'
        printf 'real message\n' > "$last_message"
        ;;
      stderr)
        target=$(readlink "/proc/$$/fd/2") || exit 9
        rm -f -- "$target" || exit 9
        printf 'forged diagnostic\n' > "$target" || exit 9
        printf 'real message\n' > "$last_message"
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
        ;;
      last-message)
        target=$(readlink "$last_message") || exit 9
        rm -f -- "$target" || exit 9
        printf 'forged message\n' > "$target" || exit 9
        printf ' \n' > "$last_message"
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
        ;;
      *) exit 9 ;;
    esac
    ;;
  rapid-output)
    printf 'bounded failure\n' > "$last_message"
    dd if=/dev/zero bs=1048576 count=32 status=none || true
    stat -Lc '%s' -- "/proc/$$/fd/1" > "${FAKE_OBSERVED_SIZE:?}" || exit 9
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3,"cached_input_tokens":1}}'
    ;;
  hang)
    trap '' TERM
    while :; do sleep 1; done
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

  ec=0
  out=$(cd "$repo" && PATH="$bin:$PATH" SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_LOG_DIR="$logs" SAAS_RUN_ID=valid-run \
    bash "$script" --role qa --profile deep --task-file task.md 2>&1) || ec=$?
  assert_exit_code "CR1: valid terminal event plus role message succeeds" "$ec" 0
  assert_output_contains "CR2: terminal output names the retained full log" "$out" 'full-log='
  assert_output_contains "CR3: every surfaced verdict line has a worker prefix" "$out" 'codex-worker: verdict two'
  if [[ "$out" == *$'\033'* ]]; then
    assert_equals "CR4: worker controls are removed from terminal output" present absent
  else
    assert_equals "CR4: worker controls are removed from terminal output" absent absent
  fi

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
      SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$logs" \
      SAAS_RUN_ID="replaced-$special" \
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
