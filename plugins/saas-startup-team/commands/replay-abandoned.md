---
name: replay-abandoned
description: Replay abandoned funnel sessions against the configured funnel definition and emit structured findings for build-track follow-up.
argument-hint: "[--band NAME] [--max N] [--dry-run] [--no-file-issues]"
allowed-tools: Bash, Read, Write, Grep, Glob, Task
user_invocable: true
---

# /replay-abandoned - Funnel Session Replay

Replay abandoned sessions with the configured funnel definition. This command is generic: it has no built-in funnel, URLs, product names, or session schema. Read everything from the `operate:` block in `.claude/saas-startup-team.local.md`.

## Configuration Requirements

The `operate:` block should provide:

- `funnel.steps` with stable step names and abandonment bands;
- a source for abandoned sessions, as a command, file, or URL/path;
- app URL or route template for browser replay;
- auth env var names when replay needs authenticated support/admin data;
- incident labels or issue template for filed findings.

If any required value is absent, stop with a clear `not configured` message.

## Flow

1. Resolve the candidate list from configured abandoned-session source.
2. Filter by `--band NAME` when provided.
3. Cap to `--max N` when provided.
4. For each candidate, create:
   ```text
   .startup/operate/replay/<timestamp>/<session-id>/
   ```
5. Spawn the session replay agent with
   `subagent_type: "saas-startup-team:session-replay"`:

   > Read `.claude/saas-startup-team.local.md` and use only configured funnel steps, app routes, auth env vars, and source paths.
   > Replay session `<session-id>` from the configured starting state to the configured abandoned step.
   > Capture desktop and mobile observations when browser tooling is available.
   > Write `finding.json` and `finding.md` to the provided output directory.
   > Classify the outcome as `no_issue`, `ux_bug`, `functional_bug`, `instrumentation_gap`, or `infra_error`.

## Finding Schema

Each `finding.json` must include:

```json
{
  "schema_version": 1,
  "session_id": "<redacted-or-configured-id>",
  "band": "<configured-band>",
  "last_step": "<configured-step>",
  "verdict": "no_issue|ux_bug|functional_bug|instrumentation_gap|infra_error",
  "pattern_key": "funnel:<stable-key>",
  "severity": "critical|high|medium|low",
  "evidence": ["relative/path/or/short-observation"],
  "summary": "one sentence",
  "recommended_fix": "smallest actionable next step"
}
```

## Issue Filing

Actionable findings (`ux_bug`, `functional_bug`, `instrumentation_gap`, `infra_error`) are filed by default — do not ask first. For each, run the shared helper (dedup + sensitive-content carve-out) with the finding's `pattern_key` in the title:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/issue-file.sh" --repo <configured repo> \
  --title "<pattern_key>: <finding summary>" --body-file <finding.md> \
  --labels "<configured incident labels>" --digest-file <current run digest, if any>
```

It comments on an existing open match instead of duplicating, and parks the finding in `docs/human-tasks.md` when it carries customer data or a secret. Skip with `--no-file-issues`; pass `--dry-run` to preview without mutating GitHub.
