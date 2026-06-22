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
phrasing. Output: `.startup/insights/candidates.jsonl` + `harvest-report.md`.

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
one-line recommendation + evidence count). **Do not file anything.** Filing to
`paat/claude-plugins` happens only after the investor approves, in the separate
opt-in filing stage (not built yet).
