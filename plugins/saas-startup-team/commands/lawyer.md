---
name: lawyer
description: On-demand legal analysis — queries the est-saas-datalake API and project context to produce Estonian-language legal compliance and risk analysis. Usage: /lawyer <topic>
user_invocable: true
---

# /lawyer — On-Demand Legal Analysis

The human investor requests legal analysis on a specific topic. You spawn the Lawyer agent to research and write analysis.

**The Lawyer is a one-shot consultant, NOT a loop participant.** It spawns, does its analysis, writes to `docs/legal/õiguslik-*.md`, and exits.

The deterministic subcommand logic lives in `${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-*.sh`; those scripts source `lawyer-common.sh`, which defines the `DATALAKE_URL` default and the shared datalake helpers. Run them from the project root (they read/write `.startup/law-registry.json` and `.startup/laws/`).

## Pre-Flight Checks (HARD FAIL — No Fallbacks)

Before spawning the Lawyer agent, ALL of the following must pass. If any check fails, stop with an error message and do NOT proceed.

Define the datalake base once, before the health check (override with `export DATALAKE_URL=…`):

```bash
: "${DATALAKE_URL:=https://datalake.r-53.com}"
```

### Check 1: Datalake API is reachable

```bash
curl --max-time 10 -s -o /dev/null -w "%{http_code}" "$DATALAKE_URL/api/v1/health/ready"
```

**Must return:** `200`

**If not 200 or unreachable:**
> **Error:** est-saas-datalake API is not available at `$DATALAKE_URL`. The Lawyer requires the datalake for Estonian legal analysis. Fix the datalake service (or `export DATALAKE_URL`) before running /lawyer.

### Check 2: Startup project exists

Verify that these files exist: `.startup/state.json` and `docs/business/brief.md`.

**If missing:**
> **Error:** No startup project found. Run /startup first to initialize the project before running /lawyer.

### Check 3: API key is available

```bash
echo "${EST_DATALAKE_API_KEY:?not set}" > /dev/null 2>&1
```

**If not set:**
> **Error:** EST_DATALAKE_API_KEY environment variable is not set. The Lawyer needs an API key to query the datalake. Set it with: export EST_DATALAKE_API_KEY=your-key

### Check 4: Law registry is valid (if present)

If `.startup/law-registry.json` exists, it must be valid JSON with `version: 2`. Missing file is fine — the command creates it on first use.

```bash
if [ -f .startup/law-registry.json ]; then
  jq -e '.version == 2' .startup/law-registry.json >/dev/null 2>&1
fi
```

**If non-zero exit:**
> **Error:** `.startup/law-registry.json` is not valid JSON or is not version 2 (expected `{"version": 2, ...}`).

### Check 5: Laws directory is a directory (if present)

If `.startup/laws` exists, it must be a directory. Missing path is fine.

```bash
[ ! -e .startup/laws ] || [ -d .startup/laws ]
```

**If non-zero exit:**
> **Error:** `.startup/laws` exists but is not a directory. Remove or rename it before running /lawyer again.

## Subcommand Dispatch

After pre-flight passes, inspect `$ARGUMENTS`. If the first whitespace-delimited token is one of `register`, `unregister`, `ack`, `ack-all`, `issue`, `status`, `check`, route to that subcommand below (pass the remaining tokens as its args). Otherwise `$ARGUMENTS` is a free-form topic — continue to Change Detection then analysis (`## Execution`).

Disambiguation: topics that legitimately start with one of these tokens must be quoted: `/lawyer "register a user — GDPR-compliant?"`.

## Register subcommand

Args: `register <slug> <act_id> <citation> <purpose> [--force]`

- `slug` — kebab-case `[a-z0-9-]+`.
- `act_id` — **integer** from `GET /api/v1/laws/search?q=<act-name>` — the `.id` field, not `rt_id`, not the RT URL segment. Look it up first: `curl -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$DATALAKE_URL/api/v1/laws/search?q=isikuandmete+kaitse&limit=5" | jq '.items[] | {id, rt_id, title}'`.
- `citation` — Estonian compound reference like `"§ 10 lõige 1 punkt 3"`. Superscript qualifiers (¹²³) are load-bearing (`§ 14 lg 1¹` ≠ `§ 14 lg 1`).
- `purpose` — one-line Estonian description of why the paragraph is load-bearing.
- `--force` — override the lifecycle guard. Without it, registering an act the datalake reports as not in force (`in_force == false` or `status != "valid"`) is refused. A 200 from `/citation` does **not** mean the law is current — a repealed/superseded/never-in-force act still returns 200 + text.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-register.sh" <slug> <act_id> "<citation>" "<purpose>" [--force]
```

The script resolves act metadata, fetches + snapshots the paragraph text, applies the lifecycle guard, and writes the entry. It hard-fails without leaving a partial snapshot or index entry.

## Unregister subcommand

Args: `unregister <slug>`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-unregister.sh" <slug>
```

## Change Detection

Runs at the start of every `/lawyer` invocation, after pre-flight and subcommand dispatch but before analysis. Polls `/changes/feed` once (matched client-side by `rt_id`), re-checks each not-yet-flagged entry's lifecycle via `/citation`, and for entries with `expected_effective_date` polls the Riigi Teataja blob-html header to flag postponements the feed cannot see, persisting any new flags. Reads only the index JSON.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-check.sh"
```

After this step the index reflects all feed changes plus any feed-independent lifecycle changes. Flagged entries are handled by the Fix-Plan and Confirmation flow below.

## Marker Scan (internal helper)

Produces a `slug → file:line` map (one `<slug>\t<file>:<line>` line per marker) by scanning project source for `LAW:` markers, excluding `docs/legal/`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-marker-scan.sh"
```

### Orphan warnings

After running the scan (non-blocking):
- **Marker slugs not in the registry:** warn for each such slug and its first file:line hit.
- **Registry slugs with no marker hits:** warn for each; candidate for `unregister`.

## Invariant Check (non-blocking warnings)

```bash
# Registered slug with no snapshot file
jq -r '.entries | keys[]' .startup/law-registry.json | while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  [ -f ".startup/laws/${slug}.txt" ] || echo "WARNING: snapshot missing for registered slug '$slug'"
done
# Orphan snapshot files
if [ -d .startup/laws ]; then
  for f in .startup/laws/*.txt; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .txt)
    jq -e --arg s "$s" '.entries | has($s)' .startup/law-registry.json >/dev/null || echo "WARNING: orphan snapshot '$f' (no registry entry for '$s')"
  done
fi
```

Marker/registry slug-set mismatches are surfaced by the Marker Scan orphan warnings above.

## Conditional gh pre-flight

If any entry has `needs_review=true` AND `gh_issue_url=null`, the investor is about to be prompted to create a GitHub issue — `gh` must work at that point.

```bash
needs_gh=$(jq -r '.entries | to_entries[] | select(.value.needs_review == true and .value.gh_issue_url == null) | .key' .startup/law-registry.json | head -n1)
if [ -n "$needs_gh" ]; then
  command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not installed and /lawyer detected pending legal changes that need GitHub issues."; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Error: gh is not authenticated. Run 'gh auth login' first."; exit 1; }
  gh repo view --json nameWithOwner >/dev/null 2>&1 || { echo "Error: not a GitHub-backed repository. /lawyer's change workflow requires a GitHub remote."; exit 1; }
  # Ensure the fix-tracking labels exist (idempotent; internal, so silenced).
  gh label create legal-review --color FFA500 --description "Õigusküsimus või seadusemuudatus" --force >/dev/null 2>&1 || true
  gh label create seadusemuudatus --color FF6B6B --description "Estonian law changed — fix pending" --force >/dev/null 2>&1 || true
fi
```

## Fix-Plan Generation

Runs only when Change Detection produced at least one flagged-and-unacked entry (`needs_review=true AND gh_issue_url=null`). Entries whose `gh_issue_url` is already set are skipped.

### Step 1: Collect inputs

```bash
TMP=$(mktemp -d)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-fixplan-collect.sh" "$TMP"
```

This writes `$TMP/<slug>.json` (old + new text, lifecycle status, feed change, datalake impact) for each flagged-and-unacked slug, and `$TMP/markers.tsv` (slug → file:line).

### Step 2: Spawn the Lawyer agent

Invoke the Lawyer agent via the Task tool with
`subagent_type: "saas-startup-team:lawyer"` and the following brief:

> Brief: "Seadusemuudatuste parandusplaan"
>
> Context files (read these — they already contain old text, new text, and feed-event summaries):
> - `$TMP/<slug>.json` for each flagged slug
> - `$TMP/markers.tsv` — the slug → file:line map
>
> For each flagged slug:
> 1. Read the files listed in markers.tsv for that slug; understand how each site uses the paragraph.
> 2. Check the slug JSON's `in_force`/`status`. If `in_force` is `false` (or `status` is not `valid`), the act was **repealed or superseded** — there is no replacement text to adopt. The fix is to **remove or replace** the dependency, not to update wording. Do not treat `new_text` as current law.
> 3. Produce a plain-language fix plan per file: what changes, WHY (one sentence), HOW (concrete). NOT legal language.
> 4. Write/append `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md` (fix plan up front; legal diff in a `<details>` appendix).
>
> Do NOT modify `.startup/law-registry.json` or any `.startup/laws/*.txt` file.
>
> Return (final message): a one-sentence summary per slug, prefixed with the slug. Example:
> `consent-lawful-basis: § 10 lõige 2 lisas töötleja teavituse kohustuse — uuendada tuleb 3 faili.`

On agent failure: fall back to a minimal fix plan generated from the new-text diff, write a stub review doc, and continue.

## Confirmation and Issue Creation

If any entry has `needs_review=true AND gh_issue_url=null`:

### Step 1: AskUserQuestion prompt

Build the confirmation question with `AskUserQuestion`, listing each flagged slug's one-sentence summary from the agent:

> **Question:** "Seadusemuudatus avastatud — <N> kirje(t). Täielik parandusplaan: docs/legal/õiguslik-muudatused-<DATE>.md. Kas luua GitHubi issue(d) koos parandusplaaniga?"
>
> **Options:** `Jah, loo issue` (default) · `Ei, jäta hiljemaks`

### Step 2: On "Ei, jäta hiljemaks"

Print "Lipp jääb üles; tuleb järgmisel /lawyer käivitusel uuesti ette." and exit 0 without running the topic.

### Step 3: On "Jah, loo issue"

For each flagged-and-unacked slug:

1. Extract that slug's "Mida tuleb teha" section from `docs/legal/õiguslik-muudatused-<DATE>.md` and write it, followed by a `## Registri värskendus PR-s` note telling the fixer to run `/lawyer ack <slug>` on the PR branch, to `$TMP/${slug}-issue-body.md`.
2. Create the issue and store its URL:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-issue.sh" "$slug" "$TMP/${slug}-issue-body.md"
```

The script guards on `needs_review=true AND gh_issue_url=null`, creates the issue, and stores only `gh_issue_url`. On `gh` failure the slug stays flagged (re-prompted next run). It does NOT touch `needs_review`, `change`, `verified_at`, `redaktsioon_id`, or the snapshot — the PR that fixes the code updates those via `/lawyer ack`.

### Step 4: Continue with topic analysis

After all issues are created, continue with the original topic analysis (`## Execution`). Pass the newly-issued slugs as context so the output can note "pending legal fixes in #N, #N+1".

### Step 5: Re-detection while an issue is open

Entries with `gh_issue_url != null` are skipped silently by the confirmation flow. Print a reminder at the top of the run: "Lahtised seadusemuudatuste issue'd: <url1>, <url2> — ootavad PR-i." No duplicate issue is created.

## Ack subcommand

Args: `ack <slug>`

**Invocation contract:** run inside the branch/PR that contains the code fix; commit the registry + snapshot changes together with the code so the merge is atomic.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-ack.sh" <slug>
```

Fetches the new text, refreshes `.startup/laws/<slug>.txt`, clears flags, bumps `verified_at`/`redaktsioon_id`. Refuses (non-zero) if the freshly fetched citation is not in force — a non-valid act must be resolved with a code change, not re-snapshotted. `gh_issue_url` is preserved.

## Ack-all subcommand

Args: `ack-all`

Runs `ack` for every entry with `needs_review=true`. Use only when the PR's code changes cover every flagged slug; otherwise use per-slug `ack`. Non-valid entries are skipped (flag kept), not acked.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-ack-all.sh"
```

## Issue subcommand

Args: `issue <slug>`

Non-interactive Disposition A for one slug (for agents/scripts with no investor to prompt). Requires `needs_review=true AND gh_issue_url=null`; otherwise no-op. Creates a minimal-body issue and sets only `gh_issue_url`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-issue.sh" <slug>
```

## Status subcommand

Args: `status` — concise registry summary (no spawn, no feed call).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-status.sh"
```

## Check subcommand

Args: `check` — runs Change Detection and exits. Does NOT prompt, create issues, or spawn the agent. New flags are persisted; `/lawyer status` shows them.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-check.sh"
echo "Feed check complete."
echo "Run /lawyer status to see flagged entries, or /lawyer <topic> to trigger the fix-plan prompt."
```

## Execution

### Step 0: Reset active_role

Overwrite `active_role` in `.startup/state.json` before spawning the Lawyer. The `enforce-delegation` hook fires only when `active_role=="team-lead"`; a stale value would otherwise block the Lawyer's writes. `/lawyer` is never a team-lead context.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "lawyer"' .startup/state.json > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

### Step 1: Load Lawyer Skill

```
Skill('saas-startup-team:lawyer')
```

### Step 2: Gather Project Context

Read: `docs/business/brief.md`, `.startup/state.json`, the latest files in `docs/` (research, legal, architecture), and the latest handoff in `.startup/handoffs/`.

### Step 3: Spawn Lawyer Agent

Use `Task` with `subagent_type: "saas-startup-team:lawyer"`. Pass: the investor's topic, the project-context summary, and reminders to write to `docs/legal/õiguslik-*.md` in Estonian, query the datalake API first (web search second), and include disclaimers + cite all sources.

### Step 4: Report to Investor

After the Lawyer completes, summarize in English: which documents were written, key risk findings (high/medium/low), any human tasks (e.g. "hire a lawyer for DPA review"), and where to find the full analysis (`docs/legal/õiguslik-*.md`).
