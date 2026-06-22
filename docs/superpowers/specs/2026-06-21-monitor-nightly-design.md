# Design: Generic `/monitor-nightly` command for `saas-startup-team`

**Date:** 2026-06-21
**Issue:** #51 — Generalize the nightly recurring-issue monitor into a reusable plugin command
**Status:** Approved (brainstorming) — ready for implementation plan
**Reviews:** self ("ultrathink") + Codex (gpt-5.5) adversarial design review, both folded in

## 1. Problem & goal

The Aruannik project has a battle-tested ~400-line nightly monitor
(`est-biz-aruannik/.claude/commands/monitor-nightly.md`) that scans production for failure
patterns, deduplicates per `(entity, pattern_key)`, files GitHub issues, comments on
recurrences, and persists state across runs. It is genuinely reusable but lives project-local
with hardcoded specifics (repo slug, admin-API endpoints, SSH repro host, EMTA/pipeline
categories).

**Goal:** extract a generic, project-agnostic `/monitor-nightly` command into the
`saas-startup-team` plugin. Carry over the reusable engine (state, dedup, GitHub issue
filing, the filesystem marker sweep, summary, dry-run, cron). Drop all product-specific HTTP
collectors. Add a project-supplied **custom-checks script** hook so a product plugs in its own
signals without the plugin owning an HTTP-probe DSL.

This is the first shippable slice of the larger "operate phase" vision (issue #11); everything
beyond the nightly monitor is explicitly out of scope here.

## 2. Scope

**In scope**
- `commands/monitor-nightly.md` — markdown command (LLM-orchestrated collection + formatting).
- `scripts/monitor-dedup.sh` — deterministic shell engine owning dedup/state/all `gh` I/O.
- `tests/monitor-dedup.test.sh` — unit tests with a mocked `gh`.
- Config: a new optional `monitor:` block in `.claude/saas-startup-team.local.md`.
- README section (Installation + config table + producer/custom-checks contracts).
- Version bump in **both** `.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json`.

**Out of scope (deferred to #11 "operate phase")**
- Interactive `/monitor`, `/investigate`, session-replay, support triage.
- A separate `.startup/operate.yml` config file (reuse `.local.md` for now; graduate later if #11 wants it).
- Any product-specific HTTP collectors (these become the *project's* custom-checks script).
- Issue **reopening** logic (closed always means create-fresh).
- Cross-host distributed locking (single-host `flock` + search-before-create is the documented mitigation).

## 3. Architecture: two layers

### 3.1 Markdown command (`commands/monitor-nightly.md`)
Runs under `claude -p "/monitor-nightly"` (headless cron) or interactively. Responsibilities —
**judgment and formatting only; never calls `gh`:**
1. Load config from `.claude/saas-startup-team.local.md` (`monitor:` block; all keys optional → defaults).
2. Acquire a whole-run `flock` on the state file so a manual run can't overlap the cron run.
3. Ask the engine for the scan window: `monitor-dedup.sh window`.
4. Collect findings from both producers into a single findings JSONL stream (§5).
5. Render reproduction context into each finding's `body` (the part needing judgment).
6. Pipe findings to `monitor-dedup.sh commit`.
7. Print the human summary from the engine's structured action log.
8. Honor `--dry-run` (passed through to the engine; no `gh` mutations anywhere).

### 3.2 Shell engine (`scripts/monitor-dedup.sh`)
Deterministic. Owns **all** `gh` calls (create / comment / label / view / search / repo
resolution), all state I/O, schema validation, dedup, locking semantics, and the action log.
Two subcommands:

- **`window --state <file>`** — read state (read-only), compute the scan window:
  - first run (no `last_run_at`) → 24h;
  - else → since `last_run_at`;
  - cap at 48h maximum.
  Print `MONITOR_SINCE_MINUTES=<n>` and `MONITOR_SINCE=<ISO>` (eval-able / parseable).
- **`commit --state <file> [--dry-run] [--repo <slug>]`** — read findings JSONL on stdin,
  apply the dedup ladder (§6), perform `gh` actions, write state atomically, emit a JSON
  action log on stdout for the summary.

The engine takes `gh` from `$PATH` (tests shim a fake `gh`). Every `gh` invocation passes
`--repo "$repo"` (resolved once from config or `gh repo view`).

**Why two phases:** custom-checks need the prior `last_run_at`-derived window *before* state is
mutated. `window` (read) + `commit` (write) is the clean split; the markdown layer does
`window → collect → commit`.

## 4. Findings contract (the seam)

Every producer — marker sweep and custom-checks — emits **one JSON object per line**:

```json
{
  "pattern_key": "ops:llm-categorize:failure",
  "severity": "high",
  "entity": "ARU-2026-... | null",
  "title": "[Monitor] LLM categorize failing — 6/6 errors",
  "body": "full markdown body for a NEW issue (repro context lives here)",
  "summary": "one-line text for a recurrence COMMENT (optional; falls back to title)"
}
```

Field rules:
- `pattern_key` (**required**) — stable dedup key. Validated against `^[a-z0-9][a-z0-9:_-]*$`.
  A finding with an invalid/missing key is treated as malformed input (§7.3).
- `entity` — per-incident id (session/order/feedback id …) or `null` for fleet-wide ops signals.
  Dedup is per `(entity, pattern_key)`. **One entity hitting multiple patterns files multiple
  issues** (this preserves the real bug-fix where a session's second failure was previously
  swallowed). Stored and compared as a JSON value (via `jq`), never string-concatenated, so
  backticks/newlines/pipes in an id cannot corrupt the state key.
- `severity` — one of the configured `severities` (default `high|medium|low`); maps to a label.
- `title` / `body` — pre-rendered by the producer; `body` is used for a **NEW** issue.
- `summary` — short text for a **recurrence COMMENT**; optional, falls back to `title`. (Producers
  cannot know at emit-time whether a finding becomes create-vs-comment — that is the engine's
  decision — so both forms are supplied up front.)

The engine knows *only* this schema. The marker sweep and custom-checks are simply two producers
of the same lines.

## 5. Sources (two producers)

### 5.1 Marker sweep (built into the command)
Iterate `<marker_dir>/*-last-failure.txt` (default `.monitor/`). For each marker:
- `kind` = filename minus `-last-failure.txt`.
- `pattern_key = ops:<kind>:failure`, `severity = high`, `entity = null`.
- `title = [Monitor] <kind> failed — <first line of marker>`.
- `body` = full marker contents + tail (~40 lines) of a companion log if one exists under a
  conventional logs dir (`<kind>.log` / `nightly-<kind>.log`), plus a note that the marker
  auto-clears on the producer's next successful run.

A marker's presence means "this job/service is currently failing and hasn't recovered." No time
window applies (filesystem state, not a time query).

**Marker lifecycle contract (documented for producers):**
1. Shell wrappers write `<marker_dir>/<kind>-last-failure.txt` on non-zero exit, delete it on
   zero exit. `kind` is kebab-case, grouped by service + root cause ("one kind = one triage").
2. A human closes the filed GitHub issue when the problem is fixed.
3. Recurrence-after-close → the engine sees the stored issue is CLOSED and files a **fresh**
   issue (§6 step 2). This is exactly why closed-issue reconciliation matters: without it, a
   recovered-then-re-failed marker would be skipped forever.

Fleet-wide signals use `entity = null` and therefore collapse to **one open issue per
pattern** by design. A producer that wants per-incident granularity sets a concrete `entity`
(e.g. deploy SHA, job id, failing endpoint).

### 5.2 Custom-checks hook (project-supplied)
If `<custom_checks>` (default `.startup/monitor-checks.sh`) exists and is executable, the command
runs it with the scan window in the environment:
- `MONITOR_SINCE` (ISO) and `MONITOR_SINCE_MINUTES` — from `monitor-dedup.sh window`.

The script's **stdout** is JSONL findings (§4), merged into the stream. This is where a product
puts its own API probes — the Aruannik admin-API steps (sessions/payments/feedback/funnel/LLM
health) become *this script* in the Aruannik repo, not plugin code.

Failure handling (surface, never swallow):
- Valid findings on stdout are processed **even if the script exits non-zero**.
- Non-zero exit also emits a `ops:monitor-checks:failure` finding (severity high, entity null)
  whose body captures the script's **stderr** and exit code.

## 6. Engine dedup ladder (`commit`)

Process findings **in order**, mutating an in-memory working copy of state so that two
same-pattern findings in one run yield 1 create + 1 comment (not 2 creates). For each finding:

1. Compute `(entity, pattern_key)`.
2. **Closed-issue reconciliation:** if `pattern_key` is known in state, check its stored
   `gh_issue` via `gh issue view --json state` (cached once per issue number per run). If
   CLOSED → treat as a brand-new pattern (drop the stale mapping, fall through to create).
3. If `pattern_key` known (and open) **and** `entity` already in its `sessions` list → **SKIP**
   (already reported this exact `(entity, pattern)`; do not re-comment).
4. If `pattern_key` known (and open) **and** `entity` is new → **COMMENT** on the stored issue
   (generic recurrence header + `summary`), append `entity`, update `last_seen`.
5. If `pattern_key` unknown → **state-loss recovery search** first:
   `gh issue list --state open --search "<pattern_key>"` (and, when `entity` is non-null, require
   the entity marker too — both `**Pattern:**` and `**Entity:**` markers are embedded in issue
   bodies). If a matching open issue is found → adopt it (comment, record in state); else
   **CREATE** a new issue.
6. **Labels:** before the first create, ensure base labels (`labels` config) + each severity
   label exist (idempotent `gh label create --force`). If label-ensure fails, **still create the
   issue** (filing > perfect labels) but record a warning in the action log (missing
   `monitor`/`customer-issue` labels would silently disengage the regression-test gate).
7. **Per-finding `gh` failure:** log it, do **not** record that finding in state (so it retries
   next run), and mark the run as failed (see §7.1).
8. **State write:** atomic — `mkdir -p` the parent, `mktemp` a temp file in the *same* directory,
   write, `mv` over the target. Performed once at the end with all successful actions.

### New-issue body additions (engine-appended)
- Machine markers: `**Pattern:** \`<pattern_key>\`` and (when non-null) `**Entity:** \`<entity>\``.
- A configured `repro_recipe` (with `{entity}` substituted) — appended **only when `entity` is non-null**.
- **DoD line:** "Fixing this requires a regression test (or an explicit
  `Regression-Test: none — <reason>` override), per the regression-test gate." The monitor's own
  `monitor`/`customer-issue` labels are what the gate keys on, so monitor-filed issues
  automatically require a regression test.

## 7. Failure semantics & robustness

### 7.1 Never advance the window past a dropped incident
`commit` advances `last_run_at` to "now" **only if every finding was processed successfully**.
If any `gh` op failed, or any input was malformed (§7.3), `commit` exits non-zero and leaves
`last_run_at` unchanged. Successfully-filed findings are still persisted, so the next run
re-scans the same window but only the failed/missing ones are re-filed (succeeded ones
dedup-skip via §6 step 3). At-least-once for failures, no duplicates for successes.

### 7.2 Concurrency
The markdown command wraps the whole run (`window → collect → commit`) in `flock` on the state
file, preventing an overlapping manual + cron run on one host. Cross-host duplicates are not
fully preventable (GitHub has no atomic issue upsert); the §6-step-5 search-before-create is the
documented best-effort mitigation.

### 7.3 Malformed input is surfaced, not swallowed
Unparseable JSONL lines (or findings failing schema/`pattern_key` validation) → the engine files
a single `ops:monitor-input:malformed` issue containing the offending lines, **and** treats the
run as failed (§7.1, window not advanced). A producer bug must never look like "all clear."

### 7.4 Other error handling
- Any individual `gh` read (e.g. `issue view`) failing → treat that pattern as
  unknown-but-search, never crash the batch.
- State file missing/corrupt at read → start fresh (`window` returns the 24h first-run window).
- `--dry-run` → engine performs all reads (window, view, search) but **no** mutations; the action
  log marks every would-be action with `[DRY RUN]`; state is not written.

## 8. State file schema

Default location: **`.startup/monitor-state.json`** (repo-local → naturally per-repo; avoids the
single-`$HOME`-file collision when one cron host serves multiple repos). Add to the product's
`.gitignore`.

```json
{
  "version": 1,
  "last_run_at": "2026-06-21T02:00:00Z",
  "patterns": {
    "<pattern_key>": {
      "gh_issue": 142,
      "sessions": ["ARU-...-a", "ARU-...-b"],
      "first_seen": "2026-06-19T02:00:00Z",
      "last_seen": "2026-06-21T02:00:00Z"
    }
  }
}
```

(The reference's separate `reported_cids` / `reported_feedback_ids` lists collapse into the
unified `patterns`/`sessions` model: feedback becomes a finding with `entity = <feedback_id>`,
so per-`(entity, pattern_key)` dedup gives the same "file once, never recur" semantics. Whether a
product keys feedback as `feedback:<id>` or `feedback:<category>` + `entity=<id>` is a producer
choice; the engine is agnostic.)

## 9. Config (`.claude/saas-startup-team.local.md`, new `monitor:` block — all optional)

```yaml
monitor:
  repo: owner/name                          # default: resolved via `gh repo view`
  labels: [monitor, customer-issue]         # base labels; severity label appended per-finding
  severities: [high, medium, low]           # bare names by default (collision risk documented;
                                            # configurable, e.g. severity:high, if a repo needs it)
  marker_dir: .monitor
  state_file: .startup/monitor-state.json
  custom_checks: .startup/monitor-checks.sh
  repro_recipe: |                           # optional; {entity} placeholder; appended to NEW-issue
    ssh prod-readonly "session-tar {entity}"  # bodies only when entity is non-null
```

## 10. Testing (`tests/monitor-dedup.test.sh`, mocked `gh`)

Golden `(state-in, findings-in) → (gh actions, state-out)` cases:
1. New pattern → CREATE; state records issue + entity.
2. Same `(entity, pattern)` as state → SKIP (no `gh` call).
3. Same pattern, new entity → COMMENT; entity appended.
4. Same entity, **different** pattern → CREATE (multi-pattern-per-entity not collapsed).
5. Two findings same pattern / different entity **in one run** → 1 CREATE + 1 COMMENT.
6. Stored issue CLOSED → CREATE fresh (reconciliation).
7. State lost but open issue exists (search hits) → adopt/COMMENT, no duplicate CREATE.
8. State lost, entity-specific: search requires both pattern+entity markers → no wrong-issue merge.
9. Corrupt/empty state → fresh; `window` returns 24h.
10. Malformed JSONL line → `ops:monitor-input:malformed` filed + run fails + `last_run_at` unchanged.
11. `gh` create fails for one finding → that finding not in state, run exits non-zero, window unchanged.
12. `--dry-run` → zero mutations, action log marked `[DRY RUN]`, state unwritten.
13. `window`: first-run = 24h; subsequent = since `last_run_at`; capped at 48h.
14. `pattern_key` failing the regex → rejected as malformed.

Plus a self-test that the command's frontmatter and the README config table list the same keys.

## 11. Deliverables checklist
- [ ] `commands/monitor-nightly.md` (frontmatter: `name`, `description`, `allowed-tools: Bash, Read, Write, Grep, Glob`, `argument-hint: "[--dry-run]"`).
- [ ] `scripts/monitor-dedup.sh` (`window` + `commit`, all `gh` I/O, atomic state, flock-friendly).
- [ ] `tests/monitor-dedup.test.sh` (cases above; runs in CI alongside existing tests).
- [ ] `saas-startup-team.local.md.example` — add the `monitor:` block.
- [ ] README — Installation section (three scopes), `monitor:` config table, marker-producer
      contract, custom-checks contract, cron snippet, the dependency note (`gh`, `jq`, `flock`).
- [ ] Version bump in `.claude-plugin/plugin.json` **and** root `.claude-plugin/marketplace.json`.

## 12. Open questions
None blocking. (Marker recurrence is resolved via closed-issue reconciliation; feedback keying and
severity-label namespacing are producer/config choices with documented defaults.)
