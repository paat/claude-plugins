# Plan: /learnings-migrate command (issue #14)

> **Universality rule:** The plugin MUST NOT hardcode any topic taxonomy. Topics are discovered from whatever `docs/learnings/*.md` files the project has. Nothing in this plan references project-specific domains (XBRL, compliance terms, language-specific content, etc.). The classifier reads each topic file's H1 + first paragraph at runtime to know what the topic is "about."

## Goal & Scope

Provide a mechanism in the `saas-startup-team` plugin that reads accumulated unsorted learnings in the project's `CLAUDE.md`, classifies each entry against the project's existing `docs/learnings/*.md` topic files, and migrates them in place. Must be generic (no hardcoded topics), safe (dry-run default), and cheap (one LLM pass).

**In scope**
- New slash command `/saas-startup-team:learnings-migrate`.
- Helper shell script that gathers inputs for the LLM.
- Safety: dry-run preview + single confirmation before writing.
- First-run bootstrap when `docs/learnings/` doesn't exist.
- Documentation updates.

**Out of scope**
- Changing the `auto-learn.sh` capture hook.
- Semantic de-duplication across topic files.
- Automatic Stop-hook running (optional follow-up).

## Current-state observations

1. `auto-learn.sh` instructs the agent to append to a `## Learnings` section of `CLAUDE.md`. Downstream projects often build their own `### Recent (unsorted)` subsection under `## Domain Learnings`. The migration tool must detect both layouts.
2. `auto-learn.sh` fires on `Edit|Write` for `.startup/(handoffs|reviews|signoffs|go-live)/*.md` — the migration tool must not write handoff-like files. Appending to `docs/learnings/*.md` is safe: no matching path.
3. Existing command style uses YAML frontmatter with `name`, `description`, `user_invocable: true` and numbered procedural steps.
4. Plugin uses `${CLAUDE_PLUGIN_ROOT}` convention.

## Recommendation: slash command + tiny shell helper

Single **slash command** that orchestrates an LLM pass. Reject Stop-hook auto-trigger for v1. Reject dedicated skill for v1.

**Why slash command**
- Explicit, on-demand, non-surprising — matches `/improve`, `/nudge`, `/status`.
- Work is investor-facing (destructive memory re-org); manual invocation is right.
- Can emit dry-run diff then act.

**Why not Stop hook**
- Fires unpredictably, often mid-task; hostile to a several-minute confirmed edit.
- Existing `check-stop.sh` is the only Stop hook; adding another would be surprising.
- Can add opt-in nagging later (threshold-based systemMessage) — doesn't modify files.

**Why not standalone skill**
- Skills are for disclosed knowledge consumed by multiple commands/agents. This is single user-invoked action. Command is correct primitive.

**Tiny shell helper**
- Command delegates to `scripts/learnings-migrate.sh`: (a) locate git root, (b) extract unsorted section, (c) enumerate topic files with H1 + first-paragraph descriptions, (d) emit structured brief for LLM. Bash is deterministic; matches `commands/status.md` → `scripts/status.sh` pattern.

## Classification Algorithm

Helper emits to the LLM:
```
CLAUDE_MD_PATH: /abs/path/to/CLAUDE.md
UNSORTED_SECTION_HEADING: "## Learnings"  (or "### Recent (unsorted)")
UNSORTED_ENTRIES:
  [1] - ALWAYS pair any logger.error/...
  [2] - NEVER gate a UI element visibility on condition X while...
  ...
TOPIC_FILES:
  docs/learnings/<file1>.md — "<H1>: <first-paragraph>"
  docs/learnings/<file2>.md — "<H1>: <first-paragraph>"
  ...
```

Helper derives each topic-file description from **H1 title + first non-empty prose line** (strongly stronger than filename matching; avoids requiring a user-maintained YAML index). Topic files lacking first-paragraph description still contribute H1 — good enough.

**Rejected alternatives**
- Filename-only matching — too brittle.
- User-maintained `.startup/learnings-topics.yml` — extra setup; drifts from reality.
- Reading entire topic files — expensive; first paragraph is enough in > 95% cases.

**LLM decision rules** (embedded in command prompt)
1. For each unsorted entry, pick: existing topic file, `NEW_TOPIC:<slug>`, or `KEEP_UNSORTED`.
2. Confidence threshold: if best match weak, prefer `KEEP_UNSORTED`.
3. Preserve verbatim wording — no paraphrasing/summarising.
4. Deduplicate: if semantically present in target file, mark `DUPLICATE:<filename>`, drop.
5. Group `NEW_TOPIC` proposals: require 3+ converging entries before creating new topic (unless clearly new domain, with investor confirmation).

## Safety Model

Three-phase execution:

**Phase 1 — Plan (always runs, no writes)**
- Helper extracts unsorted section + topic files.
- LLM produces plan as structured markdown: table with columns `#`, `target`, `action`, `entry-preview (50 chars)`.
- Investor sees: counts per topic, any `NEW_TOPIC:` proposals with triggering entries, `DUPLICATE:` drops, `KEEP_UNSORTED:` rationales.

**Phase 2 — Confirm**
- Single prompt: "Apply N moves, create M new topic files, drop K duplicates? (y/n)". No per-entry confirmations — plan already listed them.
- Any `NEW_TOPIC:` below 3-entry threshold surfaced separately: "Proceed anyway / keep unsorted".

**Phase 3 — Apply**
- For each move: append entry verbatim to target (create file with H1 + description if `NEW_TOPIC`), remove exact line from `CLAUDE.md`.
- Line-anchored `Edit` operations (each bullet is unique full line).
- Summary line: `Migrated N entries → {file1: 4, file2: 3, ...}. Kept M unsorted. Created K new topic files.`
- **Do not commit.** Leave as working-tree modifications; investor reviews with `git diff` and commits themselves.

**Dry-run flag** — `/learnings-migrate --dry-run` skips Phase 2+3.

## Edge Cases

1. **Section heading discovery** — try `### Recent (unsorted)` first, then `## Learnings`. If both exist, prefer `### Recent (unsorted)` (intended migration queue).
2. **No `docs/learnings/`** — first-run bootstrap. Print: "No topic structure found. Propose initial split from N unsorted entries? (y/n)". If yes, LLM clusters entries into 3–6 topic proposals with suggested filenames; investor approves; tool creates skeleton + migrates.
3. **No unsorted entries** — "Nothing to migrate"; exit 0.
4. **Git root vs CWD** — always `git rev-parse --show-toplevel`.
5. **Project without CLAUDE.md** — error: "CLAUDE.md not found — run `/startup` first."
6. **Multi-line bullets** — helper assumes bullets are single lines (`^- `). Multi-line handled up to next `^- ` or blank line.
7. **Concurrent edits** — if `auto-learn.sh` fires mid-migration, new bullets appended to `## Learnings` survive untouched (snapshot literal text in Phase 1; delete only matching literal lines in Phase 3).
8. **Topic files missing first-paragraph description** — fall back to H1 only; warn once.
9. **Unicode/diacritics** — UTF-8 throughout; avoid `iconv` transforms.
10. **Non-generic / multi-topic entry** — LLM marks `KEEP_UNSORTED` with reason "spans X and Y; split before migrating"; investor decides.

## Generic vs Project-Specific

The plugin:
- Discovers topics from `docs/learnings/*.md` at runtime.
- Uses topic file's H1 + first paragraph as classifier context.
- Falls back to first-run bootstrap when no topic structure.
- Supports arbitrary new-topic proposals (not a fixed list).

A fresh `/startup` project has CLAUDE.md with `## Learnings` section and no `docs/learnings/`. After N learnings accumulate, investor runs `/learnings-migrate` → bootstrap flow → produces their own domain-specific split. **Zero hardcoding.**

## Files to Create / Modify

**Create (new)**
- `plugins/saas-startup-team/commands/learnings-migrate.md` — slash command entry.
- `plugins/saas-startup-team/scripts/learnings-migrate.sh` — deterministic helper.

**Modify**
- `plugins/saas-startup-team/commands/startup.md` — mention `/learnings-migrate` as migration path (one sentence).
- `plugins/saas-startup-team/README.md` — add to commands table.
- `plugins/saas-startup-team/tests/run-tests.sh` — add structural + fixture tests (command exists with required frontmatter, helper script exists and is executable, idempotent on CLAUDE.md with no unsorted section).

**Do NOT modify**
- `plugins/saas-startup-team/scripts/auto-learn.sh` — capture pipeline unchanged.
- `plugins/saas-startup-team/hooks/hooks.json` — no new hooks.
- `plugins/saas-startup-team/settings.json` — no new config keys.

## Step-by-Step Implementation Order

1. Write `scripts/learnings-migrate.sh`. Deterministic core — git root, section detection (both heading variants), bullet extraction, topic enumeration. Test manually against a real project (should print its unsorted bullets and topic entries).
2. Write `commands/learnings-migrate.md` — frontmatter + procedure that runs helper, feeds output to LLM with classification prompt, renders plan, confirms, applies via Edit.
3. Add `--dry-run` pathway — skips Phase 2+3.
4. Add bootstrap pathway — "no `docs/learnings/`" branch (cluster + create skeleton files).
5. Update `commands/startup.md` Step 2b to mention migration command once.
6. Update `README.md`.
7. Update `tests/run-tests.sh`. Synthetic fixture: 5 unsorted entries + 3 topic files → assert expected brief structure.
8. Smoke test against a real project in `--dry-run` — verify classifications look sane before enabling writes.
9. PR note referencing #14.

## Open Questions

1. **If both `### Recent (unsorted)` and `## Learnings` exist** — which drains first? Proposal: `### Recent (unsorted)` wins.
2. **Auto-commit or leave in working tree?** Proposal: leave uncommitted; investor reviews via `git diff`.
3. **Stop-hook nag follow-up** — after v1 ships, add hook that counts unsorted entries and emits systemMessage when threshold exceeded. Out of scope for v1.
4. **New-topic description source** — LLM drafts; investor edits in git diff before committing.
5. **Cross-project portability** — if project uses `* ` or numbered lists, broaden regex. Not needed for v1.

## Critical Files for Implementation

- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/learnings-migrate.md` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/learnings-migrate.sh` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/auto-learn.sh` (reference)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/startup.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/tests/run-tests.sh`
