---
name: investigate
description: Investigate a live incident by correlation ID or recent sessions, create a redacted RCA artifact, and file or update a deduplicated GitHub issue when requested.
argument-hint: "{CID | --recent N} [--dry-run] [--no-file-issues]"
allowed-tools: Bash, Read, Write, Grep, Glob, Task
user_invocable: true
---

# /investigate - Incident RCA

Investigate a live incident using a correlation ID or a recent-session sweep. All endpoints, auth headers, labels, issue templates, and response shapes come from the `operate:` block in `.claude/saas-startup-team.local.md`.

## Inputs

- `{CID}` - a full correlation/session/customer-visible incident ID.
- `--recent N` - inspect the N most recent configured sessions and choose the highest-signal candidates.
- `--dry-run` - write artifacts and show the issue body without creating/updating GitHub.
- `--no-file-issues` - skip the GitHub filing step (artifact-only).

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

Spawn the incident investigator with
`subagent_type: "saas-startup-team:incident-investigator"`:

> Read `.claude/saas-startup-team.local.md` and use only the `operate:` block.
> Investigate `<correlation-id or recent list>` using the collected local artifacts.
> Write `.startup/operate/investigations/<cid>/rca.md` and `.startup/operate/investigations/<cid>/issue-body.md`.
> Include symptoms, root cause hypothesis, evidence, reproduction context, severity, and suggested regression test.
> Deduplicate against existing issues using configured repo/labels and a stable pattern key. Do not expose raw PII.

## GitHub Issue

File by default — do not ask "shall I file it?". Once the RCA artifact exists, run the shared helper (it searches, dedups, and applies the sensitive-content carve-out):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/issue-file.sh" --repo <configured repo> \
  --title "<root-cause title>" --body-file .startup/operate/investigations/<cid>/issue-body.md \
  --labels "<configured labels>" --digest-file <current run digest, if any>
```

The helper comments on an existing open match instead of creating a duplicate, and parks the defect in `docs/human-tasks.md` (exit 3) when the draft carries customer data or a secret. Skip filing with `--no-file-issues`; pass `--dry-run` through to preview without mutating GitHub.

## Output

Report:

- investigated correlation IDs;
- artifact paths;
- dedup result;
- created/commented issue URL, or dry-run plan;
- recommended build-track command, usually `/improve` with the linked issue.
