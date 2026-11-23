# Handoff Naming Enforcement — Design

**Issue:** [#21 — saas-startup-team: enforce single handoff filename convention](https://github.com/paat/claude-plugins/issues/21)
**Date:** 2026-04-24
**Target version:** `saas-startup-team` 0.33.0

## Problem

`.startup/handoffs/` in long-running projects accumulates files under three coexisting naming schemes plus orphan roles and binaries. On the reference project (aruannik, 586 files), 135+ files do not match the canonical `NNN-<direction>.md` format documented in `handoff-protocol.md`. Non-conforming files silently bypass every downstream script:

- `check-duplicate-handoff.sh` regex-matches only canonical names — duplicate detection skipped
- `auto-commit.sh` only auto-commits canonical handoffs — non-conforming writes fall through
- `status.sh` derives highest-handoff from canonical names only — count understated
- `index-handoff.sh` indexes non-canonical files with `---` prefix — defeats numeric sort

The documented convention is not enforced; drift has already happened and continues.

## Scope (chosen approach: A + B from issue)

1. **One-time migration script** to clean up existing non-conforming files per project.
2. **PreToolUse hook** to block non-conforming Writes going forward.

Explicitly **out of scope**:

- No updates to `check-duplicate-handoff.sh`, `auto-commit.sh`, `status.sh`, `index-handoff.sh`. After migration + enforcement, they operate on a clean canonical set; existing fallbacks cover any residual legacy files.
- No widening of the canonical 4-direction set. Organic roles (`investor-to-tech`, `business-to-team`, `tribunal-to-tech`, `ux-audit-*`) are handled by routing to `.startup/reviews/` or flagging for manual review, not by expanding the whitelist.
- No changes to `/improve` or agent system prompts. The hook's error message is the teaching mechanism.

## Canonical format (unchanged)

```
^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$
```

Plus `INDEX.md` (auto-generated).

## Architecture

Two independent additions, no changes to existing scripts:

- `scripts/enforce-handoff-naming.sh` — new PreToolUse hook
- `scripts/migrate-handoff-names.sh` — new standalone script (not a hook; run manually per project)

Plus wiring:

- `hooks/hooks.json` — one new PreToolUse entry
- `skills/startup-orchestration/references/handoff-protocol.md` — short "Enforcement" section

## Component 1 — `enforce-handoff-naming.sh`

**Event:** `PreToolUse`
**Matcher:** `Write` (not Edit — legacy files must remain editable for maintenance)
**Exit codes:**
- `0` — not a handoff path, or filename is valid
- `2` — blocked; systemMessage on stderr

### Algorithm

```
input = stdin JSON
file_path = tool_input.file_path
if file_path not under .startup/handoffs/: exit 0
filename = basename(file_path)
if filename == "INDEX.md": exit 0
if filename matches canonical regex: exit 0

# Block with helpful message
handoff_dir = dirname(file_path)
max_nnn = max of `^[0-9]{3}-` prefixes in handoff_dir (0 if none)
next_nnn = printf '%03d' $((max_nnn + 1))
systemMessage = "Handoff filename '<name>' is not valid. Handoffs must be named
  NNN-<direction>.md where NNN is a zero-padded 3-digit number and <direction>
  is one of: business-to-tech, tech-to-business, business-to-growth,
  growth-to-business. Next available NNN: <next_nnn>. Binaries belong in
  .startup/attachments/; signoffs in .startup/signoffs/; reviews in
  .startup/reviews/."
exit 2
```

### Why these design choices

- **Write-only matcher:** Editing an existing legacy file (e.g., to correct frontmatter during migration) must not be blocked. Only net-new files need conformance.
- **Computed `next_nnn` in the error:** Agents retry blocked Writes in their agent loop. Handing them the next valid NNN eliminates guesswork; prior hook patterns (`auto-commit.sh`, `check-duplicate-handoff.sh`) use the same pattern.
- **PreToolUse, not PostToolUse:** Blocking is the goal; PostToolUse can't prevent the write.
- **Routing hints in the message:** Most observed drift is misrouted content (signoffs/reviews/binaries landing in handoffs/). The error names the correct destination so the agent self-corrects.

## Component 2 — `migrate-handoff-names.sh`

**Invocation:** manual, per project. Dry-run by default; `--apply` performs the filesystem changes.

**Signature:**

```
bash scripts/migrate-handoff-names.sh                  # dry-run
bash scripts/migrate-handoff-names.sh --apply          # execute
bash scripts/migrate-handoff-names.sh --apply <dir>    # override handoffs dir
```

### Rule application (first match wins)

For each entry in `.startup/handoffs/`:

1. **Skip canonical:** `INDEX.md` or `^[0-9]{3}-<canonical-direction>\.md$` — no action.

2. **Move to `.startup/signoffs/`** — misplaced signoffs:
   - filename matches `*roundtrip-signoff*.md`
   - filename matches `*-signoff.md` (trailing)
   - keeps the original filename intact in the destination (preserves NNN prefix when present)

3. **Move to `.startup/reviews/`** — misplaced review artifacts:
   - `*-qa-review.md`, `*-qa-pass.md`
   - `*-business-review*.md`, `business-review-*.md`
   - `*-business-qa*.md`, `business-qa-*.md`
   - `*.lawyer.md` → rename to `lawyer-<basename-without-.lawyer.md>.md`
   - `*.QA-PASS.md` → rename to `qa-pass-<basename-without-.QA-PASS.md>.md`
   - `*-regression-tests-*.md`, `*-regression-results-*.md`
   - `*ux-audit*.md`, `*ux-fixes*.md`
   - `tribunal-*-to-tech*.md`, `*-tribunal-to-tech*.md`
   - `*-tech-review-fixes*.md`, `*-tech-fixes*.md`
   - `*-business-verification*.md`
   - keeps the original filename intact in the destination (preserves NNN prefix when present)

4. **Move to `.startup/attachments/`** — not a markdown handoff:
   - any non-`.md` file (e.g., `.pdf`, `.png`, `.xbrl`)
   - any directory
   - creates `.startup/attachments/` if missing

5. **Rename to canonical handoff** — infer direction, assign next-available NNN:
   - First try: frontmatter `from:` / `to:` pair that maps to one of the 4 canonical directions
   - Fallback: filename contains one of the 4 canonical-direction substrings (`business-to-tech`, `tech-to-business`, `business-to-growth`, `growth-to-business`)
   - NNN assignment: `max_existing_NNN + 1`, incrementing; input sorted by mtime ascending (oldest first) so chronology is preserved

6. **Manual review** — no rule matched:
   - `investor-to-business*`, `investor-to-tech*` (human-origin; non-canonical role)
   - `business-to-team*` (broadcast; no canonical equivalent)
   - anything else unclassified
   - left in place; listed in the dry-run output

### NNN collision handling

- Before renaming, compute `max_existing_NNN` from `ls .startup/handoffs/ | grep -oE '^[0-9]{3}'`.
- Sort files-to-rename by mtime ascending.
- Assign `max_existing_NNN + 1`, `max_existing_NNN + 2`, … sequentially.
- This guarantees no collision with existing canonical files and no collision between renamed files.
- Move operations (rules 2–4) do NOT draw from the NNN counter; they keep their original NNN prefix in the destination dir.

### Destination collision handling (for moves)

If a move would overwrite an existing file in the destination (rare — signoffs/ and reviews/ are sparsely populated):
- Append `-dup<timestamp>` suffix to preserve both
- Record in output

### Dry-run output format

```
=== Handoff migration plan for /path/.startup/handoffs/ ===

Skipping (already canonical): 451 files

Move to .startup/signoffs/ (N files):
  133-roundtrip-signoff.md → /path/.startup/signoffs/133-roundtrip-signoff.md
  228-signoff.md → /path/.startup/signoffs/228-signoff.md
  …

Move to .startup/reviews/ (N files):
  369-qa-review.md → /path/.startup/reviews/369-qa-review.md
  business-to-tech-satisfaction-guarantee.lawyer.md
    → /path/.startup/reviews/lawyer-business-to-tech-satisfaction-guarantee.md
  …

Move to .startup/attachments/ (N files):
  arve_fixed_logo_preview.pdf → /path/.startup/attachments/arve_fixed_logo_preview.pdf
  421-artifacts/ → /path/.startup/attachments/421-artifacts/
  …

Rename (N files, next NNN starts at XYZ):
  2026-04-16T074318Z-business-to-tech-improve-189.md → XYZ-business-to-tech.md
  business-to-tech-fix-invoice-logo-broken.md → XY(Z+1)-business-to-tech.md
  …

Manual review needed (N files, left in place):
  205-investor-to-business.md    (reason: non-canonical role 'investor')
  476-business-to-team.md        (reason: non-canonical recipient 'team')
  …

Summary: skip 451, move 70, rename 50, manual 15
Dry-run — re-run with --apply to perform changes.
```

### --apply behavior

- Performs all moves and renames using `mv`
- Re-runs `backfill-handoff-index.sh` at the end to regenerate `INDEX.md` with new names
- Prints the same section layout with `[DONE]` markers
- Exits non-zero only on hard errors; manual-review entries are not errors

## Component 3 — `hooks/hooks.json` wiring

Add one new block at the end of the existing hook list:

```json
"PreToolUse": [
  {
    "matcher": "Write",
    "hooks": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/scripts/enforce-handoff-naming.sh",
        "description": "Block non-conforming handoff filenames (NNN-<direction>.md only)"
      }
    ]
  }
]
```

Placed alongside existing hook arrays at the top level of `hooks.hooks`.

## Component 4 — `handoff-protocol.md` update

Append a new "Enforcement" section after the existing "File Naming Convention" section:

```markdown
### Enforcement

The canonical format is enforced by a PreToolUse hook (`enforce-handoff-naming.sh`).
Writes to `.startup/handoffs/` that don't match `NNN-<direction>.md` (with one of the
four canonical directions) are blocked with an error message that includes the next
available NNN.

Misrouted content:
- Signoffs go in `.startup/signoffs/`
- Review artifacts (QA, lawyer, UX audit, tribunal, regression) go in `.startup/reviews/`
- Binaries and directories go in `.startup/attachments/`

For legacy projects with pre-existing non-conforming files, run
`bash $CLAUDE_PLUGIN_ROOT/scripts/migrate-handoff-names.sh` (dry-run) then
`--apply` to clean up.
```

## Tests

Add to `tests/run-tests.sh`:

**Hook tests (`enforce-handoff-naming.sh`):**
- Pass: canonical `NNN-business-to-tech.md` → exit 0
- Pass: canonical `NNN-tech-to-business.md` → exit 0
- Pass: `INDEX.md` → exit 0
- Pass: path outside `.startup/handoffs/` → exit 0
- Block: slug-only `business-to-tech-foo.md` → exit 2, message contains next NNN
- Block: timestamp prefix → exit 2
- Block: `.pdf` file → exit 2, message mentions `.startup/attachments/`
- Block: non-canonical direction `NNN-business-to-team.md` → exit 2
- Block: in empty dir → next NNN = `001`

**Migration tests (`migrate-handoff-names.sh`):**
- Fixture directory with one file from each category
- Dry-run output contains each file in the expected section
- `--apply` on the fixture moves/renames correctly
- NNN assignment respects existing max and assigns sequentially
- Destination collision in signoffs/ gets `-dup<ts>` suffix
- Manual-review files are not touched

Fixtures live under `tests/fixtures/migrate-handoff-names/`.

## Aruannik validation plan

1. Apply the version bump and code changes on a branch.
2. Copy `scripts/migrate-handoff-names.sh` to aruannik temporarily or invoke via full path.
3. Dry-run against `/mnt/data/ai/est-biz-aruannik/.startup/handoffs/`.
4. Review the 6 sections — especially `manual review`.
5. Run `--apply` once output is approved.
6. Verify final state:
   - `ls .startup/handoffs/ | grep -vE '^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$|^INDEX\.md$'` prints only the manual-review residue
   - `INDEX.md` regenerated without `---` rows for moved/renamed files
   - `.startup/signoffs/`, `.startup/reviews/`, `.startup/attachments/` populated as expected
7. Touch-test the hook: attempt `Write .startup/handoffs/garbage.md` in a throwaway session; confirm the block message includes the correct next NNN.

## Version bump

- `plugins/saas-startup-team/.claude-plugin/plugin.json`: `0.32.0` → `0.33.0`
- root `.claude-plugin/marketplace.json` entry for `saas-startup-team`: `0.32.0` → `0.33.0`

Minor bump because this adds new functionality (hook + script) without breaking existing handoff consumers.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Migration renames break references in handoff contents that point to other handoffs by name | Low risk: canonical files are already canonically named; only slug→numbered transitions could break references, and no current agent workflow greps for slug filenames. Dry-run makes all renames visible before apply. |
| Hook blocks legitimate writes where the agent made a typo | Error message includes next valid NNN + direction list. Agent re-Writes with corrected name on next turn. |
| Downstream projects upgrade the plugin and get surprised by hook blocks on in-flight work | Hook matcher is `Write` only. Edits to existing files still pass. New writes get a clear actionable error, not a silent failure. |
| Migration mis-routes a file (e.g., folds a legitimate "tech-fixes" handoff into reviews/) | Dry-run first; `--apply` is deliberate. User reviews each section before committing. |
| Destination dir (`.startup/attachments/`) doesn't exist on target project | Migration creates it as needed. |
| NNN collision with a handoff written concurrently during migration | Migration is a manual, one-shot operation run in a quiet session. Not a multi-writer scenario. |

## Success criteria (from issue #21)

- [x] New handoffs land in exactly one filename format (hook enforces, not just docs)
- [x] Existing scripts handle every handoff without silent skips (after migration, everything is canonical)
- [x] No binaries in `.startup/handoffs/` (moved to `.startup/attachments/`)
