#!/usr/bin/env python3
"""Cooperative active-epic guard. Marker helpers + open-PR check.

Blockers require a valid body marker (<!-- saas-epic: … -->). Unmarked
epic/<n> branch names are advisory only (listed under advisory, never exit 3).
"""

from __future__ import annotations

import argparse
import json
import os
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


def classify_prs(prs: list[dict[str, Any]], branch: str) -> dict[str, Any]:
    """Split open PRs into marker blockers, same-branch mine, and advisory."""
    active: list[dict[str, Any]] = []
    advisory: list[dict[str, Any]] = []

    for pr in prs:
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
            advisory.append(
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

    # Only marker-bearing PRs can block mutation.
    blockers = [
        a
        for a in active
        if a.get("marker") == "body" and a.get("branch") and a["branch"] != branch
    ]
    mine = [
        a
        for a in active
        if a.get("marker") == "body" and a.get("branch") == branch
    ]
    return {
        "ok": len(blockers) == 0,
        "branch": branch,
        "active": active,
        "mine": mine,
        "blockers": blockers,
        "advisory": advisory,
    }


def _parse_pr_list_json(stdout: str, *, context: str) -> list[dict[str, Any]]:
    """Parse gh pr list JSON; fail closed on empty-unexpected or decode errors."""
    raw = stdout if stdout is not None else ""
    try:
        batch = json.loads(raw or "[]")
    except json.JSONDecodeError as exc:
        print(
            f"epic-active: invalid JSON from gh ({context}): {exc}",
            file=sys.stderr,
        )
        raise SystemExit(1) from exc
    if not isinstance(batch, list):
        print(
            f"epic-active: gh JSON must be a list ({context})",
            file=sys.stderr,
        )
        raise SystemExit(1)
    for item in batch:
        if not isinstance(item, dict):
            print(
                f"epic-active: gh JSON list items must be objects ({context})",
                file=sys.stderr,
            )
            raise SystemExit(1)
    return batch


def _gh_json(repo: str) -> list[dict[str, Any]]:
    """List open PRs (gh max 100 per call). Prefer head:epic/ search first.

    Test hook: EPIC_ACTIVE_PR_JSON — if set, parse that string as the PR list
    and skip network (used by unit tests).
    """
    fixture = os.environ.get("EPIC_ACTIVE_PR_JSON")
    if fixture is not None:
        return _parse_pr_list_json(fixture, context="EPIC_ACTIVE_PR_JSON")

    by_num: dict[Any, dict[str, Any]] = {}
    saw_success = False

    for extra in (
        ["--search", "head:epic/"],
        ["--search", "saas-epic"],
        [],
    ):
        label = " ".join(extra) if extra else "unfiltered"
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
        saw_success = True
        for pr in _parse_pr_list_json(proc.stdout, context=label):
            n = pr.get("number")
            if n is not None:
                by_num[n] = pr

    if not saw_success:
        print("epic-active: gh pr list produced no successful responses", file=sys.stderr)
        raise SystemExit(1)

    return list(by_num.values())


def cmd_check(args: argparse.Namespace) -> int:
    repo = args.repo
    branch = args.branch
    if not repo:
        if os.environ.get("EPIC_ACTIVE_PR_JSON") is not None:
            repo = "test/repo"
        else:
            proc = subprocess.run(
                [
                    "gh",
                    "repo",
                    "view",
                    "--json",
                    "nameWithOwner",
                    "-q",
                    ".nameWithOwner",
                ],
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
        if proc.returncode == 0 and proc.stdout.strip():
            branch = proc.stdout.strip()
        else:
            # Fixture / non-git cwd: default for tests and dry hosts
            branch = "main"

    classified = classify_prs(_gh_json(repo), branch)
    out = {
        "ok": classified["ok"],
        "repo": repo,
        "branch": classified["branch"],
        "active": classified["active"],
        "mine": classified["mine"],
        "blockers": classified["blockers"],
        "advisory": classified["advisory"],
    }
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    if classified["advisory"]:
        print(
            "epic-active: advisory unmarked epic/* branches (not blockers): "
            + ", ".join(
                f"#{a.get('pr')} ({a.get('branch')})" for a in classified["advisory"]
            ),
            file=sys.stderr,
        )
    return 0 if classified["ok"] else 3


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
