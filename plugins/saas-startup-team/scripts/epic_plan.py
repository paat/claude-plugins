#!/usr/bin/env python3
"""Deterministic epic-body checklist parser (Phase 1). Pure: no GitHub/git."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

TASK_RE = re.compile(r"^\s*(?:[-*]|\d+\.)\s+\[([ xX])\]\s+(.+)$")
ISSUE_START_RE = re.compile(r"^\*{0,2}#(\d+)\*{0,2}\b(?:\s*[—–:-]\s*|\s+)?(.*)$")
EXTRA_ISSUE_RE = re.compile(r"#\d+")
CROSS_REPO_RE = re.compile(r"\b[\w.-]+/[\w.-]+#\d+\b")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
TASK_PREFIX_RE = re.compile(r"^\s*(?:[-*]|\d+\.)\s+\[[ xX]\]\s+")


def strip_noise(text: str) -> str:
    # Balanced fenced blocks (``` or ~~~), then unclosed fences to EOF.
    text = re.sub(r"```.*?```", "\n", text, flags=re.S)
    text = re.sub(r"~~~.*?~~~", "\n", text, flags=re.S)
    text = re.sub(r"```[\s\S]*\Z", "\n", text)
    text = re.sub(r"~~~[\s\S]*\Z", "\n", text)
    text = re.sub(r"<!--.*?-->", "\n", text, flags=re.S)
    return text


def parse_body(body: str) -> dict[str, Any]:
    body = body.replace("\r\n", "\n").replace("\r", "\n")
    lines = strip_noise(body).split("\n")
    children: list[dict[str, Any]] = []
    seen: dict[int, int] = {}
    current_track: str | None = None
    errors: list[str] = []

    for idx, line in enumerate(lines, start=1):
        hm = HEADING_RE.match(line)
        if hm:
            title = hm.group(1).strip()
            if re.search(r"Track\s+[A-Za-z0-9]", title, re.I):
                current_track = title
            continue

        tm = TASK_RE.match(line)
        if not tm:
            if TASK_PREFIX_RE.match(line):
                rest = TASK_PREFIX_RE.sub("", line)
                if CROSS_REPO_RE.search(rest):
                    errors.append(f"line {idx}: cross-repo reference not allowed")
                elif re.search(r"#\d+", rest) and not ISSUE_START_RE.match(rest.strip()):
                    errors.append(f"line {idx}: ambiguous issue task syntax")
            continue

        checked = tm.group(1).lower() == "x"
        payload = tm.group(2).strip()
        if CROSS_REPO_RE.search(payload):
            errors.append(f"line {idx}: cross-repo reference not allowed")
            continue

        im = ISSUE_START_RE.match(payload)
        if not im:
            if re.search(r"#\d+", payload):
                errors.append(f"line {idx}: issue number must lead the task payload")
            continue

        num = int(im.group(1))
        title = (im.group(2) or "").strip()
        if num <= 0:
            errors.append(f"line {idx}: invalid issue number {num}")
            continue
        if len(EXTRA_ISSUE_RE.findall(payload)) > 1:
            errors.append(f"line {idx}: multiple issue numbers on one item")
            continue
        if num in seen:
            errors.append(
                f"line {idx}: duplicate child #{num} (first at line {seen[num]})"
            )
            continue
        seen[num] = idx
        title = re.sub(r"\s*\*\*\s*$", "", title).strip()
        children.append(
            {
                "number": num,
                "checked": checked,
                "title": title,
                "track": current_track,
                "line": idx,
            }
        )

    if errors:
        for e in errors:
            print(f"epic-plan: {e}", file=sys.stderr)
        raise SystemExit(1)
    if not children:
        print(
            "epic-plan: zero children — refuse (no checklist items leading with #N)",
            file=sys.stderr,
        )
        raise SystemExit(1)

    checked_n = sum(1 for c in children if c["checked"])
    return {
        "ok": True,
        "children": children,
        "counts": {
            "total": len(children),
            "unchecked": len(children) - checked_n,
            "checked": checked_n,
        },
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--file", type=Path, help="Epic body file (default: stdin)")
    args = p.parse_args(argv)
    try:
        body = args.file.read_text(encoding="utf-8") if args.file else sys.stdin.read()
    except OSError as exc:
        print(f"epic-plan: {exc}", file=sys.stderr)
        return 2
    try:
        out = parse_body(body)
    except SystemExit as exc:
        return int(exc.code or 1)
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
