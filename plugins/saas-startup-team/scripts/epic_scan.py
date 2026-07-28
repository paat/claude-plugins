#!/usr/bin/env python3
"""Inventory open issues for epic composition (no clustering LLM).

Emits eligible leaf issues and open epic checklist occupancy so /epic-compose
can draft a focused epic without double-booking children.

Usage:
  epic_scan.py --repo OWNER/REPO
  epic_scan.py --issues-file PATH [--epics-file PATH]

Exit 0 + JSON on success; 2 bad args; 1 gh/IO error.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

CHECK_ITEM_RE = re.compile(
    r"^\s*(?:[-*]|\d+\.)\s+\[[ xX]\]\s+\*{0,2}#(\d+)\b",
    re.M,
)
EXCLUDE_LABELS = frozenset(
    {
        "epic",
        "needs-human",
        "needs_human",
        "wontfix",
        "duplicate",
        "invalid",
    }
)


def _gh_json(args: list[str]) -> Any:
    proc = subprocess.run(
        ["gh", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"epic-scan: gh failed: {proc.stderr.strip()}", file=sys.stderr)
        raise SystemExit(1)
    try:
        return json.loads(proc.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"epic-scan: invalid gh JSON: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


def _labels(issue: dict[str, Any]) -> list[str]:
    raw = issue.get("labels") or []
    names: list[str] = []
    for lab in raw:
        if isinstance(lab, str):
            names.append(lab)
        elif isinstance(lab, dict) and lab.get("name"):
            names.append(str(lab["name"]))
    return names


def _parse_children(body: str) -> list[int]:
    return [int(m.group(1)) for m in CHECK_ITEM_RE.finditer(body or "")]


def scan(
    issues: list[dict[str, Any]],
    *,
    repo: str,
) -> dict[str, Any]:
    open_epics: list[dict[str, Any]] = []
    claimed: set[int] = set()
    excluded: dict[str, list[int]] = {
        "epic": [],
        "needs_human": [],
        "on_open_epic": [],
        "other_label": [],
    }

    for iss in issues:
        num = int(iss["number"])
        labs = {x.lower() for x in _labels(iss)}
        if "epic" in labs:
            kids = _parse_children(iss.get("body") or "")
            open_epics.append(
                {
                    "number": num,
                    "title": iss.get("title") or "",
                    "children": kids,
                    "labels": _labels(iss),
                }
            )
            for k in kids:
                claimed.add(k)
            excluded["epic"].append(num)

    eligible: list[dict[str, Any]] = []
    for iss in issues:
        num = int(iss["number"])
        labs = {x.lower() for x in _labels(iss)}
        if "epic" in labs:
            continue
        if labs & {"needs-human", "needs_human"}:
            excluded["needs_human"].append(num)
            continue
        if labs & {"wontfix", "duplicate", "invalid"}:
            excluded["other_label"].append(num)
            continue
        if num in claimed:
            excluded["on_open_epic"].append(num)
            continue
        eligible.append(
            {
                "number": num,
                "title": iss.get("title") or "",
                "labels": _labels(iss),
                "createdAt": iss.get("createdAt") or iss.get("created_at") or "",
                "updatedAt": iss.get("updatedAt") or iss.get("updated_at") or "",
            }
        )

    # Deterministic label-affinity clusters (suggestion only; agent chooses focus).
    by_label: dict[str, list[int]] = {}
    for iss in eligible:
        for lab in iss["labels"]:
            key = lab.lower()
            if key in EXCLUDE_LABELS:
                continue
            by_label.setdefault(key, []).append(iss["number"])
    clusters = []
    for lab, nums in sorted(by_label.items(), key=lambda x: (-len(x[1]), x[0])):
        uniq = sorted(set(nums))
        if 2 <= len(uniq) <= 12:
            clusters.append({"label": lab, "children": uniq, "size": len(uniq)})

    return {
        "ok": True,
        "repo": repo,
        "counts": {
            "open_issues": len(issues),
            "open_epics": len(open_epics),
            "eligible": len(eligible),
            "claimed_on_epics": len(claimed),
        },
        "open_epics": open_epics,
        "excluded": excluded,
        "eligible": eligible,
        "suggested_clusters": clusters[:20],
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", default="", help="OWNER/REPO (default: gh repo view)")
    p.add_argument(
        "--issues-file",
        type=Path,
        help="Fixture: JSON array of issues (number,title,body,labels,state)",
    )
    p.add_argument("--limit", type=int, default=200, help="Max open issues to list")
    args = p.parse_args(argv)

    if args.issues_file:
        try:
            issues = json.loads(args.issues_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"epic-scan: {exc}", file=sys.stderr)
            return 1
        if not isinstance(issues, list):
            print("epic-scan: issues-file must be a JSON array", file=sys.stderr)
            return 1
        repo = args.repo or "fixture/repo"
    else:
        repo = args.repo
        if not repo:
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
                print("epic-scan: cannot resolve --repo", file=sys.stderr)
                return 1
            repo = proc.stdout.strip()
        issues = _gh_json(
            [
                "issue",
                "list",
                "--repo",
                str(repo),
                "--state",
                "open",
                "--limit",
                str(args.limit),
                "--json",
                "number,title,body,labels,createdAt,updatedAt,state",
            ]
        )
        if not isinstance(issues, list):
            print("epic-scan: unexpected issue list type", file=sys.stderr)
            return 1

    out = scan(issues, repo=str(repo))
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
