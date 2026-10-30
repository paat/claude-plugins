#!/usr/bin/env python3
"""Stop real runner processes backed only by disposable, sleeping provider stubs."""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

scripts = Path(sys.argv[1]).resolve()
work = Path(sys.argv[2]).resolve()
work.mkdir()
bin_dir = work / "bin"
bin_dir.mkdir()
stub = bin_dir / "stub"
stub.write_text('''#!/usr/bin/python3
import json, os, signal, sys
from pathlib import Path
if "--help" in sys.argv:
    print("--diff-file --print-base running model")
    sys.exit(0)
if "--print-base" in sys.argv:
    print("http://stub.invalid:8000/v1")
    sys.exit(0)
if os.environ["STOP_CASE"].startswith("grok-resume") and "--resume" not in sys.argv:
    Path(os.environ["STOP_REPO"], "app.txt").write_text("partial edit\\n")
    print("max turns reached", file=sys.stderr)
    sys.exit(1)
if "inherited" not in os.environ["STOP_CASE"]:
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN if "stubborn" in os.environ["STOP_CASE"] else signal.SIG_DFL)
try:
    os.fstat(3)
    fd3_open = True
except OSError:
    fd3_open = False
ancestor = os.getppid()
runner_pid = None
while ancestor > 1 and ancestor != int(os.environ["STOP_HARNESS_PID"]):
    command = Path(f"/proc/{ancestor}/cmdline").read_bytes().split(b"\\0")
    if any(Path(os.fsdecode(arg)).name == os.environ["STOP_RUNNER"] for arg in command):
        runner_pid = ancestor
    ancestor = int(Path(f"/proc/{ancestor}/stat").read_text().rsplit(") ", 1)[1].split()[1])
os.write(int(os.environ["STOP_READY_FD"]), (json.dumps({"pid": os.getpid(), "pgid": os.getpgrp(), "fd3_open": fd3_open, "runner_pid": runner_pid}) + "\\n").encode())
while True:
    signal.pause()
''')
stub.chmod(0o755)
for name in ("codex", "claude", "grok", "agy", "muse", "qwen-wrapper"):
    (bin_dir / name).symlink_to(stub)
nested_wrapper = bin_dir / "qwen-nested-wrapper"
nested_wrapper.write_text('''#!/usr/bin/env bash
case "$1" in
  --help|--print-base) exec "$(dirname "$0")/stub" "$@" ;;
esac
# Match the real Qwen wrapper's foreground pipeline and separate timeout group.
printf task | timeout -k 10 120 "$(dirname "$0")/stub"
''')
nested_wrapper.chmod(0o755)
curl = bin_dir / "curl"
curl.write_text("#!/usr/bin/env bash\nprintf '[]\\n200'\n")
curl.chmod(0o755)


def readiness_pipe():
    read_fd, write_fd = os.pipe()
    # The Qwen wrapper owns FD 9 and the API wrapper owns FD 3.
    ready_fd = fcntl.fcntl(write_fd, fcntl.F_DUPFD_CLOEXEC, 100)
    os.close(write_fd)
    return read_fd, ready_fd


def check(case):
    name, sig, target = case
    label = f"{name} {sig.name} to {target}"
    fixture = work / f"{name}-{sig.name}-{target}"
    fixture.mkdir()
    repo = fixture / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (repo / "app.txt").write_text("base\n")
    subprocess.run(["git", "-C", str(repo), "add", "app.txt"], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=test", "-c",
                    "user.email=test@example.invalid", "commit", "-qm", "base"], check=True)
    for directory in ("home", "tmp"):
        (fixture / directory).mkdir()
    key = fixture / "api-key"
    key.write_text("dummy-test-key\n")
    tiers = fixture / "tiers.tsv"
    tiers.write_text("T3\tcodex\tgpt-6.1-sol\thigh\n")
    output = fixture / "outcomes.tsv"
    read_fd, write_fd = readiness_pipe()
    env = {**os.environ, "PATH": f"{bin_dir}:/usr/bin:/bin",
           "HOME": str(fixture / "home"), "TMPDIR": str(fixture / "tmp"),
           "MMO_OUTCOMES_FILE": str(output), "MMO_POOL_TIERS": str(tiers),
           "MMO_QWEN_LOCAL_RUN": str(bin_dir / "qwen-wrapper"),
           "MMO_CLAUDE_API_KEY_FILE": str(key), "STOP_READY_FD": str(write_fd),
           "STOP_CASE": name, "STOP_REPO": str(repo),
           "STOP_HARNESS_PID": str(os.getpid()),
           "MMO_LEG_ENV": "STOP_READY_FD STOP_CASE STOP_REPO STOP_RUNNER STOP_HARNESS_PID"}
    for var in tuple(env):
        if var.startswith(("MMO_GROK_", "MMO_CODEX_", "MMO_CLAUDE_MODEL", "MMO_OPUS_", "MMO_AGY_", "MMO_MUSE_")):
            env.pop(var)
    provider = name.split("-")[0]
    runner = "qwen-local" if provider == "qwen" else provider
    if name.startswith("qwen-nested"):
        env["MMO_QWEN_LOCAL_RUN"] = str(nested_wrapper)
    env["STOP_RUNNER"] = f"run-{'codex' if provider == 'pool' else runner}.sh"
    args = ["bash", str(scripts / f"run-{runner}.sh")]
    if provider == "pool":
        args = ["bash", str(scripts / "pool.sh"), "run", "--tier", "T3", "--usage", "/dev/null"]
    args += ["--mode", "implement", "--repo", str(repo), "--timeout", "120",
             "--out", str(fixture / "body.txt")]
    if "api" in name:
        args += ["--api"]
    if "stream" in name:
        args += ["--stream-log", str(fixture / "stream.json")]
    if provider == "grok":
        args += ["--continue-on-max-turns", "1" if "resume" in name else "0"]
    info = None
    pid_fd = None
    runner_fd = None
    with (fixture / "stdout").open("wb") as stdout, (fixture / "stderr").open("wb") as stderr:
        proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
                                start_new_session=True, pass_fds=(write_fd,), env=env)
        os.close(write_fd)
        try:
            proc.stdin.write(b"task\n")
            proc.stdin.close()
            assert select.select([read_fd], [], [], 10)[0], "stub did not become ready"
            data = os.read(read_fd, 4096)
            assert data, f"runner exited before stub readiness: {(fixture / 'stderr').read_text()}"
            info = json.loads(data)
            (fixture / "ready.json").write_text(json.dumps(info))
            pid_fd = os.pidfd_open(info["pid"])
            runner_fd = os.pidfd_open(info["runner_pid"])
            if "api" in name:
                assert not info["fd3_open"], "API key redactor FD 3 leaked to CLI"
            started = time.monotonic()
            if target == "group":
                os.killpg(proc.pid, sig)
            else:
                os.kill(proc.pid, sig)
            assert select.select([pid_fd], [], [], 12)[0], "provider still alive 12s after stop"
            assert select.select([runner_fd], [], [], max(0.01, 12 - (time.monotonic() - started)))[0], "runner did not exit within 12s"
            proc.wait(timeout=max(0.01, 12 - (time.monotonic() - started)))
            expected = 128 + sig
            # A group stop may terminate pool itself by signal; the runner must still record.
            allowed = (expected, -sig) if provider == "pool" and target == "group" else (expected,)
            assert proc.returncode in allowed, f"exit {proc.returncode}, expected {allowed}"
            rows = output.read_text().splitlines()
            assert len(rows) == 2 and rows[1].split("\t")[8] == str(expected), rows
            return True, label
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
            return False, f"{label}: {exc}"
        finally:
            os.close(read_fd)
            if pid_fd is not None:
                os.close(pid_fd)
            if runner_fd is not None:
                os.close(runner_fd)
            # Clean failed red tests too: timeout deliberately owns a separate process group.
            for pgid in {proc.pid, info["pgid"] if info else proc.pid}:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.wait(timeout=5)


def check_startup_stop():
    label = "helper group TERM before timeout PID publication"
    fixture = work / "startup-stop"
    fixture.mkdir()
    output = fixture / "outcomes.tsv"
    marker = fixture / "cli-started"
    read_fd, write_fd = readiness_pipe()
    launch = r'''
source "$1"
repo_dir="$2"
mmo_outcome_init codex
root=$BASHPID
printf() {
  if [ "$BASHPID" != "$root" ] && [ "${1:-}" = '%s\n' ] && [ "${2:-}" = "$BASHPID" ]; then
    builtin printf '%s\n' "$BASHPID" >&"$STOP_READY_FD"
    kill -STOP "$BASHPID"
  fi
  builtin printf "$@"
}
mmo_run direct "" "" timeout -k 10 120 bash -c 'touch "$STOP_STARTED"; exec sleep 120'
'''
    child_fd = None
    with (fixture / "stdout").open("wb") as stdout, (fixture / "stderr").open("wb") as stderr:
        proc = subprocess.Popen(
            ["bash", "-c", launch, "bash", str(scripts / "lib-outcomes.sh"), str(fixture)],
            stdout=stdout, stderr=stderr, start_new_session=True, pass_fds=(write_fd,),
            env={**os.environ, "MMO_OUTCOMES_FILE": str(output),
                 "STOP_READY_FD": str(write_fd), "STOP_STARTED": str(marker)},
        )
        os.close(write_fd)
        try:
            assert select.select([read_fd], [], [], 10)[0], "launch did not reach PID publication"
            data = os.read(read_fd, 128)
            assert data, f"helper exited before PID publication: {(fixture / 'stderr').read_text()}"
            child_fd = os.pidfd_open(int(data))
            started = time.monotonic()
            os.killpg(proc.pid, signal.SIGTERM)
            os.killpg(proc.pid, signal.SIGCONT)
            proc.wait(timeout=12)
            assert proc.returncode == 143, f"exit {proc.returncode}, expected 143"
            assert select.select([child_fd], [], [], max(0.01, 12 - (time.monotonic() - started)))[0], "unpublished launch child survived stop"
            assert not marker.exists(), "CLI started after startup group stop"
            rows = output.read_text().splitlines()
            assert len(rows) == 2 and rows[1].split("\t")[8] == "143", rows
            return True, label
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
            return False, f"{label}: {exc}"
        finally:
            os.close(read_fd)
            if child_fd is not None:
                os.close(child_fd)
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)


names = ("codex", "claude", "claude-api", "claude-stream", "claude-api-stream",
         "grok", "grok-stream", "grok-resume", "grok-resume-stream", "agy", "muse", "qwen", "qwen-nested")
cases = [(name, sig, "pid") for name in names
         for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)]
cases += [("codex-stubborn", signal.SIGTERM, "pid"),
          ("claude-api-stubborn", signal.SIGTERM, "pid"),
          ("claude-api-stream-stubborn", signal.SIGTERM, "pid"),
          ("qwen-nested-stubborn", signal.SIGTERM, "pid"),
          ("pool", signal.SIGTERM, "pid"), ("pool", signal.SIGTERM, "group")]
cases += [(name, signal.SIGINT, "pid") for name in
          ("codex-inherited", "claude-api-inherited", "qwen-nested-inherited")]
cases += [(name, signal.SIGTERM, "group") for name in
          ("claude-api", "claude-api-stream", "qwen-nested", "claude-api-stubborn",
           "claude-api-stream-stubborn", "qwen-nested-stubborn")]
passes = failures = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
    for ok, label in executor.map(check, cases):
        passes += ok
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: stop signals: {label}", flush=True)
ok, label = check_startup_stop()
passes += ok
failures += not ok
print(f"{'PASS' if ok else 'FAIL'}: stop signals: {label}", flush=True)
print(f"Stop signal regressions: {passes} PASS, {failures} FAIL.", flush=True)
sys.exit(bool(failures))
