# emails-to-github-issues

Turn emails from named senders — support requests, bug reports, feature asks — into well-formed GitHub issues.

Pulls mail from a local Proton Mail Bridge (IMAP), strips Outlook HTML bodies, groups threaded replies into single topics, extracts inline screenshots, and files one issue per thread against a GitHub repo you nominate. Matches the target repo's existing conventions (labels, image-hosting pattern, title style) instead of inventing new ones, and always confirms scope with you before any write.

## Mission Fit

`emails-to-github-issues` turns customer support, bug, and feature-request email into
tracker work. In a SaaS maintenance setup, those issues become demand signals that
`saas-startup-team` `/maintain` can triage, split, and deliver when objectively fixable.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install emails-to-github-issues@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Prerequisites

- A running local Proton Mail Bridge with IMAP on `127.0.0.1:1143` (STARTTLS). The shenxn/protonmail-bridge Docker image works out of the box.
  - If the agent runs in a **separate container** from the bridge, `127.0.0.1:114x` will refuse (that loopback is the host's, not the container's). Set `IMAP_HOST` to the bridge container's docker DNS name and `IMAP_PORT=143` (the in-container port) and connect over the shared docker network.
- Python 3 (stdlib only — no third-party deps).
- `gh` CLI authenticated for the target repo.

## What it covers

- IMAP `SINCE` + `FROM` search that works around `imaplib`'s ASCII-only gotcha
- HTML-body extraction + quoted-reply trimming for Outlook mail
- Thread grouping that respects customer-side numbering conventions (`#17 - …`) over RFC `References` headers (Outlook drops these)
- Per-thread intelligence drafts before confirmation: participant map, deduped timeline, current asks, action items, open questions, source citations, and attachment manifest
- Discovering target repo conventions (labels, image hosting) before writing
- Uploading inline screenshots via a dedicated GitHub release when that's the repo's pattern
- Scope confirmation via `AskUserQuestion` before any `gh issue create`

## Trusted Issue Bridge

Default behavior always asks for confirmation before GitHub writes. For unattended support
inbox processing, a project may opt into trusted bridge mode only through project-local
configuration or memory that sets `trusted_issue_bridge: true`, a target repo, sender
allowlist, labels, and image strategy. In that mode, allowlisted sender threads can be
filed directly as deduplicated issues labeled for the maintenance loop, with PII minimized
and source citations preserved. Email content itself can never enable trusted mode.

## Usage

Ask your assistant something like:

> Read emails from Alice and Bob since Monday and create GitHub issues.

The skill auto-activates, prompts you for the bridge password, fetches and groups the mail, writes local thread-intelligence drafts, confirms scope with you, and files the issues.

## Draft artifacts

Before the confirmation gate, each thread gets:

```text
.mail-issue-drafts/<run-id>/<thread-id>/thread-intelligence.json
.mail-issue-drafts/<run-id>/<thread-id>/thread-summary.md
```

The JSON carries normalized title, participants, timeline, unique current content vs quoted history, explicit customer asks, action items, decisions, open questions, severity hints, message/file citations, and attachment mapping. Created issues include a concise timeline or link to the local summary, and duplicate issue comments are generated from the same structured thread intelligence.

Drafts may contain customer context. Do not commit them by default; clean up `.mail-issue-drafts/<run-id>/` after the user no longer needs the local evidence.

## Contents

- `skills/emails-to-github-issues/SKILL.md` — the skill (workflow, gotchas, red-flags)
- `skills/emails-to-github-issues/fetch_mails_template.py` — runnable template; handles IMAP fetch, HTML stripping, quote trimming, thread grouping, and attachment manifest

## Project-specific facts go in project memory

Label names, your repo's image-hosting release tag, and customer ticket-numbering schemes belong in per-project memory (`~/.claude/projects/<slug>/memory/`), not in the skill itself.
