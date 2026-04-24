# emails-to-github-issues

Turn emails from named senders — support requests, bug reports, feature asks — into well-formed GitHub issues.

Pulls mail from a local Proton Mail Bridge (IMAP), strips Outlook HTML bodies, groups threaded replies into single topics, extracts inline screenshots, and files one issue per thread against a GitHub repo you nominate. Matches the target repo's existing conventions (labels, image-hosting pattern, title style) instead of inventing new ones, and always confirms scope with you before any write.

## Prerequisites

- A running local Proton Mail Bridge with IMAP on `127.0.0.1:1143` (STARTTLS). The shenxn/protonmail-bridge Docker image works out of the box.
- Python 3 (stdlib only — no third-party deps).
- `gh` CLI authenticated for the target repo.

## What it covers

- IMAP `SINCE` + `FROM` search that works around `imaplib`'s ASCII-only gotcha
- HTML-body extraction + quoted-reply trimming for Outlook mail
- Thread grouping that respects customer-side numbering conventions (`#17 - …`) over RFC `References` headers (Outlook drops these)
- Discovering target repo conventions (labels, image hosting) before writing
- Uploading inline screenshots via a dedicated GitHub release when that's the repo's pattern
- Scope confirmation via `AskUserQuestion` before any `gh issue create`

## Usage

Ask Claude Code something like:

> Read emails from Alice and Bob since Monday and create GitHub issues.

The skill auto-activates, prompts you for the bridge password, fetches and groups the mail, confirms scope with you, and files the issues.

## Contents

- `skills/emails-to-github-issues/SKILL.md` — the skill (workflow, gotchas, red-flags)
- `skills/emails-to-github-issues/fetch_mails_template.py` — runnable template; handles IMAP fetch, HTML stripping, quote trimming, thread grouping, and attachment manifest

## Project-specific facts go in project memory

Label names, your repo's image-hosting release tag, and customer ticket-numbering schemes belong in per-project memory (`~/.claude/projects/<slug>/memory/`), not in the skill itself.
