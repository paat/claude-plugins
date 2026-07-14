# Linux Landlock containment for tracked QA/live proof commands.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "proof-landlock.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_proof_landlock() {
  echo -e "\n${CYAN}Suite PL: proof Landlock containment${NC}"
  local runner="$PLUGIN_ROOT/scripts/proof-landlock.py"
  local root work scratch outside command ec out marker

  assert_file_exists "PL1: proof Landlock runner exists" "$runner"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$runner" ]; then
    echo -e "  ${GREEN}PASS${NC} PL2: proof Landlock runner is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} PL2: proof Landlock runner is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("PL2: runner is not executable")
  fi
  ec=0; python3 - "$runner" <<'PY' || ec=$?
import ast
import pathlib
import sys

ast.parse(pathlib.Path(sys.argv[1]).read_bytes(), filename=sys.argv[1])
PY
  assert_exit_code "PL3: proof Landlock runner parses" "$ec" 0

  out=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$runner" <<'PY'
import importlib.util
import errno
import sys

spec = importlib.util.spec_from_file_location("proof_landlock", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(hex(module.handled_fs_access(7)))
print(hex(module.handled_fs_access(10)))
module._call = lambda *args: (_ for _ in ()).throw(OSError(errno.ENOSYS, "missing"))
try:
    module.query_abi()
except module.PolicyError:
    print("unavailable-fails-closed")
module._call = lambda *args: 11
try:
    module.query_abi()
except module.PolicyError:
    print("future-abi-fails-closed")
PY
  )
  assert_output_contains "PL4: ABI 7 handles every filesystem right through IOCTL" "$out" "0xffff"
  assert_output_contains "PL5: ABI 10 additionally handles pathname UNIX resolution" "$out" "0x1ffff"
  assert_output_contains "PL5a: unavailable Landlock fails closed" "$out" \
    "unavailable-fails-closed"
  assert_output_contains "PL5b: unreviewed future ABI fails closed" "$out" \
    "future-abi-fails-closed"

  root=$(mktemp -d)
  chmod 700 "$root"
  work="$root/work"; scratch="$root/scratch"; outside="$root/outside"
  mkdir -m 700 "$work" "$scratch" "$outside"
  printf 'outside-secret\n' > "$outside/secret"
  command="$work/probe.sh"
  cat > "$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$HOME" = "$TMPDIR" ]
[ "$HOME" = "$EXPECTED_SCRATCH" ]
[ "${AMBIENT_SECRET+x}" != x ]
[ "$EXPLICIT_TOKEN" = allowed ]
printf ignored >/dev/null
printf device-ok > "$TMPDIR/dev-null-ok"
head -c 1 /dev/urandom > "$TMPDIR/random"
cat input.txt > output.txt
printf scratch > "$TMPDIR/written"
python3 - <<'PY'
import ctypes
import socket

libc = ctypes.CDLL(None)
assert libc.prctl(39, 0, 0, 0, 0) == 1
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(1)
client = socket.create_connection(listener.getsockname())
server, _ = listener.accept()
client.sendall(b"network-ok")
assert server.recv(10) == b"network-ok"
client.close()
server.close()
listener.close()
PY
SH
  chmod 700 "$command"
  printf 'inside\n' > "$work/input.txt"
  ec=0; out=$(AMBIENT_SECRET=blocked EXPLICIT_TOKEN=allowed EXPECTED_SCRATCH="$scratch" \
    python3 "$runner" --work-root "$work" --scratch-root "$scratch" \
      --pass-env EXPLICIT_TOKEN --pass-env EXPECTED_SCRATCH -- "$command" 2>&1) || ec=$?
  assert_exit_code "PL6: contained proof command succeeds" "$ec" 0
  assert_equals "PL6a: narrow /dev/null write is usable" \
    "$(cat "$scratch/dev-null-ok")" device-ok
  assert_equals "PL6b: narrow random-device read is usable" \
    "$(wc -c < "$scratch/random" | tr -d ' ')" 1
  assert_equals "PL7: proof reads and writes disposable work" "$(cat "$work/output.txt")" inside
  assert_equals "PL8: proof writes explicit scratch" "$(cat "$scratch/written")" scratch

  cat > "$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "$1"
SH
  chmod 700 "$command"
  ec=0; out=$(python3 "$runner" --work-root "$work" --scratch-root "$scratch" \
    -- "$command" "$outside/secret" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ]; then
    assert_equals "PL9: proof cannot read outside disposable roots" denied denied
  else
    assert_equals "PL9: proof cannot read outside disposable roots" allowed denied
  fi
  assert_output_not_contains "PL10: denied proof does not disclose outside content" "$out" outside-secret

  cat > "$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf escaped > "$1"
SH
  chmod 700 "$command"
  marker="$outside/escaped"
  ec=0; out=$(python3 "$runner" --work-root "$work" --scratch-root "$scratch" \
    -- "$command" "$marker" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ]; then
    assert_equals "PL11: proof cannot write outside disposable roots" denied denied
  else
    assert_equals "PL11: proof cannot write outside disposable roots" allowed denied
  fi
  assert_file_not_exists "PL12: outside write leaves no artifact" "$marker"

  cat > "$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if printf leaked >&9 2>/dev/null; then
  exit 9
fi
exit 0
SH
  chmod 700 "$command"
  ec=0
  python3 "$runner" --work-root "$work" --scratch-root "$scratch" -- "$command" \
    9> "$outside/inherited" >/dev/null 2>&1 || ec=$?
  assert_exit_code "PL13: inherited non-standard descriptor is closed" "$ec" 0
  assert_equals "PL14: closed descriptor cannot modify outside file" \
    "$(wc -c < "$outside/inherited" | tr -d ' ')" 0

  ln -s "$work" "$root/work-link"
  ec=0; out=$(python3 "$runner" --work-root "$root/work-link" --scratch-root "$scratch" \
    -- "$command" 2>&1) || ec=$?
  assert_exit_code "PL15: symlink work root fails closed" "$ec" 2
  assert_output_contains "PL16: symlink rejection is explicit" "$out" "canonical and contain no symlink"

  ln -s "$command" "$work/command-link"
  ec=0; out=$(python3 "$runner" --work-root "$work" --scratch-root "$scratch" \
    -- "$work/command-link" 2>&1) || ec=$?
  assert_exit_code "PL17: symlink command fails closed" "$ec" 2

  ec=0; out=$(LD_PRELOAD=unused python3 "$runner" --work-root "$work" \
    --scratch-root "$scratch" --pass-env LD_PRELOAD -- "$command" 2>&1) || ec=$?
  assert_exit_code "PL18: loader injection environment cannot be passed" "$ec" 2
  assert_output_contains "PL19: unsafe environment rejection is explicit" "$out" \
    "unsafe environment variable"

  chmod 755 "$scratch"
  ec=0; out=$(python3 "$runner" --work-root "$work" --scratch-root "$scratch" \
    -- "$command" 2>&1) || ec=$?
  assert_exit_code "PL20: shared scratch root fails closed" "$ec" 2
  assert_output_contains "PL21: root permission rejection is explicit" "$out" \
    "must not grant group or other access"
  chmod 700 "$scratch"

  ec=0; out=$(python3 "$runner" --work-root "$work" --scratch-root "$scratch" \
    -- /usr/bin/true 2>&1) || ec=$?
  assert_exit_code "PL22: command outside work root fails closed" "$ec" 2
  assert_output_contains "PL23: command containment rejection is explicit" "$out" \
    "beneath --work-root"

  rm -rf "$root"
}

test_proof_landlock
