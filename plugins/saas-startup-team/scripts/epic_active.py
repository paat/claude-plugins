#!/usr/bin/env python3
"""Cooperative active-epic guard (Phase 1). Marker helpers + open-PR check."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any

MARKER_RE = re.compile(
    r"<!--\s*saas-epic:\s*(\d+)\s+sha=([0-9a-fA-F]+)\s+children=([0-9,\s]*)\s*-->"
)
BRANCH_EPIC_RE = re.compile(r"^epic/(\d+)\b")


def marker_line(epic: str, body_sha: str, children: str) -> str:
    return f"<!-- saas-epic: {epic} sha={body_sha} children={children} -->\n"


def cmd_marker(args: argparse.Namespace) -> int:
    sys.stdout.write(marker_line(args.epic, args.body_sha, args.children))
    return 0


def _gh_json(repo: str) -> list[dict[str, Any]]:
    """List open PRs (gh max 100 per call). Prefer head:epic/ search first."""
    by_num: dict[Any, dict[str, Any]] = {}

    def _ingest(stdout: str) -> None:
        try:
            batch = json.loads(stdout or "[]")
        except json.JSONDecodeError:
            return
        if not isinstance(batch, list):
            return
        for pr in batch:
            n = pr.get("number")
            if n is not None:
                by_num[n] = pr

    for extra in (
        ["--search", "head:epic/"],
        ["--search", "saas-epic"],
        [],
    ):
        proc = subprocess.run(
            [
                "gh",
                "pr",
                "list",
                "--repo",
                repo,
                "--state",
                "open",
                "--limit",
                "100",
                "--json",
                "number,title,headRefName,body,url",
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            if not extra:
                print(
                    f"epic-active: gh pr list failed: {proc.stderr.strip()}",
                    file=sys.stderr,
                )
                raise SystemExit(1)
            continue
        _ingest(proc.stdout)

    return list(by_num.values())


def cmd_check(args: argparse.Namespace) -> int:
    repo = args.repo
    branch = args.branch
    if not repo:
        proc = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            print("epic-active: cannot resolve --repo", file=sys.stderr)
            return 1
        repo = proc.stdout.strip()
    if not branch:
        proc = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
        )
        branch = (proc.stdout or "").strip()

    active: list[dict[str, Any]] = []
    for pr in _gh_json(repo):
        body = pr.get("body") or ""
        m = MARKER_RE.search(body)
        head = pr.get("headRefName") or ""
        if m:
            kids = [int(x) for x in re.findall(r"\d+", m.group(3))]
            active.append(
                {
                    "epic": int(m.group(1)),
                    "body_sha": m.group(2),
                    "children": kids,
                    "pr": pr.get("number"),
                    "branch": head,
                    "url": pr.get("url"),
                    "marker": "body",
                }
            )
            continue
        tm = BRANCH_EPIC_RE.match(head)
        if tm:
            active.append(
                {
                    "epic": int(tm.group(1)),
                    "body_sha": "",
                    "children": [],
                    "pr": pr.get("number"),
                    "branch": head,
                    "url": pr.get("url"),
                    "marker": "branch-name-only",
                }
            )

    blockers = [a for a in active if a.get("branch") and a["branch"] != branch]
    mine = [a for a in active if a.get("branch") == branch]
    out = {
        "ok": len(blockers) == 0,
        "repo": repo,
        "branch": branch,
        "active": active,
        "mine": mine,
        "blockers": blockers,
    }
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if not blockers else 3


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("marker", help="Print PR body marker line")
    m.add_argument("--epic", required=True)
    m.add_argument("--body-sha", required=True)
    m.add_argument("--children", required=True)
    m.set_defaults(func=cmd_marker)

    c = sub.add_parser("check", help="Check for blocking active epic PRs")
    c.add_argument("--repo", default="")
    c.add_argument("--branch", default="")
    c.set_defaults(func=cmd_check)

    args = p.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
