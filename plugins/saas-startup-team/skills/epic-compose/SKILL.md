---
name: epic-compose
description: "Scan open issues and file one focused GitHub epic for /epic. Usage: /epic-compose [--dry-run] [theme hint]"
---

# Epic compose

Scan open issues → one focused epic (2–12 leaves) → validate → file `label:epic`.
Implement with `/epic <n>`. Rules: `docs/legacy/epic-compose.md`.

1. Health-preflight (`--require-gh --check-sync`).
2. `python3 scripts/epic_scan.py --repo OWNER/REPO > /tmp/epic-scan.json`
3. Pick one theme from `eligible` / `suggested_clusters` (skip needs-human / on-epic).
   No group → **no-op**.
4. Draft Why/Done/OOS/Tracks with `- [ ] #N — title`.
5. `python3 scripts/epic_compose_validate.py --body-file /tmp/epic-body.md --scan-file /tmp/epic-scan.json`
6. `--dry-run` → print body. Else `gh issue create --label epic --body-file …` and point to `/epic <n>`.

No product implementation, merge, or leaf closes. One epic per run. No state machine.
