---
name: lawyer
description: "On-demand legal analysis — queries the est-saas-datalake API and project context to produce Estonian-language legal compliance and risk analysis. Usage: /lawyer <topic>"
user_invocable: true
---

# /lawyer — On-Demand Legal Analysis

Run one topic-scoped Lawyer consultation, write its decision brief, and exit.
The Lawyer is not a founder-loop participant. Stay token-frugal: load only the
topic, named context, and operation reference section needed for this run.

## Pre-flight

Hard-fail before any dispatch:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-preflight.sh"
```

This checks datalake readiness/key, startup state, and registry shape without
printing credentials. Do not continue after a failure.

## Subcommand dispatch

Inspect the first whitespace-delimited token in `$ARGUMENTS`. For `register`,
`unregister`, `ack`, `ack-all`, `issue`, `status`, or `check`, read only the
matching section of `skills/lawyer/references/lawyer-operations.md`, run its
deterministic `scripts/lawyer-*.sh` command, report the result, and stop.
Topics beginning with a reserved token must be quoted.

Otherwise treat `$ARGUMENTS` as the free-form topic.

## Change detection

Before every free-form topic, persist current registry signals once:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-check.sh"
```

### Non-interactive / autonomous disposition

If this run cannot accept immediate confirmation:

1. Print one compact warning with pending count/slugs, existing issue URLs, and
   `/lawyer status` for details. The flags remain durable in `.startup/law-registry.json`.
2. Skip Marker Scan, Invariant Check, Conditional gh pre-flight, Fix-Plan
   Generation, Confirmation, and issue creation. Continue directly to
   `## Execution`; never load or spawn an agent for unrelated backlog.
3. Issue creation still requires an explicit subcommand or interactive
   confirmation. Never clear/ack flags or set `gh_issue_url` here.
4. If the topic depends on a flagged slug, mark it pending and re-verify it from Tier A before using it.

If interactive confirmation is available and unfiled flags exist, read only
`Interactive backlog review` in
`skills/lawyer/references/lawyer-operations.md`. Complete that flow, then
continue the requested topic. Existing filed flags produce one reminder and do
not block unrelated analysis.

## Execution

### Step 0: Reset active_role

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "lawyer"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

### Step 1: Load Lawyer Skill

```text
Skill('saas-startup-team:lawyer')
```

### Step 2: Gather targeted context

Read only topic-relevant sections of `docs/business/brief.md`,
`.startup/state.json`, files named by the request, and targeted matches in
`docs/`. Read the latest handoff only when the topic concerns that active work.
Do not inventory or load the newest files across every docs area.

### Step 3: Run Lawyer

Use `Task` with `subagent_type: "saas-startup-team:lawyer"`. Pass the topic and
targeted context summary. Require the Lawyer skill's topic workflow, one concise
Estonian decision brief, checked citations, and exact human-task metadata.

### Step 4: Verify deliverable

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legal-verdict-gate.sh" --validate \
  <written-doc>...
```

Validation must pass before reporting: complete primary-source sentences for
confirmed Tier A claims, exact body/frontmatter human-task parity, valid schema,
and at most 150 lines. Remove unrelated audit sections.

### Step 5: Report

Summarize in English: artifact path, decision/risk levels, evidence boundary,
and human tasks. Do not restate the report.
