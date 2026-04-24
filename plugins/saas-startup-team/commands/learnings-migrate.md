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
