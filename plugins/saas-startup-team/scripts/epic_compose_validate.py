#!/usr/bin/env python3
"""Validate a draft epic body before filing (focused checklist gates).

Usage:
  epic_compose_validate.py --body-file PATH [--scan-file PATH]
  epic_compose_validate.py --body-file PATH --min 2 --max 12

Uses epic_plan.parse_body rules via subprocess to epic_plan.py.
Fails closed if plan invalid, size out of bounds, or children not eligible
when --scan-file provided.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--body-file", type=Path, required=True)
    p.add_argument("--scan-file", type=Path, help="epic_scan.py JSON output")
    p.add_argument("--min", type=int, default=2)
    p.add_argument("--max", type=int, default=12)
    args = p.parse_args(argv)

    plan_script = Path(__file__).resolve().parent / "epic_plan.py"
    try:
        body = args.body_file.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"epic-compose-validate: {exc}", file=sys.stderr)
        return 2

    proc = subprocess.run(
        [sys.executable, str(plan_script), "--file", str(args.body_file)],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(proc.stderr or "epic-compose-validate: epic_plan failed", file=sys.stderr)
        return 1
    try:
        plan = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        print(f"epic-compose-validate: plan JSON: {exc}", file=sys.stderr)
        return 1

    total = int(plan.get("counts", {}).get("total") or 0)
    if total < args.min or total > args.max:
        print(
            f"epic-compose-validate: child count {total} not in [{args.min},{args.max}]",
            file=sys.stderr,
        )
        return 1

    children = [int(c["number"]) for c in plan.get("children") or []]
    if len(children) != len(set(children)):
        print("epic-compose-validate: duplicate children", file=sys.stderr)
        return 1

    errors: list[str] = []
    if args.scan_file:
        try:
            scan = json.loads(args.scan_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"epic-compose-validate: scan-file: {exc}", file=sys.stderr)
            return 1
        eligible = {int(x["number"]) for x in scan.get("eligible") or []}
        claimed = set()
        for ex in (scan.get("excluded") or {}).get("on_open_epic") or []:
            claimed.add(int(ex))
        for ep in scan.get("open_epics") or []:
            for k in ep.get("children") or []:
                claimed.add(int(k))
        for n in children:
            if n not in eligible:
                errors.append(f"#{n} not in eligible leaf set")
            if n in claimed:
                errors.append(f"#{n} already on an open epic checklist")

    # Body must state outcome / done signal (lightweight)
    low = body.lower()
    if "done" not in low and "acceptance" not in low and "outcome" not in low:
        errors.append("body missing Done/acceptance/outcome section keyword")

    if errors:
        for e in errors:
            print(f"epic-compose-validate: {e}", file=sys.stderr)
        return 1

    out = {
        "ok": True,
        "children": children,
        "counts": plan.get("counts"),
        "title_guess": _title_guess(body),
    }
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


def _title_guess(body: str) -> str:
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("# ") and not s.startswith("## "):
            return s[2:].strip()[:120]
    return ""


if __name__ == "__main__":
    raise SystemExit(main())
