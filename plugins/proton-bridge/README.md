# proton-bridge

Proton Mail Bridge skills: what an agent needs to work with a Proton Mail
account through the Bridge's local IMAP and SMTP ports. Skills for the same
bridge belong here.

## Skills

- **`reply-draft`** (`proton-bridge:reply-draft`) — creates a reply draft that
  carries its reply context: reply-all recipients, a "Re:" subject and the
  original mail quoted under the text. The draft is stored in Drafts and read
  back. It never sends.
- **`emails-to-github-issues`** (`proton-bridge:emails-to-github-issues`) —
  fetches mail from named senders, groups threads into topics and files one
  deduplicated GitHub issue per thread, with inline screenshots. It confirms
  scope before any GitHub write.

## Mission fit

An agent that appends a bare message to Drafts leaves the human to rebuild the
recipients and paste the original by hand, or to send a reply with no context.
One command builds the reply the way a mail client would, so the human only
reads, edits and sends.

Customer support, bug and feature-request mail becomes tracker work: issues a
maintenance loop can triage and deliver.

## What it provides

- **`skills/reply-draft`** — when and how to draft a reply, how to re-make a
  draft the user already edited, and what IMAP cannot do on Proton Mail Bridge.
- **`scripts/reply-draft.py`** — builds and stores the draft:
  - parent by `--parent-uid`, `--parent-message-id` or a local `--parent-eml`;
  - body from `--body-file` (`.html`/`.htm` as HTML, anything else as plain
    text) or from an existing draft with `--from-draft-uid`;
  - `To` is the parent's `Reply-To` or `From`; `Cc` is the parent's `To` and
    `Cc` without your own addresses (`--me` adds more of yours;
    `--no-reply-all` drops `Cc`);
  - the quote keeps the parent's HTML without its scripts and styles;
  - prints one JSON object; exit code 0 only when the stored draft was read
    back with the quote in it.
- **`skills/emails-to-github-issues`** — the workflow, gotchas and red flags
  for filing mail as issues:
  - a persisted cursor, so an unattended run with no new mail exits before any
    repo discovery or GitHub call;
  - HTML-body extraction and quoted-reply trimming for Outlook mail;
  - thread grouping that prefers customer-side numbering (`#17 - …`) over
    `References` headers, which Outlook drops;
  - per-thread drafts written before confirmation to
    `.mail-issue-drafts/<run-id>/<thread-id>/` (`thread-intelligence.json`,
    `thread-summary.md`). They may hold customer context: do not commit them;
  - the target repo's own labels and image-hosting pattern, discovered before
    writing.
- **`skills/emails-to-github-issues/fetch_mails_template.py`** — a template to
  adapt: IMAP fetch, HTML stripping, quote trimming, thread grouping and the
  attachment manifest.

## Requirements

- python3 3.8+, standard library only.
- Proton Mail Bridge running and signed in; the script itself works with any
  IMAP account. Connection comes from the environment:
  `MAIL_IMAP_HOST`, `MAIL_IMAP_PORT`, `MAIL_USER`, `MAIL_PASSWORD`
  (`--env-prefix` changes the `MAIL` prefix, `--env-file` loads `KEY=VALUE` lines).
- `emails-to-github-issues` also needs the `gh` CLI authenticated for the
  target repo. Its fetch template reads `IMAP_USER`, `BRIDGE_PASS` and
  `IMAP_PORT` (default `1143`, STARTTLS); its docstring covers an agent that
  runs in a different container from the bridge.

## Usage

```bash
python3 scripts/reply-draft.py --env-file mail.env --parent-uid 123 --body-file body.txt
python3 scripts/reply-draft.py --env-file mail.env --parent-uid 123 --from-draft-uid 45
python3 scripts/reply-draft.py --parent-eml parent.eml --body-file body.html --dry-run out.eml
```

STARTTLS is the default; `--tls ssl` uses implicit TLS and `--insecure` accepts
a local bridge's self-signed certificate. The last form needs no server.

To file mail as issues, ask for it:

> Read emails from Alice and Bob since Monday and create GitHub issues.

## Trusted issue bridge

`emails-to-github-issues` asks before every GitHub write. A project can opt
into unattended filing only through project-local configuration or memory that
sets `trusted_issue_bridge: true` with a target repo, sender allowlist, labels
and image strategy. Mail content can never enable it.

Label names, the image-hosting release tag and customer numbering schemes
belong in project memory, not in the skill.

## Proton Mail Bridge limitation

Bridge creates an appended draft without a parent and drops `In-Reply-To` and
`References`, so Proton does not show the draft inside the conversation; the
quote in the body is the reply context the reader gets. Bridge stores only the
HTML part of a draft. Only its SMTP send path links a reply to the thread.
Details and sources are in the skill.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install proton-bridge@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this
  repository, via `.claude/settings.local.json`.

## Testing

```bash
bash plugins/proton-bridge/tests/run.sh
```

Offline only: every case uses `--parent-eml` with `--dry-run`.
