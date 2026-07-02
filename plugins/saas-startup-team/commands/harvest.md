---
name: harvest
description: Dry-run harvester for the self-improvement loop. Clusters local session-insights signals into candidate GENERIC plugin improvements, de-identifies them, runs a hard PII gate, dedups against a ledger, and presents drafts for review. No network, no issue filing — review precedes any filing. Usage: /harvest
allowed-tools: Bash, Read
user_invocable: true
---

# /harvest — candidate plugin improvements (dry run)

Part of the self-improvement loop (see `docs/design/self-improvement-loop.md`).
This turns *local* intervention/friction signals into **candidate generic
plugin-improvement drafts** for the investor to review. It is **dry run only**:
nothing is filed anywhere, and nothing touches a public repo. Public filing is a
separate, later, opt-in stage gated behind the human review.

## Pipeline

1. Refresh local signals (idempotent; safe to re-run):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/session-insights.sh"
```

2. Cluster + de-identify + PII-gate + dedup into candidates:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/harvest.sh"
```

`harvest.sh` is the deterministic **safety layer**: it de-identifies (project
nouns → `{{PROJECT}}`), **hard-blocks any candidate containing a secret/PII
pattern**, enforces recurrence thresholds, and dedups against
`.startup/insights/harvest-ledger.json`. It decides nothing about genericity or
phrasing. Output: `.startup/insights/candidates.jsonl` + `.startup/insights/harvest-report.md`.

3. For market/customer/product demand candidates, run the broader internal evidence
   harvester:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/demand-discovery.sh"
```

It ingests configured Claude/Codex session JSONL, GitHub issue/PR exports, local
docs/learnings, test logs, runtime/error logs, and analytics exports. It clusters signals
by customer pain area, ranks needs by evidence/confidence/value/complexity, de-identifies
project-specific strings, and attaches acceptance packs. It does **not** perform external
market research; when no browsing or paid data is available, internal discovery still runs
and the report states that limitation.

## Your job (the genericity + drafting step)

Read `.startup/insights/candidates.jsonl`. Each candidate is a recurring,
de-identified, PII-checked cluster with `signal_type`, `count`, `evidence_refs`,
and a deterministic `observation`. For each one:

1. **Decide scope.** Is this a *generic, transferable* lesson about how the agent
   team builds SaaS, or is it project-specific? Project-specific → drop it (keep
   it out of any plugin-improvement draft).
2. **Draft conditionally.** For generic ones, write the improvement as:
   *"When [context], the plugin should prefer/avoid [behavior], because
   [evidence: N occurrences, refs]. Counterexamples: [...]."* Fill
   `hypothesis` and `recommendation`; keep `observation` factual.
3. **Re-check de-identification.** Confirm no project/customer specifics, no
   verbatim quotes, no paths/IDs survived. When unsure, drop it.

Present the surviving drafts to the investor as a short review list (title +
one-line recommendation + evidence count).

## Filing (opt-in, gated — `lesson-file.sh`)

Filing is a separate, explicitly-gated step. By default it is a **dry run** that
files nothing:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lesson-file.sh" --repo "${SAAS_PLUGIN_REPO}"
```

To actually open `lesson-candidate` issues in the plugin repo, the investor sets
the enable flag and pins the repo (`SAAS_PLUGIN_REPO`, or `--repo OWNER/REPO`):

```bash
SAAS_LESSON_SYNC_ENABLED=true \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/lesson-file.sh" --repo "${SAAS_PLUGIN_REPO}"
```

`lesson-file.sh` re-runs the hard PII gate on every issue at the filing boundary,
is idempotent (the ledger prevents re-filing), and dedups against existing open
issues. The filed issues are `lesson-candidate`s — they still pass through the
human review gate (`/lessons-review`) before any implementation.
