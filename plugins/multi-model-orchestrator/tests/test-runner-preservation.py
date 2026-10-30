#!/usr/bin/env python3
"""Stub-only runner contracts; optional old scripts compare exact observable bytes."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1]).resolve()
baseline = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
variants = {
    "codex": ("codex", []),
    "claude": ("claude", []),
    "claude-stream": ("claude", ["--stream-log"]),
    "claude-api": ("claude", ["--api"]),
    "claude-api-stream": ("claude", ["--api", "--stream-log"]),
    "grok": ("grok", []),
    "grok-stream": ("grok", ["--stream-log"]),
    "agy": ("agy", []),
    "muse": ("muse", []),
    "qwen-local": ("qwen-local", []),
}
expected = {"success": 0, "failure": 23, "timeout": 124, "limit": 75,
            "auth": 77, "bad-args": 2, "abort": 42, "empty": 5, "deadline": 124}

CLI = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "qwen-local" and "--help" in args:
    print("--diff-file --print-base running model")
    sys.exit(0)
if name == "qwen-local" and "--print-base" in args:
    print("http://127.0.0.1:9/v1")
    sys.exit(0)
if name in ("grok", "muse"):
    prompt = Path(args[args.index("--prompt-file") + 1]).read_text()
else:
    prompt = sys.stdin.read()
assert "preservation-input-682" in prompt, (name, "lost prompt input", prompt)
case = os.environ["PRESERVE_CASE"]
if case == "deadline":
    key = os.environ.get("ANTHROPIC_API_KEY", "plan").encode()
    prefix = b'{"type":"system","subtype":"init"}\n' if "stream-json" in args else b""
    os.write(1, prefix + b"partial-stdout:" + key)
    os.write(2, b"partial-stderr:" + key)
    time.sleep(30)
    sys.exit(99)
rc = {"success": 0, "empty": 0, "failure": 23, "timeout": 124,
      "limit": 1, "auth": 1}[case]
message = {"limit": "API Error: 429 usage limit", "auth": "API Error: 401 Unauthorized"}.get(case, "provider failure")
body = "" if case == "empty" else "fixture findings\nAPPROVE\n"
print("provider diagnostic", file=sys.stderr)
if name == "codex":
    if rc:
        print("ERROR: " + message, file=sys.stderr)
    else:
        Path(args[args.index("-o") + 1]).write_text(body)
        print("provider progress")
elif name == "claude":
    stream = "stream-json" in args
    if stream:
        print(json.dumps({"type": "result", "subtype": "success", "is_error": bool(rc),
                          "result": message if rc else body}))
    else:
        print(message if rc else body, end="\n" if rc else "")
elif name == "agy":
    print(json.dumps({"event": "result", "result": {
        "status": "FAILED" if rc else "SUCCESS", "response": "" if rc else body,
        "error": message if rc else ""}}))
elif name == "muse":
    print(json.dumps({"payload_type": "run.model.configured", "payload": {"model_id": "muse-spark-1.3"}}))
    print(json.dumps({"payload_type": "run.terminal.completed", "payload": {
        "terminal": "failed" if rc else "completed", "text": "" if rc else body,
        "reason": message if rc else ""}}))
else:
    if rc:
        print(message, file=sys.stderr)
    else:
        print(body, end="")
sys.exit(rc)
'''
# Stable, private temporary paths make stderr and artifact comparisons byte exact.
MKTEMP = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
counter = Path(os.environ["PRESERVE_COUNTER"])
n = int(counter.read_text()) + 1
counter.write_text(str(n))
if os.environ["PRESERVE_CASE"] == "abort" and n == 1:
    sys.exit(42)
args = [a for a in sys.argv[1:] if not a.startswith("-")]
p = Path(args[0].replace("XXXXXX", str(n).zfill(6)) if args else os.environ["TMPDIR"] + "/tmp." + str(n))
if "-d" in sys.argv:
    p.mkdir(mode=0o700)
else:
    p.touch(mode=0o600, exist_ok=False)
print(p)
'''

with tempfile.TemporaryDirectory(prefix="mmo-preservation-") as temp:
    work = Path(temp)
    bindir, repo, home, artifacts, runtime = [work / x for x in ("bin", "repo", "home", "artifacts", "runtime")]
    for directory in (bindir, repo, home):
        directory.mkdir()
    for name in ("codex", "claude", "grok", "agy", "muse", "qwen-local"):
        (bindir / name).write_text(CLI)
        (bindir / name).chmod(0o755)
    (bindir / "mktemp").write_text(MKTEMP)
    (bindir / "mktemp").chmod(0o755)
    (bindir / "curl").write_text('#!/usr/bin/env bash\nprintf \'[{"is_processing":false}]\\n200\\n\'\n')
    (bindir / "curl").chmod(0o755)
    (work / "key").write_text("dummy-preservation-key\n")
    (work / "blocked").write_text("not a directory\n")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (repo / "app.txt").write_text("base\n")
    subprocess.run(["git", "-C", str(repo), "add", "app.txt"], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=t@t", "commit", "-qm", "base"], check=True)
    environment = {k: v for k, v in os.environ.items() if not k.startswith(("MMO_", "ANTHROPIC_", "CLAUDE_", "GROK_"))}
    environment.update({"PATH": f"{bindir}:{os.environ['PATH']}", "HOME": str(home),
                        "TMPDIR": str(runtime), "PRESERVE_COUNTER": str(work / "counter"),
                        "MMO_LEG_ENV": "PRESERVE_CASE", "MMO_QWEN_LOCAL_RUN": str(bindir / "qwen-local"),
                        "MMO_CLAUDE_API_KEY_FILE": str(work / "key"), "OPENAI_BASE_URL": "http://127.0.0.1:9/v1"})

    def run(source, provider, extra, case, destination):
        for directory in (artifacts, runtime):
            shutil.rmtree(directory, ignore_errors=True)
            directory.mkdir()
        (work / "counter").write_text("0")
        rows = work / "outcomes.tsv"
        rows.unlink(missing_ok=True)
        env = {**environment, "PRESERVE_CASE": case,
               "MMO_OUTCOMES_FILE": str(rows if destination == "writable" else work / "blocked" / "outcomes.tsv")}
        args = ["bash", str(source / f"run-{provider}.sh"), "--mode", "implement", "--repo", str(repo),
                "--out", str(artifacts / "body"), "--timeout",
                {"bad-args": "0", "deadline": "1"}.get(case, "10")]
        for flag in extra:
            args.append(flag)
            if flag == "--stream-log":
                args.append(str(artifacts / "stream"))
        result = subprocess.run(args, input=b"preservation-input-682\n", capture_output=True, env=env, timeout=20)
        assert result.returncode == expected[case], (provider, case, destination, result.returncode, result.stderr)
        if destination == "writable":
            lines = rows.read_text().splitlines()
            assert len(lines) == 2 and lines[1].split("\t")[8] == str(expected[case]), lines
        files = {str(path.relative_to(artifacts)): path.read_bytes() for path in artifacts.rglob("*") if path.is_file()}
        if case == "deadline":
            key = b"[REDACTED]" if "--api" in extra else b"plan"
            stream = "--stream-log" in extra
            prefix = b'{"type":"system","subtype":"init"}\n' if stream else b""
            assert files["stream" if stream else "body"] == prefix + b"partial-stdout:" + key, files
            assert files["body.stderr"] == b"partial-stderr:" + key, files
            assert result.stdout == b"", result.stdout
        return result.returncode, result.stdout, result.stderr, files

    cases = 0
    comparisons = 0
    for variant, (provider, extra) in variants.items():
        for case in expected:
            if case == "deadline" and provider != "claude":
                continue
            observations = []
            for destination in ("writable", "blocked"):
                observed = run(scripts, provider, extra, case, destination)
                observations.append(observed)
                if baseline:
                    before = run(baseline, provider, extra, case, destination)
                    for label, old, new in zip(("exit", "stdout", "stderr", "artifacts"), before, observed):
                        assert old == new, (variant, case, destination, label, old, new)
                    comparisons += 1
                cases += 1
            assert observations[0] == observations[1], (variant, case, "outcome destination changed observable output")
            print(f"PASS: preservation: {variant} {case}: writable/blocked outcomes, exact exit/output/artifacts", flush=True)
    print(f"Runner preservation: {cases} scenarios PASS, 0 FAIL; {cases // 2} destination comparisons; {comparisons} baseline comparisons.")
