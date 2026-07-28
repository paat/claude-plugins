---
name: market-scout
description: "Ranked SaaS improvement candidates from external market evidence with internal demand fallback."
---

# Market scout

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

Emits `.startup/demand/market-scout.jsonl` and `market-scout-report.md`. Falls back to
`demand-discovery.sh` when external sources are unavailable. Feed results into
`/startup`, `/growth`, `/improve`, `/goal-deliver` when the investor has no fresh task.
