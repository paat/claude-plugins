---
name: investigate
description: Investigate a live incident by correlation ID or recent sessions, create a redacted RCA artifact, and file or update a deduplicated GitHub issue when requested.
argument-hint: "{CID | --recent N} [--dry-run] [--file-issue]"
allowed-tools: Bash, Read, Write, Grep, Glob, Task
user_invocable: true
---

# /investigate - Incident RCA

Investigate a live incident using a correlation ID or a recent-session sweep. All endpoints, auth headers, labels, issue templates, and response shapes come from the `operate:` block in `.claude/saas-startup-team.local.md`.

## Inputs

- `{CID}` - a full correlation/session/customer-visible incident ID.
- `--recent N` - inspect the N most recent configured sessions and choose the highest-signal candidates.
- `--dry-run` - write artifacts and show the issue body without creating/updating GitHub.
- `--file-issue` - create or update a deduplicated GitHub issue after the RCA is complete.

If neither `{CID}` nor `--recent` is provided, show the configured recent-session source and ask the user which mode to run.

## Data Collection

Create a scratch directory:

```text
.startup/operate/investigations/<correlation-id>/
```

Fetch only through configured sources:

- session detail path/template;
- logs path/template;
- support feedback path/template;
- artifacts path/template, if configured.

Redact or summarize PII before writing any artifact outside `.startup/operate/`.

## RCA Agent

Spawn the incident investigator:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/incident-investigator.md`.
> Read `.claude/saas-startup-team.local.md` and use only the `operate:` block.
> Investigate `<correlation-id or recent list>` using the collected local artifacts.
> Write `.startup/operate/investigations/<cid>/rca.md` and `.startup/operate/investigations/<cid>/issue-body.md`.
> Include symptoms, root cause hypothesis, evidence, reproduction context, severity, and suggested regression test.
> Deduplicate against existing issues using configured repo/labels and a stable pattern key. Do not expose raw PII.

## GitHub Issue

If `--file-issue` is present:

1. Search the configured repo for an open issue with the same pattern key, correlation ID, or root-cause title.
2. If found, append a compact update comment using `--body-file`.
3. If not found, create a new issue using `--body-file`, configured labels, and the generated title.

If `--dry-run` is present, print the planned issue/comment action and do not mutate GitHub.

## Output

Report:

- investigated correlation IDs;
- artifact paths;
- dedup result;
- created/commented issue URL, or dry-run plan;
- recommended build-track command, usually `/improve` with the linked issue.
