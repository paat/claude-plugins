---
name: monitor
description: On-demand post-launch monitor using the shared monitor and operate config blocks. Produces an interactive operations report without duplicating /monitor-nightly.
argument-hint: "[sessions|payments|health|costs|traffic|funnel|support|all] [--minutes=N] [--days=N] [--dry-run] [--file-issues]"
allowed-tools: Bash, Read, Write, Grep, Glob
user_invocable: true
---

# /monitor - On-Demand Operations Report

Run an interactive monitor pass for a live SaaS product. This command is the on-demand sibling of `/monitor-nightly`: reuse the same `monitor:` block and `scripts/monitor-dedup.sh` engine for failure markers and custom checks, and read additional live-product sources from the `operate:` block.

## Configuration

Read `.claude/saas-startup-team.local.md`.

- `monitor:` owns recurring failure dedup, marker files, labels, and custom checks.
- `operate:` owns API base URLs, auth env var names, funnel steps, log sources, analytics sources, support source, and incident conventions.

Do not introduce `.startup/operate.yml`.

## Sections

Supported sections:

- `sessions` - configured session/log source.
- `payments` - configured payment or billing source.
- `health` - configured health checks plus `/monitor-nightly --dry-run` marker/custom-check pass.
- `costs` - configured usage/cost source.
- `traffic` - configured analytics source.
- `funnel` - configured `operate.funnel.steps` abandonment report.
- `support` - configured support feedback source.
- `all` - every configured section.

If a section is requested but the matching source is not configured, report it as `not configured` and continue with the other requested sections.

## Source Contract

For every `operate.log_sources`, `operate.analytics_sources`, or `operate.support_api` entry, use only configured commands, URLs, headers, and env var names. Accept either:

- a local command that prints JSON or text to stdout;
- an HTTP URL/path joined to the configured API base URL;
- a local file path.

Every HTTP call must use a timeout and must read secrets from the configured env var names.

## Report

Write a report to:

```text
docs/operate/monitor-YYYY-MM-DD-HHMM.md
```

Include:

- command arguments and time window;
- each requested section with source, status, and high-signal findings;
- funnel drop-off table using configured step names and abandonment bands;
- links to local artifacts under `.startup/operate/monitor/` when raw evidence is large or sensitive;
- recommended next action: `/investigate`, `/replay-abandoned`, `/improve`, `support`, or no action.

## Issue Filing

Default is read/report-only.

If `--file-issues` is present, use the existing `scripts/monitor-dedup.sh` commit path and the configured `monitor:` labels. If `--dry-run` is present, preview the dedup actions without creating or commenting on GitHub issues.

Never call `gh` directly from this command; the monitor engine owns GitHub I/O.
