# Learnings auto-routing + migrate command

Design for GitHub issue #14. Two-part change to `saas-startup-team`:

1. `scripts/auto-learn.sh` PostToolUse hook auto-routes new learnings directly to topic files in `docs/learnings/*.md` when it can classify confidently; uncertain entries fall back to a staging bucket in CLAUDE.md.
2. New `/saas-startup-team:learnings-migrate` command sweeps the staging bucket into topic files on demand, and handles first-time bootstrap when no topic files exist yet.

## Why

Currently `auto-learn.sh` appends every learning under `## Learnings` in CLAUDE.md as a flat list. Aruannik has 18+ unsorted entries accumulated there and topic files under `docs/learnings/` that were filled by hand. The flat list grows without bound and nothing routes entries into the topic files.

## Scope

- Auto-route on the hook's hot path (option B-with-fallback from brainstorming).
- Aruannik is the only current consumer; backward compat with older flat `## Learnings` layouts is non-destructive but not first-class — pre-existing flat entries are left alone, not rewritten.

## Component 1 — `scripts/auto-learn.sh` (hook)

### Current behaviour

The hook is a PostToolUse filter that fires on `.startup/(handoffs|reviews|signoffs|go-live)/*.md` writes. It emits a `systemMessage` instructing Claude to extract up to 3 learnings and append them under `## Learnings` in CLAUDE.md at git root.

### New behaviour

Same trigger and file filter. Only the `systemMessage` prompt body changes. New instruction, roughly:

> Read the file just written. Extract up to 3 reusable project learnings (tech decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge.
>
> Find git root. Ensure `CLAUDE.md` exists with a `# Project Learnings` H1 and a `## Learnings` H2.
>
> List files in `docs/learnings/*.md` at git root (if the dir exists). For each, read the first heading line to build a topic catalog (filename + heading).
>
> For each candidate learning:
> - Skip if semantically equivalent to any existing entry in any topic file or in `### Recent (unsorted)`.
> - If it clearly fits an existing topic file, append one dash-bullet to that file.
> - Otherwise ensure a `### Recent (unsorted)` subsection exists under `## Learnings` with comment `<!-- Uncertain/new-topic learnings staged here. Run /saas-startup-team:learnings-migrate to organise into docs/learnings/*.md. -->` and append the dash-bullet there.
>
> One dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries total. If nothing worth recording, do nothing.

### Behavioural notes

- **No `docs/learnings/` dir** → all entries go to Recent (first-time bootstrap). No dir creation by the hook.
- **Pre-existing flat `## Learnings` entries** → untouched. Only new entries are routed.
- **Dedup scope** → topic files *and* Recent (an entry queued in Recent should block a duplicate from being re-appended to a topic file in a later hook fire).
- **Append format** → unchanged (one dash per line, laconic).

## Component 2 — `commands/learnings-migrate.md`

New markdown command (pure prompt, no shell script). Frontmatter:

```yaml
---
name: learnings-migrate
description: Organise learnings staged in '### Recent (unsorted)' of CLAUDE.md into topic files under docs/learnings/. Bootstraps the topic catalog on first use.
user_invocable: true
---
```

### Flow (what the command tells Claude to do)

1. Resolve git root via `git rev-parse --show-toplevel`.
2. Read CLAUDE.md. Locate `### Recent (unsorted)` under `## Learnings` and extract dash-bullets. If section missing or empty, print `Nothing to migrate.` and exit.
3. List `docs/learnings/*.md`. If the dir does not exist, offer to create it. If the user declines, exit without changes (Recent entries stay put).
4. Build topic catalog: for each file, extract the first `^#{1,2} ` heading line; if none, fall back to the filename (stem, dashes → spaces). Store as `(path, display_name)` pairs.
5. **If topic catalog is empty (first-time bootstrap):**
   - Cluster Recent entries by theme (LLM-driven).
   - Propose a topic name per cluster. For each cluster, ask the user to confirm the name, rename, or merge into another cluster.
   - Create empty topic files with the confirmed names.
   - If the user declines/skips every cluster → exit with no changes (Recent stays put).
6. Classify each Recent entry against the catalog. Three buckets per entry:
   - **Match** — confident route to an existing topic file.
   - **New topic** — no existing topic fits; suggest a new topic name.
   - **Uncertain** — two or more topics could plausibly fit, or the entry is too generic.
7. Resolve non-match rows interactively, one prompt per row: pick existing topic, accept suggested new topic, rename, or skip.
8. Semantic dedup: for every resolved (entry, target) pair, compare against existing lines in **all topic files** (not just the target) and in any entries being migrated in the same run. If semantically equivalent to any, drop the row from the plan as a dup.
9. Print preview grouped by target file:
   - `docs/learnings/xbrl-taxonomy.md` ← 3 entries
   - `docs/learnings/business-marketing.md` ← 2 entries
   - `docs/learnings/new-topic-name.md` ← 1 entry (NEW FILE)
   - Skipped (remain in Recent): 2 entries
10. Ask `apply / skip: <rows> / cancel`.
11. On apply:
    - Append entries to each target file (create file if it's a new topic).
    - Rewrite CLAUDE.md with migrated entries removed from Recent; preserve skipped entries.
12. Print summary: `Migrated N entries into M files. K skipped. J new topics created.`

### Guarantees

- Non-destructive: only Recent is swept. Flat pre-existing `## Learnings` bullets outside Recent stay put.
- Existing topic file content is never modified or reordered — entries are only appended.
- Dedup is semantic, done by the LLM against existing lines in each target file.
- Uncertain entries the user skips remain in Recent until the next migrate run.

## Component 3 — version bump

- `plugins/saas-startup-team/.claude-plugin/plugin.json`: 0.30.1 → 0.31.0
- `.claude-plugin/marketplace.json` (root): same

Both must match (pre-push hook enforces it).

## Out of scope

- Auto-triggering migration from a Stop hook when Recent exceeds N entries (nice-to-have; issue mentions it, not needed for v1).
- Rewriting pre-existing flat `## Learnings` entries into Recent.
- A `misc.md` fallback topic file.
- Seeding `docs/learnings/` with plugin-provided topics (topics are project-specific).
- Maintaining a topic link list in CLAUDE.md above Recent (comment pointing to `docs/learnings/` is enough).

## Tests

- No new tests for the command (pure prompt, needs a live LLM).
- Run `tests/run-tests.sh` after the hook prompt change to confirm nothing asserts on the old message body.

## File change summary

| Path | Change |
|------|--------|
| `plugins/saas-startup-team/scripts/auto-learn.sh` | Replace `systemMessage` body with auto-routing instructions |
| `plugins/saas-startup-team/commands/learnings-migrate.md` | New file, prompt-only command |
| `plugins/saas-startup-team/.claude-plugin/plugin.json` | Bump version to 0.31.0 |
| `.claude-plugin/marketplace.json` | Bump saas-startup-team version to 0.31.0 |
