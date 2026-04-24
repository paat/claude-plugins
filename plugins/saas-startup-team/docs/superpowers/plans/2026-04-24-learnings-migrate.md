# Learnings Auto-Routing + Migrate Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `auto-learn.sh` PostToolUse hook route new learnings directly to `docs/learnings/*.md` topic files when it can classify confidently, with a `/saas-startup-team:learnings-migrate` command to sweep the fallback `### Recent (unsorted)` bucket into topic files on demand.

**Architecture:** Two files change. (1) `scripts/auto-learn.sh` — only the `systemMessage` heredoc body is replaced; the bash filter, exit codes, and file-path regex are unchanged. (2) `commands/learnings-migrate.md` — new pure-prompt command (no shell script), uses Read/Edit tools to apply migrations. Plus a version bump in `plugin.json` + root `marketplace.json`.

**Tech Stack:** Bash 4+, jq (for hook), Claude Code Skill/Command frontmatter, markdown prompt files.

**Spec reference:** `plugins/saas-startup-team/docs/superpowers/specs/2026-04-24-learnings-migrate.md`

---

### Task 1: Update `auto-learn.sh` hook prompt to auto-route

**Files:**
- Modify: `plugins/saas-startup-team/scripts/auto-learn.sh` (only the heredoc body between `<<'MSG'` and `MSG`)

The bash filter (path regex, `set -euo pipefail`, `jq` extraction, `exit 2`) stays exactly as-is. Only the `systemMessage` JSON body changes.

- [ ] **Step 1: Open the hook and replace the heredoc body**

Replace this block:

```bash
cat >&2 <<'MSG'
{"systemMessage": "Read the file just written. Extract up to 3 reusable project learnings (tech stack decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge. Read CLAUDE.md at git root. If missing, create with '# Project Learnings' header and '## Learnings' section. If exists but lacks '## Learnings', append it. Skip entries semantically equivalent to existing ones. Append new entries under '## Learnings' — one dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries. If nothing worth recording, do nothing."}
MSG
```

With this:

```bash
cat >&2 <<'MSG'
{"systemMessage": "Read the file just written. Extract up to 3 reusable project learnings (tech stack decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge. Find git root (git rev-parse --show-toplevel). Ensure CLAUDE.md exists with '# Project Learnings' H1 and '## Learnings' H2. List files in docs/learnings/*.md at git root (skip if dir missing); for each, read the first '#'/'##' heading line (fall back to filename stem with dashes→spaces if no heading) to build a topic catalog. For each candidate learning: (a) skip if semantically equivalent to any existing entry in any topic file or in '### Recent (unsorted)'; (b) if it clearly fits one existing topic file, append a dash-bullet to that file; (c) otherwise ensure '### Recent (unsorted)' subsection exists under '## Learnings' with comment '<!-- Uncertain/new-topic learnings staged here. Run /saas-startup-team:learnings-migrate to organise into docs/learnings/*.md. -->' and append the dash-bullet there. One dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries total. If nothing worth recording, do nothing."}
MSG
```

Use the Edit tool — replace the whole `cat >&2 <<'MSG' ... MSG` block in place.

- [ ] **Step 2: Syntax-check the updated script**

Run: `bash -n plugins/saas-startup-team/scripts/auto-learn.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Run the plugin test suite to confirm no regressions**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | tail -20`
Expected: all tests pass. Specifically check that I6 (`auto-learn.sh references Learnings section`) and I7 (`auto-learn.sh contains duplicate-skip instruction`) both PASS — these assert presence of the strings `## Learnings` and `semantically equivalent`, both of which are preserved in the new message.

If any test fails, read the failure and fix before continuing.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/scripts/auto-learn.sh
git commit -m "feat(saas-startup-team): auto-learn routes learnings to docs/learnings/ topic files

Hook now reads docs/learnings/*.md catalog and appends new entries
directly to the matching topic file. Uncertain or new-topic entries
fall back to '### Recent (unsorted)' in CLAUDE.md for manual curation
via /learnings-migrate.

Refs #14"
```

---

### Task 2: Create the `/learnings-migrate` command

**Files:**
- Create: `plugins/saas-startup-team/commands/learnings-migrate.md`

- [ ] **Step 1: Create the command file**

Write `plugins/saas-startup-team/commands/learnings-migrate.md` with this exact content:

```markdown
---
name: learnings-migrate
description: Organise learnings staged in '### Recent (unsorted)' of CLAUDE.md into topic files under docs/learnings/. Bootstraps the topic catalog on first use. Non-destructive — flat pre-existing '## Learnings' bullets outside Recent are left alone.
user_invocable: true
---

# /learnings-migrate — Sweep staged learnings into topic files

The `auto-learn.sh` PostToolUse hook normally routes new learnings directly into `docs/learnings/<topic>.md`. When it can't classify confidently, or when the topic catalog is empty, entries are staged in `### Recent (unsorted)` inside CLAUDE.md. This command sweeps Recent into topic files with human-in-the-loop review.

## Actions

1. Resolve git root:

   ```bash
   git rev-parse --show-toplevel
   ```

2. Read `CLAUDE.md` at git root. Locate `### Recent (unsorted)` subsection under `## Learnings` and extract dash-bullet entries (lines matching `^- `). If the section is missing or empty, print `Nothing to migrate.` and stop.

3. Check whether `docs/learnings/` exists at git root.
   - If the directory does not exist, ask the user: "Create `docs/learnings/`? (y/N)". On `y`, `mkdir -p docs/learnings`. On anything else, exit with no changes — Recent stays put.

4. Build the topic catalog: for each `docs/learnings/*.md` file, extract the first heading line matching `^#{1,2} ` (H1 or H2) and strip the leading hashes/space. If no heading exists, fall back to the filename stem with dashes replaced by spaces (e.g. `xbrl-taxonomy.md` → `xbrl taxonomy`). Store as `(path, display_name)` pairs.

5. **First-time bootstrap** — only if the topic catalog is empty after step 4:
   - Cluster the Recent entries by theme (use your own reasoning). Each cluster becomes a candidate topic.
   - For each cluster, propose a kebab-case filename (e.g. `estonian-compliance.md`) and a display heading. Ask the user, one cluster at a time: `Cluster "<display heading>": create docs/learnings/<filename>? (y/rename/skip)`. On `rename`, prompt for a new filename. On `skip`, drop the cluster (entries stay in Recent).
   - After confirmations, create each confirmed topic file with a `# <display heading>` H1 and a blank line underneath.
   - If the user declined or skipped every cluster, exit with no changes.
   - Rebuild the topic catalog.

6. Classify each Recent entry against the catalog. Assign each entry to one of three buckets:
   - **Match** — high-confidence route to an existing topic file.
   - **New topic** — no existing topic fits; suggest a new topic name.
   - **Uncertain** — two or more topics could plausibly fit, or the entry is too generic.

7. Resolve non-match entries interactively, one entry at a time. For each **Uncertain** entry, show the entry and the top 2-3 candidate topics and ask the user to pick one, skip, or create a new topic. For each **New topic** entry, show the entry and the suggested topic name and ask `y/rename/pick existing/skip`.

8. Semantic dedup: for every resolved `(entry, target_file)` pair, compare the entry against all existing dash-bullet lines in *all* topic files and against other entries being migrated in this run. If semantically equivalent to any, drop the entry from the plan and mark it as a duplicate (it will still be removed from Recent).

9. Print a preview grouped by target file. Example:

   ```
   Preview:
     docs/learnings/xbrl-taxonomy.md ← 3 entries
     docs/learnings/business-marketing.md ← 2 entries
     docs/learnings/estonian-compliance.md (NEW FILE) ← 1 entry
     Duplicates (will be removed from Recent, not appended): 1 entry
     Skipped (remain in Recent): 2 entries
   ```

   Followed by the actual entry texts under each target.

10. Ask the user: `apply / skip: <row numbers> / cancel`. On `cancel`, exit with no changes. On `skip: 3,7`, mark those rows to remain in Recent and re-show the preview. On `apply`, proceed.

11. Apply edits:
    - For each target file, append the planned entries as dash-bullets (one per line) at the end of the file. Create the file with a `# <heading>` H1 if it was a new topic.
    - Rewrite CLAUDE.md: keep the `### Recent (unsorted)` subsection and its comment, but remove every migrated or deduplicated entry. Skipped entries stay.

12. Print summary: `Migrated N entries into M files. K skipped. J new topics created. D duplicates dropped.`

## Guarantees

- **Non-destructive.** Only `### Recent (unsorted)` is swept. Flat pre-existing `## Learnings` bullets outside Recent are left alone.
- **Append-only on topic files.** Existing content is never modified or reordered.
- **Semantic dedup across all topic files** — not just the target — so the same entry can't land in two topics.
- **No silent `misc.md` fallback.** Entries the user skips stay in Recent until the next migrate run.
- **Interruptible.** If the user cancels or the session dies before step 11, nothing is changed.
```

- [ ] **Step 2: Confirm the file is well-formed**

Run: `head -5 plugins/saas-startup-team/commands/learnings-migrate.md`
Expected: YAML frontmatter with `name: learnings-migrate`.

- [ ] **Step 3: Run the plugin test suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | tail -10`
Expected: all tests still pass. (The test suite may or may not enumerate commands; either way, adding a new command must not break existing checks.)

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/commands/learnings-migrate.md
git commit -m "feat(saas-startup-team): add /learnings-migrate command

Sweeps '### Recent (unsorted)' entries from CLAUDE.md into topic files
under docs/learnings/. Bootstraps the catalog on first use by
clustering entries into proposed topics. Human-in-the-loop preview
and semantic dedup across all topic files.

Refs #14"
```

---

### Task 3: Bump plugin version

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

Per repo rule: both must be bumped together (pre-push hook enforces this).

- [ ] **Step 1: Bump plugin.json**

In `plugins/saas-startup-team/.claude-plugin/plugin.json`, change:

```json
"version": "0.30.1",
```

To:

```json
"version": "0.31.0",
```

- [ ] **Step 2: Bump marketplace.json**

In `.claude-plugin/marketplace.json` (repo root), find the `saas-startup-team` entry (around line 65) and change its `"version": "0.30.1"` to `"version": "0.31.0"`.

- [ ] **Step 3: Verify both files have the same version**

Run: `grep -A1 '"saas-startup-team"' .claude-plugin/marketplace.json | grep version && grep '"version"' plugins/saas-startup-team/.claude-plugin/plugin.json`
Expected: both print `"version": "0.31.0"`.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(saas-startup-team): v0.31.0 — auto-route learnings + /learnings-migrate (#14)"
```

---

### Task 4: Close out

- [ ] **Step 1: Final test sweep**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: all tests pass.

- [ ] **Step 2: Show the commits**

Run: `git log --oneline -5`
Expected: three new commits on top (hook update, command, version bump) plus the earlier spec commit.

- [ ] **Step 3: Push**

```bash
git push
```

The pre-push hook verifies plugin version sync; expect it to pass since Task 3 kept both files aligned.

- [ ] **Step 4: Close the issue**

Run:

```bash
gh issue close 14 --comment "Implemented via auto-routing in the hook + /learnings-migrate command. See commits on main."
```

Expected: issue closed.
