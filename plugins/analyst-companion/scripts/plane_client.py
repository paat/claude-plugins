#!/usr/bin/env python3
"""Minimal Plane work-item client for the analyst-companion plugin.

Auth: PLANE_API_TOKEN (workspace API token). Base URL: PLANE_BASE_URL
(required, no default — set it to your Plane instance's URL). Used by /meeting-end to
create reviewed work items.

CLI:
    PLANE_API_TOKEN=... python plane_client.py create \
        --workspace SLUG --project NAME_OR_UUID \
        --name "Title" --description-html-file body.html [--priority high] [--dry-run]
"""
from __future__ import annotations
import argparse, json, os, sys, time
import urllib.error, urllib.request


def build_payload(name: str, description_html: str = "", priority: str | None = None,
                  state: str | None = None, labels: list[str] | None = None) -> dict:
    """Build the work-item POST body, omitting empty/None fields."""
    payload: dict = {"name": name}
    if description_html:
        payload["description_html"] = description_html
    if priority:
        payload["priority"] = priority
    if state:
        payload["state"] = state
    if labels:
        payload["labels"] = labels
    return payload


class Plane:
    def __init__(self, base_url: str, token: str, workspace_slug: str):
        self.base = base_url.rstrip("/")
        self.token = token
        self.ws = workspace_slug

    def _req(self, method: str, path: str, body: dict | None = None):
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(6):
            req = urllib.request.Request(url, method=method, data=data)
            req.add_header("X-API-Key", self.token)
            req.add_header("Accept", "application/json")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < 5:
                    time.sleep(30 * (attempt + 1)); continue
                raise SystemExit(f"Plane {method} {path} failed {e.code}: {e.read().decode('utf-8','replace')}")
        raise SystemExit(f"Plane {method} {path} failed after retries")

    def list_projects(self) -> list[dict]:
        r = self._req("GET", f"/api/v1/workspaces/{self.ws}/projects/")
        # Plane returns either a paginated dict or a flat list depending on version.
        return r["results"] if isinstance(r, dict) and "results" in r else r

    def resolve_project(self, name_or_id: str) -> str:
        """Return the project UUID, accepting either a UUID or a project name."""
        projects = self.list_projects()
        proj = next((p for p in projects if p["id"] == name_or_id or p["name"] == name_or_id), None)
        if not proj:
            raise SystemExit(f"Project '{name_or_id}' not found. Available: "
                             + ", ".join(p["name"] for p in projects))
        return proj["id"]

    def create_issue(self, project_id: str, payload: dict) -> dict:
        return self._req("POST", f"/api/v1/workspaces/{self.ws}/projects/{project_id}/issues/", payload)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--workspace", required=True)
    c.add_argument("--project", required=True)
    c.add_argument("--name", required=True)
    c.add_argument("--description-html-file")
    c.add_argument("--priority")
    c.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    desc = ""
    if args.description_html_file:
        with open(args.description_html_file, encoding="utf-8") as fh:
            desc = fh.read()
    payload = build_payload(name=args.name, description_html=desc, priority=args.priority)

    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    token = os.environ.get("PLANE_API_TOKEN")
    if not token:
        raise SystemExit("PLANE_API_TOKEN not set")
    base = os.environ.get("PLANE_BASE_URL")
    if not base:
        raise SystemExit("set PLANE_BASE_URL to your Plane instance URL")
    plane = Plane(base, token, args.workspace)
    project_id = plane.resolve_project(args.project)
    created = plane.create_issue(project_id, payload)
    print(json.dumps({"id": created.get("id"), "name": created.get("name")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
