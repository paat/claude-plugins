#!/usr/bin/env python3
"""Exercise outcome lifecycle races with disposable files and a sleeping CLI."""
import concurrent.futures
import os
from pathlib import Path
import select
import signal
import subprocess
import sys

scripts = Path(sys.argv[1]).resolve()
work = Path(sys.argv[2]).resolve()
repo = Path(sys.argv[3]).resolve()
work.mkdir()
passes = 0


def passed(label):
    global passes
    passes += 1
    print(f"PASS: outcomes lifecycle: {label}", flush=True)


for runner in sorted(scripts.glob("run-*.sh")) + [scripts / "review-gate.sh"]:
    for flag in ("-h", "--help"):
        output = work / "help.tsv"
        output.write_text("existing content\n")
        result = subprocess.run(
            ["bash", str(runner), flag], capture_output=True,
            env={**os.environ, "MMO_OUTCOMES_FILE": str(output)}, timeout=10,
        )
        assert result.returncode == 0, result.stderr
        assert output.read_text() == "existing content\n", runner
        passed(f"{runner.name} {flag} leaves outcomes unchanged")

bin_dir = work / "bin"
bin_dir.mkdir()
stub = bin_dir / "codex"
for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    output = work / f"signal-{sig}.tsv"
    read_fd, write_fd = os.pipe()
    stub.write_text(f"#!/usr/bin/env bash\nprintf ready >&{write_fd}\nexec sleep 1\n")
    stub.chmod(0o755)
    proc = subprocess.Popen(
        ["setsid", "bash", str(scripts / "run-codex.sh"), "--repo", str(repo)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        pass_fds=(write_fd,),
        env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
             "MMO_OUTCOMES_FILE": str(output)},
    )
    os.close(write_fd)
    try:
        proc.stdin.write(b"task\n")
        proc.stdin.close()
        proc.stdin = None
        assert select.select([read_fd], [], [], 10)[0], "CLI did not start"
        assert os.read(read_fd, 5) == b"ready"
        os.killpg(proc.pid, sig)
        stdout, stderr = proc.communicate(timeout=10)
        expected = 128 + sig
        assert proc.returncode == expected, (proc.returncode, stderr)
        rows = output.read_text().splitlines()
        assert len(rows) == 2 and rows[1].split("\t")[8] == str(expected), rows
        passed(f"{sig.name} preserves exit and recorded status {expected}")
    finally:
        os.close(read_fd)
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def append(output):
    subprocess.run(
        ["bash", "-c", 'source "$1"; mmo_outcome_init codex',
         "bash", str(scripts / "lib-outcomes.sh")], check=True, timeout=10,
        env={**os.environ, "MMO_OUTCOMES_FILE": str(output)},
    )


with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
    for trial in range(150):
        output = work / f"concurrent-{trial}.tsv"
        list(pool.map(append, [output] * 24))
        rows = output.read_text().splitlines()
        assert len(rows) == 25, (trial, len(rows))
        assert rows[0].startswith("utc_time\t"), rows[0]
        assert all(len(row.split("\t")) == 13 for row in rows)
passed("150 fresh-file trials × 24 writers retain all 3,600 rows")
print(f"Outcome lifecycle: {passes} PASS, 0 FAIL.")
