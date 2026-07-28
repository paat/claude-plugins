#!/usr/bin/env python3
"""Conductor/worker boundary for Isolated Build.

preflight --base REF
post --base REF --receipt FILE

Exit 0 ok | 20 contract violation | 2 usage.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ALLOW = re.compile(
    r"^(\.codex-cast-[^/]+\.(md|json)|\.epic-[^/]+\.md|"
    r"\.epic-compose-draft\.md|\.epic-pr-body\.md)$"
)


def die(msg: str, code: int) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def usage() -> None:
    die(
        "usage: isolated-build-assert.py preflight --base REF | "
        "post --base REF --receipt FILE",
        2,
    )


def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True)


def resolve_base(ref: str) -> str:
    try:
        return run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"]).strip()
    except subprocess.CalledProcessError:
        die(f"isolated-build-assert: invalid --base: {ref}", 2)
        raise  # pragma: no cover


def product_paths(base: str) -> list[str]:
    chunks: list[str] = []
    for cmd in (
        ["git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, "--"],
        ["git", "diff", "--name-only", "--cached", "--diff-filter=ACDMRTUXB", base, "--"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ):
        try:
            chunks.append(run(cmd))
        except subprocess.CalledProcessError as e:
            die(f"isolated-build-assert: git failed: {e}", 2)
    paths = sorted({p for p in "\n".join(chunks).splitlines() if p and not ALLOW.match(p)})
    return paths


def parse_args(argv: list[str]) -> tuple[str, str | None]:
    base_ref = ""
    receipt: str | None = None
    i = 0
    while i < len(argv):
        if argv[i] == "--base" and i + 1 < len(argv):
            base_ref = argv[i + 1]
            i += 2
        elif argv[i] == "--receipt" and i + 1 < len(argv):
            receipt = argv[i + 1]
            i += 2
        else:
            usage()
    if not base_ref:
        usage()
    return base_ref, receipt


def ensure_repo() -> None:
    try:
        run(["git", "rev-parse", "--is-inside-work-tree"])
    except subprocess.CalledProcessError:
        die("isolated-build-assert: not a git worktree", 2)


def emit(obj: dict) -> None:
    print(json.dumps(obj, separators=(",", ":")))


def preflight(base: str) -> None:
    paths = product_paths(base)
    if paths:
        print("isolated-build-assert: product dirty before worker:", file=sys.stderr)
        for p in paths:
            print(f"  {p}", file=sys.stderr)
        die("isolated-build-assert: preflight failed — conductor must not implement", 20)
    emit({"ok": True, "phase": "preflight", "base": base, "product_dirty": False})


def post(base: str, receipt_path: str) -> None:
    path = Path(receipt_path)
    if not path.is_file():
        die(f"isolated-build-assert: receipt missing: {receipt_path}", 2)
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        die("isolated-build-assert: invalid JSON receipt", 2)
    paths = product_paths(base)
    if not paths:
        emit(
            {
                "ok": True,
                "phase": "post",
                "base": base,
                "product_dirty": False,
                "receipt_required": False,
            }
        )
        return
    mode = receipt.get("mode") or ""
    outcome = receipt.get("outcome") or ""
    exit_code = receipt.get("exit_code")
    commit_sha = receipt.get("commit_sha") or ""
    if mode != "implement":
        die("isolated-build-assert: receipt mode must be implement", 20)
    if outcome != "success" or exit_code != 0:
        die(
            f"isolated-build-assert: implement worker failed "
            f"(outcome={outcome} exit={exit_code})",
            20,
        )
    if commit_sha != base:
        print(
            f"isolated-build-assert: receipt commit_sha must equal --base ({base}), "
            f"got: {commit_sha or 'none'}",
            file=sys.stderr,
        )
        die(
            "isolated-build-assert: parent product edits before cast break this binding",
            20,
        )
    emit(
        {
            "ok": True,
            "phase": "post",
            "base": base,
            "product_dirty": True,
            "receipt_required": True,
            "receipt": receipt_path,
            "product_paths": paths,
        }
    )


def main(argv: list[str]) -> None:
    if len(argv) < 1:
        usage()
    cmd, rest = argv[0], argv[1:]
    ensure_repo()
    base_ref, receipt = parse_args(rest)
    base = resolve_base(base_ref)
    if cmd == "preflight":
        preflight(base)
    elif cmd == "post":
        if not receipt:
            usage()
        post(base, receipt)
    else:
        usage()


if __name__ == "__main__":
    main(sys.argv[1:])
