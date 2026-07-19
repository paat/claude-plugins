---
name: issue-file
description: >
  File or reuse a GitHub issue for agent-discovered defects with open-issue
  dedup, PII park, and optional pattern-key re-occurrence. Use when filing
  investigate/replay/plugin defects or any new public issue from automation.
  Do not use for maintain partial-delivery (park residual on parent) or for
  monitor-nightly (uses monitor-dedup.sh).
---

# Issue file

Shared helper: `scripts/issue-file.sh` (resolve via plugin root).

## When

- New defect / RCA / plugin-bug filing with optional stable **pattern key**
- Need create-or-comment without post-create GitHub search fail-closed

## When not

- Maintain partial fix → residual on same parent (no child issue)
- Monitor recurring failures with entity state → `scripts/monitor-dedup.sh`
- Lessons public filing → `scripts/lesson-file.sh`

## Contract

1. Build title + body. If you have an **authoritative** pattern key (caller-owned,
   single-line lowercase `^[a-z0-9][a-z0-9:_-]*$`), pass `--pattern-key`. Do **not**
   invent product semantics for a key; omit the flag and use title dedup instead.
2. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-file.sh" \
  --repo OWNER/REPO \
  --title "..." \
  --body-file path.md \
  [--pattern-key "ops:example:key"] \
  [--labels a,b] \
  [--digest-file path] \
  [--dry-run]
```

3. Outcomes — URL on stdout when filed/reused; one stderr line `issue-file: status=...`:

| status | exit | meaning | retry? |
|--------|------|---------|--------|
| `created` | 0 | new issue | no |
| `reused` | 0 | commented on open match (or title-adopted + marker backfill) | no |
| `dry-run` `action=file` | 0 | would file/dedup | n/a |
| `dry-run` `action=park` | 3 | would park sensitive (no human-tasks write) | n/a |
| `parked` | 3 | PII; human-tasks written | fix content, then re-run |
| `ambiguous` | 1 | multi open match | do not invent merge |
| `precheck_failed` | 1 | search/schema/cap/body-fetch | fix env; do not blind create |
| `comment_failed` / `create_failed` | 1 | gh mutation failed | inspect; careful retry |
| `unknown` `mutation_possible=true` | 1 | create output unparseable | **do not auto-retry** |
| `usage` | 2 | bad args / env | fix invocation |

Guarantee is **open-issue** duplicate resistance only (not closed-issue reopen,
not full at-most-once under concurrency/search lag).

Marker (when key set): whole-line `**Pattern:** \`key\`` only (embedded prose does not match).
