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
- Optional **source-repo escalate** so a product-repo filing also lands once on
  the plugin/source tracker for the same pattern key

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
  [--source-repo OWNER/REPO] \
  [--source-escalate none|comment] \
  [--labels a,b] \
  [--digest-file path] \
  [--dry-run]
```

3. Outcomes — URL on stdout when filed/reused (always the **local** `--repo`
   issue); one stderr line `issue-file: status=...`; optional second line
   `issue-file: source_escalate=...` after local success when escalate is on:

| status / source_escalate | exit | meaning | retry? |
|--------------------------|------|---------|--------|
| `created` | 0 | new issue on local repo | no |
| `reused` | 0 | commented on open match (or title-adopted + marker backfill) | no |
| `source_escalate=created` | 0 | new issue on `--source-repo` after local success | no |
| `source_escalate=reused` | 0 | commented on open source match (same pattern key) | no |
| `dry-run` `action=file` | 0 | would file/dedup (and would source-escalate when flags set) | n/a |
| `dry-run` `action=park` | 3 | would park sensitive (no human-tasks write) | n/a |
| `parked` | 3 | PII; human-tasks written | fix content, then re-run |
| `ambiguous` / `source_escalate=ambiguous` | 1 | multi open match | do not invent merge |
| `precheck_failed` / `source_escalate=precheck_failed` | 1 | search/schema/cap/body-fetch | fix env; do not blind create |
| `comment_failed` / `create_failed` (local or source) | 1 | gh mutation failed | inspect; careful retry |
| `unknown` `mutation_possible=true` | 1 | create output unparseable | **do not auto-retry** |
| `usage` | 2 | bad args / env | fix invocation |

### Source-repo escalate (`--source-escalate comment`)

- Default is `none` (no source traffic). Opt in explicitly.
- Requires `--source-repo OWNER/REPO` and `--pattern-key`.
- Runs **after** a successful local create/reuse: same pattern-key pre-check
  ladder on the source repo, then comment on an open marker match or create
  **once**. Does not open a second source issue for the same key when an open
  match already exists.
- Local stdout URL is unchanged; source outcome is only on the
  `source_escalate=` stderr line.
- Guarantee remains **open-issue** duplicate resistance only (not closed-issue
  reopen, not full at-most-once under concurrency/search lag).

Marker (when key set): whole-line `**Pattern:** \`key\`` only (embedded prose does not match).
