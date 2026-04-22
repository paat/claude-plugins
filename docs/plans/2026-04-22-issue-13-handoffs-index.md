# Plan: shard or index handoffs/ (issue #13)

> **Universality rule:** Pure infrastructure. INDEX.md schema and parsing cascade are domain-agnostic. No project-specific strings enter the plugin.

## Goal & Scope

Make `.startup/handoffs/` navigable at 495+ files without breaking the 20+ scripts/agents/templates that assume a flat `.startup/handoffs/NNN-direction.md` layout. "Navigable" = agent or human finds a specific handoff in < 5 seconds without `ls | wc -l` or reading every file.

Scope limited to handoffs. Sibling `.startup/signoffs/`, `.startup/reviews/`, `.startup/improvements/` not addressed (can adopt same pattern later).

## Recommendation: Option B (generated INDEX.md)

Reasons found during exploration:

1. **Option A breaks ~15 glob sites.** `grep -rn 'handoffs/\*\.md' plugins/saas-startup-team/` shows `status.sh`, `check-idle.sh`, `check-task-complete.sh`, `check-stop.sh`, `auto-commit.sh`, plus 10+ tests all doing `for f in "$STARTUP_DIR/handoffs/"*.md`. Sharding means every one of these needs `**` globs or `find`, plus migration, plus agent prompts. Cost is high; `ls` is already broken at 495 files.
2. **Numbering is monotonic-increasing and directions are enumerable** — ideal for a single-line-per-file index.
3. **Issue #12 eliminates the other driver** — once state.json stops being the de-facto index, INDEX.md suffices.
4. **Incremental cost.** Option B = ~1 day. Option A = ~1 week.

Do **not** do both. Keep surface area small.

## INDEX.md Format Spec

Path: `.startup/handoffs/INDEX.md`.

Format: markdown table. One row per handoff file. Sorted numerically by `N` ascending.

```markdown
# Handoffs Index

Generated: 2026-04-22T14:30:00Z
Total: 495

| N   | direction         | date       | iteration | signoff | scope                                              | file                                   |
|-----|-------------------|------------|-----------|---------|----------------------------------------------------|----------------------------------------|
| 001 | business-to-tech  | 2026-02-25 | 1         | -       | Initial product brief — core feature implementation| 001-business-to-tech.md                |
| 002 | tech-to-business  | 2026-02-26 | 1         | -       | Scaffold, first pass                                | 002-tech-to-business.md                |
| 133 | roundtrip-signoff | 2026-03-03 | -         | APPROVED| Feature X acceptance                                | 133-roundtrip-signoff.md               |
| --- | adhoc             | 2026-04-03 | -         | -       | UX audit findings                                   | ux-audit.md                            |
```

### Column semantics (parseable)

| Column | Source | Rules |
|---|---|---|
| `N` | leading 3-digit number from filename | `000`–`999`; `---` for ad-hoc (unnumbered) |
| `direction` | `sed 's/^[0-9]*-//;s/\.md$//'` | Known: `business-to-tech`, `tech-to-business`, `business-to-growth`, `growth-to-business`, `roundtrip-signoff`, `signoff`, `qa-review`, `ux-audit-to-*`, plus suffix variants. Fallback: `adhoc`. |
| `date` | frontmatter `date:` → first `**Date:**` → file mtime | ISO date only |
| `iteration` | frontmatter `iteration:` | integer or `-` |
| `signoff` | frontmatter `status:` → scan first 30 lines for `APPROVED`/`REJECTED`/`PENDING` | `APPROVED` \| `REJECTED` \| `PENDING` \| `-` |
| `scope` | frontmatter `scope:` → H1 `# ...` → first line of `## Summary` → filename suffix | stripped of newlines, truncated to 60 chars |
| `file` | basename | exact |

**Why markdown table, not JSON/YAML:** primary consumers are Claude agents. Markdown is cheap to render, grep-friendly, diffs nicely. Bash parsing straightforward (`awk -F'|'`).

## Generation / Update Algorithm

**Two scripts, two call sites.**

**A. `scripts/update-handoffs-index.sh`** — incremental, PostToolUse hook on `Write` matching `.startup/handoffs/.*\.md$` (excluding `INDEX.md` itself).
```
parse written file_path
if basename == INDEX.md: exit 0
extract row from file
read existing INDEX.md (skip header)
replace row where file column matches basename, or insert-sorted by N
atomically rewrite INDEX.md
update Total / Generated header
```
Cost: ~50ms per write.

**B. `scripts/rebuild-handoffs-index.sh`** — full rebuild from scratch. Called manually for backfill / self-heal (if INDEX.md missing or row count disagrees with `ls | wc -l`).
```
for f in handoffs/*.md (excluding INDEX.md):
  extract row
write header + sorted rows → INDEX.md atomically
```

### Why not full-rebuild on every write

495 files × frontmatter parsing ≈ 0.5–2s. Stacked with other Write hooks (auto-learn, auto-commit, check-handoff-secrets, enforce-tone, check-duplicate-handoff) this adds up. Incremental is ~50ms.

### Hook failure handling

Incremental script exits 0 on any parse error, logs to `.startup/.index-errors.log` rather than blocking the write. `status.sh` can trigger full rebuild if log non-empty.

## Backfill Procedure

`rebuild-handoffs-index.sh` against existing project. Pseudocode:
```bash
#!/bin/bash
set -euo pipefail
HANDOFF_DIR="$(git rev-parse --show-toplevel)/.startup/handoffs"
INDEX="$HANDOFF_DIR/INDEX.md"
TMP=$(mktemp)

extract_row() {
  local f="$1" base N direction
  base=$(basename "$f")
  if [[ "$base" =~ ^([0-9]{3})-(.+)\.md$ ]]; then
    N="${BASH_REMATCH[1]}"; direction="${BASH_REMATCH[2]}"
  else
    N="---"; direction="adhoc"
  fi
  # frontmatter block between first two ---
  fm=$(awk '/^---$/{c++;next} c==1{print} c==2{exit}' "$f")
  date=$(echo "$fm"    | awk -F': *' '/^date:/{print $2; exit}')
  iter=$(echo "$fm"    | awk -F': *' '/^iteration:/{print $2; exit}')
  signoff=$(echo "$fm" | awk -F': *' '/^status:/{print $2; exit}')
  scope=$(echo "$fm"   | awk -F': *' '/^scope:/{sub(/^scope: */,""); print; exit}')
  # fallbacks
  [ -z "$date" ] && date=$(awk -F'[* ]+' '/^\*\*Date:\*\*/{print $3; exit}' "$f")
  [ -z "$date" ] && date=$(stat -c %y "$f" | cut -d' ' -f1)
  [ -z "$iter" ] && iter="-"
  [ -z "$signoff" ] && signoff=$(grep -m1 -oE 'APPROVED|REJECTED|PENDING' "$f")
  [ -z "$signoff" ] && signoff="-"
  [ -z "$scope" ] && scope=$(awk '/^# /{sub(/^# /,""); print; exit}' "$f")
  [ -z "$scope" ] && scope=$(awk '/^## Summary$/{flag=1;next} flag && NF{print; exit}' "$f")
  [ -z "$scope" ] && scope="(no scope extracted)"
  scope=$(echo "$scope" | tr -d '|' | tr -s ' ' | cut -c1-60)
  printf '| %-3s | %-17s | %-10s | %-9s | %-7s | %-57s | %s |\n' \
    "$N" "$direction" "$date" "$iter" "$signoff" "$scope" "$base"
}
```

Runtime estimate for 495 files: 10–15s on local disk. Fine for one-off backfill, too slow for per-write.

### Edge cases

- Missing N gaps (e.g. `022` absent) — skip, don't synthesise.
- Duplicate N with different directions — both rows kept.
- Subdirectories under handoffs (e.g. `NNN-artifacts/`) — `*.md` glob skips cleanly. Preamble note: "Subdirectories are not indexed."
- Timestamped filenames without leading N (e.g. `YYYY-MM-DDTHHMMSSZ-direction-*.md`) — `N=---`, direction still parsed.
- Pure ad-hoc files (e.g. `ux-audit.md`) — `N=---`, direction=`adhoc`. Date from fallback chain.

## Script Updates (move from globbing to reading INDEX.md)

Should switch:
1. `status.sh` — handoff listing + `HIGHEST_HANDOFF`.
2. `check-task-complete.sh` — `HIGHEST_HANDOFF`.
3. `check-idle.sh` — per-direction highest + total.
4. `check-stop.sh` — `HANDOFF_COUNT` from `Total:` header.
5. Agent prompts (`tech-founder.md`, `business-founder.md`, `growth-hacker.md`, `lawyer.md`) — add "Read `.startup/handoffs/INDEX.md` first — do not `ls` the directory".

Should NOT change (operate on a specific file, no glob):
- `auto-commit.sh`, `check-duplicate-handoff.sh` (globs by number prefix, cheap), `check-handoff-secrets.sh`, `enforce-tone.sh`, `validate-growth-brief.sh`.
- `auto-learn.sh` — must be updated to **exclude INDEX.md** to prevent self-referential learning loop.

Tests: ~15 sites create test handoff files and glob. Fine; performance not an issue in fresh workdirs.

## Shared Helper

`scripts/_lib/read-index.sh` (or inline functions). Exposes:
- `index_highest_n [direction_filter]`
- `index_total`
- `index_rows_by_direction <pattern>`
- `index_exists`

Each function: if INDEX.md missing/stale, fall back to globbing — missing index never breaks plugin.

## Ad-Hoc Files Handling

Include with `N=---`, `direction=adhoc`. Sort to end (since `---` sorts after `999`). Don't rename — out of scope, breaks git history.

Exception: `INDEX.md` itself is skipped (hard-coded).

## Files to Create / Modify

### Create
- `plugins/saas-startup-team/scripts/update-handoffs-index.sh`
- `plugins/saas-startup-team/scripts/rebuild-handoffs-index.sh`
- `plugins/saas-startup-team/scripts/_lib/read-index.sh`
- `plugins/saas-startup-team/templates/handoffs-INDEX.md`

### Modify
- `plugins/saas-startup-team/hooks/hooks.json` — add PostToolUse Write entry.
- `plugins/saas-startup-team/scripts/status.sh` — read INDEX.md with fallback.
- `plugins/saas-startup-team/scripts/check-task-complete.sh` — same.
- `plugins/saas-startup-team/scripts/check-idle.sh` — same.
- `plugins/saas-startup-team/scripts/check-stop.sh` — same.
- `plugins/saas-startup-team/scripts/auto-learn.sh` — exclude INDEX.md.
- `plugins/saas-startup-team/agents/{tech-founder,business-founder,growth-hacker,lawyer}.md` — add "read INDEX.md first".
- `plugins/saas-startup-team/commands/startup.md` — document INDEX.md; run rebuild script once if pre-existing handoffs detected.
- `plugins/saas-startup-team/commands/status.md` — document.
- `plugins/saas-startup-team/skills/startup-orchestration/references/handoff-protocol.md` — document format.
- `plugins/saas-startup-team/templates/handoff-{business-to-tech,tech-to-business,business-to-growth,growth-to-business}.md` — add optional `scope:` frontmatter field.
- `plugins/saas-startup-team/README.md` — update directory structure.
- `plugins/saas-startup-team/tests/run-tests.sh` — add rebuild, incremental, exclusion, fallback tests.

## Step-by-Step Implementation Order

1. Add `scope:` field to 4 handoff templates. Zero-risk; unblocks reliable extraction.
2. Write `rebuild-handoffs-index.sh`. Test against fixture (or a local copy of a large project's handoffs dir).
3. Write `update-handoffs-index.sh`. Unit-test with hook-style stdin JSON.
4. Wire in `hooks.json`. Ensure ordering: update-index BEFORE auto-commit (so commit includes index change).
5. Update `auto-learn.sh` to exclude INDEX.md.
6. Update `status.sh`, `check-task-complete.sh`, `check-idle.sh`, `check-stop.sh` with graceful fallback.
7. Update agent prompts.
8. Update `handoff-protocol.md`, `README.md`, startup.md, status.md.
9. Extend `tests/run-tests.sh`.
10. Update `startup.md` to run rebuild once at init (detects pre-existing handoffs).
11. Document migration: "run `${CLAUDE_PLUGIN_ROOT}/scripts/rebuild-handoffs-index.sh` once after upgrading."

## Trade-offs

- Bash parsing fragile vs Python/jq. Chose bash (no new runtime dep). Accept ~5% imperfect scope extraction; users can edit INDEX.md or add `scope:` frontmatter.
- `.startup/handoffs/` is gitignored → INDEX.md is ephemeral, lost on fresh clone. OK: rebuild in 10–15s. Optional: git-track via `.gitignore` whitelist (`!INDEX.md`) — worth considering.
- Row-level atomicity: rewrite whole file; concurrent hooks could race. Mitigation: `flock` on `/tmp/handoffs-index.lock`. Low practical risk.

## Open Questions

1. Git-track INDEX.md? Adds diffability; recommend yes, whitelist in `.gitignore`.
2. Include signoffs/reviews/improvements/? Not this issue; file follow-up if same pain emerges.
3. Team lead reads INDEX.md at session start? Probably yes via SessionStart hook; outside this issue.
4. Retention at 2000+ rows: auto-archive old rows to `INDEX-archive-YYYY.md`. Future issue.
5. Format evolution: include schema-version marker (`<!-- index-schema: 1 -->`) for future parsers.

## Critical Files for Implementation

- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/hooks/hooks.json`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/status.sh`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/auto-learn.sh`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/skills/startup-orchestration/references/handoff-protocol.md`
