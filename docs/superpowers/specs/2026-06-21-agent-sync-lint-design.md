# agent-sync lint — design spec

**Issue:** #55 — agent-sync: add doc-drift + rules-file bloat linter
**Date:** 2026-06-21
**Status:** Approved design, ready for implementation plan
**Plugin:** `plugins/agent-sync` (version bump `0.2.2 → 0.3.0`)

## Problem

Rule/doc files drift from reality and from each other, and they grow past the point where
agents actually read them. Contradictory docs actively poison agent sessions.

- **Stack contradictions:** a README claims `Supabase`/`Vercel` while reality is `.NET`/`Postgres`/`Hetzner`. One doc says one thing, another says the opposite; an agent reading both gets poisoned context.
- **Rules-file bloat:** rules past ~200 lines become "context wallpaper" and are effectively ignored.
- **Soft directives:** `prefer X` preferences do not bind agents the way negative-constraint-with-path directives do.

`agent-sync` already owns the README/CLAUDE.md/AGENTS.md surface (it generates `AGENTS.md` from
`.claude/` config). This feature extends it with a deterministic, vendorable **lint** that catches
the three problems above.

## Constraints (inherited from agent-sync)

- **Deterministic bash.** bash 4+, `jq`, `awk`, `sed`. No LLM, no network.
- **Vendorable into CI without the plugin installed.** Same model as `generate.sh`: `/agent-sync:init`
  vendors the script into the repo; CI runs the repo-local copy.
- **Backward compatible.** A `sources.json` with no `lint` key produces no lint output and exits 0.

## Architecture

A new standalone script **`scripts/lint.sh`**, sibling to `scripts/generate.sh`, with the same CLI
conventions:

```
lint.sh [--config <path>] [--root <path>]
```

- Auto-detects `sources.json` the same way `generate.sh` does (`tools/agent-sync/sources.json`,
  then `.agent-sync/sources.json`).
- Resolves `REPO_ROOT` identically to `generate.sh` (parent of the config dir, with the
  `tools/agent-sync` / `.agent-sync` special-casing).
- Reads the optional `lint` block from `sources.json`. **No `lint` block → print nothing, exit 0.**
- Runs three independent checks, collects **all** findings, prints them sorted, then exits.

Rationale for a separate script (not a `--lint` flag on `generate.sh`): single responsibility,
independently runnable and testable, and it keeps the already-large `generate.sh` (692 lines)
focused on assembly. Cost is one extra vendored file + one extra CI line.

## Configuration

All under one optional `lint` key in `sources.json`. Every sub-key and field is optional.

```jsonc
{
  "version": 2,
  "files": { /* ... existing ... */ },
  "outputs": [ /* ... existing ... */ ],

  "lint": {
    "contradictions": {
      "severity": "warn",                      // default: warn
      "files": ["README.md", "CLAUDE.md"],     // default if omitted
      "exclusiveGroups": [
        ["Supabase", "Postgres"],
        ["Vercel", "Hetzner"]
      ]
    },
    "lineBudget": {
      "severity": "warn",                      // default: warn
      "max": 200,                              // default: 200
      "files": ["CLAUDE.md", ".claude/rules/*.md"]
    },
    "softPreferences": {
      "severity": "warn",                      // default: warn
      "files": ["CLAUDE.md", ".claude/rules/*.md"]
    }
  }
}
```

### Severity

`severity` ∈ `{"error", "warn", "off"}` for every check.

- `error` — finding printed; contributes to exit code 1.
- `warn` — finding printed; does **not** affect exit code.
- `off` — check is skipped entirely (the escape hatch; no allowlist machinery in v1).

**Defaults:** every check defaults to `warn`. (Contradiction detection via word co-occurrence is a
heuristic — not proof — so it must not block CI until a project has tuned its groups. Teams opt into
`error` deliberately.)

Invalid `severity` (not one of the three) or non-numeric `lineBudget.max` is a **config error**:
print `[agent-sync lint] config error: ...` to stderr and exit 2.

### File lists & globs

- Each check has its own `files` list (the contradiction check needs `README.md`, which is not in
  the AGENTS.md `files` map — so lint does not reuse that map).
- Entries may be literal paths or single-level globs (`.claude/rules/*.md`).
- **Globs expand relative to `REPO_ROOT`**, not the current working directory, using bash `nullglob`.
  Recursive `**` globstar is **not** supported in v1 (documented).
- A glob that matches nothing, or an explicitly listed file that does not exist, is **silently
  skipped** (no finding). This keeps the lint quiet on repos that don't have a README, etc.

## The three checks

### 1. Contradictions (default `warn`)

For each group in `exclusiveGroups`:

- Scan the **union** of the check's `files`.
- A term is **present** in a file if it appears as a **whole word, case-insensitive**
  (`grep -iwF -- "$term"`). Whole-word matching means `Postgres` does **not** match inside
  `PostgreSQL`, and multi-word terms (`Claude Code`, `GitHub Actions`) match literally.
- If **≥ 2 distinct terms** from the same group are present anywhere across the union, emit one
  finding per group naming: the group, each matched term, and the file(s) it was found in.

**Known limitations (documented, accepted for v1):**
- Co-occurrence is not proof of contradiction — "migrated from Supabase to Postgres" or
  "do not use Vercel" will trip it. This is why the default is `warn`.
- Very short / common-word terms (`Go`, `C`, `R`) are the user's responsibility; the lint does not
  special-case them.
- No alias grouping (e.g. treating `Postgres`/`PostgreSQL` as one choice) and no section scoping in
  v1 — documented as future extensions.

### 2. Line budget (default `warn`)

- Glob-expand `files` (relative to `REPO_ROOT`, `nullglob`).
- For each existing file, count lines with `wc -l` (**raw line count — blank lines, comments, and
  code fences all count**; this is the honest deterministic signal and is documented as such).
- If `lines > max`, emit a finding: file path + line count + the budget.

### 3. Soft preferences (default `warn`)

- Glob-expand `files` as above.
- Flag lines where `prefer` is the leading directive verb. Exact ERE (case-insensitive), applied
  per line:

  ```
  ^[[:space:]]*([-*+]|#{1,6}|[0-9]+[.)])?[[:space:]]*prefer(s|red)?([[:space:]]|$)
  ```

  - Matches: `Prefer X over Y`, `- prefer using A`, `1. Prefer B`, `### Prefer C`.
  - Does **not** match mid-sentence prose: `users prefer dark mode`, `we preferred the old API`
    (not line-leading).
- Emit a finding per matched line: `file:lineno` + the offending text (trimmed).

## Reporting & exit code

- Findings from all three checks are **collected**, then **sorted deterministically** (by check,
  then file, then line) so CI output is stable across runs and machines.
- Output is human-readable, grouped by check, each line prefixed `[agent-sync lint]`. Example:

  ```
  [agent-sync lint] contradiction: group {Supabase, Postgres} — both terms present
      Supabase  -> README.md
      Postgres  -> CLAUDE.md
  [agent-sync lint] line-budget: .claude/rules/architecture.md is 250 lines (budget 200)
  [agent-sync lint] soft-preference: CLAUDE.md:42: Prefer composition over inheritance
  [agent-sync lint] summary: 0 errors, 3 warnings
  ```

- **Exit code:**
  - `0` — no `error`-severity findings (warnings may be present, or no `lint` block at all).
  - `1` — at least one `error`-severity finding.
  - `2` — config error (invalid severity / non-numeric max / unreadable config).
- When there is no `lint` block, print **nothing** (no summary) and exit 0.

## Wiring

### `/agent-sync:check`

Update the command to run **both** the drift check and the lint, preferring repo-vendored copies
(the same precedence already used for `generate.sh`, so the command stays byte-consistent with CI):

```bash
# drift
GEN=... (tools/agent-sync/generate.sh | .agent-sync/generate.sh | $CLAUDE_PLUGIN_ROOT/scripts/generate.sh)
bash "$GEN" --config "<sources.json>" --check ; gen_rc=$?

# lint
LINT=... (tools/agent-sync/lint.sh | .agent-sync/lint.sh | $CLAUDE_PLUGIN_ROOT/scripts/lint.sh)
bash "$LINT" --config "<sources.json>" ; lint_rc=$?
```

- Both run **independently** (lint runs even when drift is detected) so the user sees all problems
  in one pass.
- Overall check is "failed" if either `gen_rc` or `lint_rc` is non-zero; report which.

### `/agent-sync:init`

Vendor `lint.sh` into the repo next to `generate.sh` (`tools/agent-sync/lint.sh` or
`.agent-sync/lint.sh`), and scaffold/refresh the GitHub Actions workflow to run both.

### GitHub Actions template

Repo-local invocation, no plugin/Claude dependency:

```yaml
- run: bash tools/agent-sync/generate.sh --check
- run: bash tools/agent-sync/lint.sh
```

### Docs

- `skills/agent-sync/references/sources-json-format.md` — document the `lint` block, all fields,
  defaults, severities, glob semantics, and the contradiction-check limitations.
- `README.md` — add a short "Linting" subsection and list `lint.sh` in Components.

## Testing

New `tests/run-lint-tests.sh` following the existing harness style (`assert_*` helpers, `mktemp -d`
fixtures, `PASS`/`FAIL` counters). Wire it into `tests/run-tests.sh`.

**Acceptance-criteria cases:**
1. Injected README/CLAUDE.md stack contradiction (`Supabase` in README, `Postgres` in CLAUDE.md,
   group `["Supabase","Postgres"]`) → contradiction finding emitted. With `severity: error` → exit 1.
2. A 250-line rules file with `max: 200` → line-budget finding emitted.
3. A line-leading `Prefer X over Y` directive → soft-preference finding emitted.
4. A synced, in-budget, single-stack fixture → no findings, exit 0.

**Robustness / regression cases:**
5. `Postgres` group term must **not** match a file containing only `PostgreSQL` (whole-word guard).
6. Multi-word term (`Claude Code`) matches literally.
7. Mid-sentence `users prefer dark mode` → **no** soft-preference finding.
8. Single term from a group present → **no** contradiction finding.
9. Missing `lint` block → no output, exit 0.
10. Glob matching nothing / explicitly-listed missing file → silently skipped, no error.
11. Invalid `severity` value or non-numeric `max` → config error, exit 2.
12. `severity: "off"` on a check → that check produces no findings.
13. Deterministic output ordering — same fixture produces byte-identical output across runs.

## Out of scope (v1 / YAGNI)

- Alias grouping and per-term pattern schemas for contradictions.
- Section-scoped contradiction detection.
- Line-level `lint ignore` comments / full allowlist system (the `off` severity covers disabling).
- "Logical line" counting that discounts blanks/comments/fences.
- Recursive `**` globstar.

## Version

Bump `0.2.2 → 0.3.0` in **both** `plugins/agent-sync/.claude-plugin/plugin.json` and the root
`.claude-plugin/marketplace.json` (must stay in sync per repo rules).
