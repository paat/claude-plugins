---
name: epic-compose
description: "Scan open issues, file focused epic, auto-run /epic. Usage: /epic-compose [--dry-run] [--compose-only] [hint]"
---

# Epic compose

`docs/legacy/epic-compose.md`. Flow: scan → draft one focused epic (2–12 leaves) →
validate → file → **run `skills/epic/SKILL.md` on new N** (same turn).

1. Health-preflight `--require-gh --check-sync`
2. `python3 scripts/epic_scan.py --repo OWNER/REPO > /tmp/epic-scan.json`
3. Pick one theme; no group → **no-op**
4. Draft body with `- [ ] #N — title`; validate with `epic_compose_validate.py`
5. `--dry-run` → print only. `--compose-only` → `gh issue create` and stop.
6. Default: create epic, then run `/epic N` same turn (no second user prompt).

| Result | Meaning |
|--------|---------|
| `complete` | filed + `/epic` done |
| `filed` / `draft` / `no-op` / `blocked` | compose-only / dry-run / none / fail |
