---
name: emails-to-github-issues
description: Use when asked to turn emails from named senders (support requests, bug reports, feature asks) into GitHub issues — covers IMAP fetch via Proton Bridge, HTML-body extraction, thread grouping, screenshot handling, and scope-confirmation before writes.
---

# Emails to GitHub Issues

## Overview

Pull emails from one or more senders out of Proton Bridge, group them into coherent topics, and file them as GitHub issues with screenshots attached.

**Core principle:** *match the target repo's existing conventions before inventing new ones, and confirm scope + image strategy with the user before any GitHub write.* Issue creation is visible to others and hard to clean up quietly.

## When to Use

- User says "read mail from X since <date>" and asks for issues/tickets filed
- Customer reports arriving via email that should become tracker items
- Senders have their own numbering convention (e.g., `#17 - …`) you should preserve

Do **not** use for internal FYI mail or for mail the user only wants summarized in chat.

## Workflow

1. **Discover repo conventions.** `git remote -v`; read 2–3 recent customer-reported issues (`gh issue list -R <repo> --label customer-reported --limit 5` + `gh api repos/<repo>/issues/<N> --jq .body`) to learn label names, title/body style, and — critically — **how images are hosted** (dedicated release tag, user-attachments CDN, committed files).
2. **Ask user for `BRIDGE_PASS`.** Never try to read the encrypted Proton Bridge vault. Connect to `127.0.0.1:1143` STARTTLS (primary bridge; 1144 is aruannik, a different account).
3. **Fetch.** Adapt `fetch_mails_template.py`: set `SENDER_TOKENS` to ASCII address substrings, `SINCE` to `dd-Mon-yyyy`. Use `readonly=True`.
4. **Extract bodies.** Prefer `text/plain`; strip HTML when absent (Outlook is HTML-only). Trim quoted replies (`From:`/`Saatja:`/`On … wrote:`/leading `>`). Template does this.
5. **Group into threads** in this priority: (a) customer's own `#NN` numbering; (b) normalized subject minus `Re:/RE:/Fwd:/VS:`; (c) RFC `References`/`In-Reply-To` only if both fail — Outlook drops these.
6. **Pull context** for third parties mentioned in bodies (consultants, external stakeholders). A second IMAP pass over the last few weeks often yields a prior thread worth splicing into the issue body.
7. **Confirm with `AskUserQuestion`** before any write: scope (which threads to file), image strategy (matches repo convention?). Never skip this gate.
8. **Upload screenshots** using the pattern from step 1. Common ones:
   - Dedicated release: `gh release upload <tag> *.png -R <repo> --clobber`, embed `![](…/releases/download/<tag>/<file>)`.
   - user-attachments CDN: save locally, tell user to drag-drop (no API).
   - Never commit PNGs to `main` unless that's the established pattern.
9. **Create issues** via `gh issue create --body-file` (never `--body` — shell quoting mangles non-ASCII). One issue per thread. Dedupe first: `gh issue list --search "in:title <normalized>"`.

## Gotchas

| Gotcha | Fix |
|---|---|
| `imaplib.search` raises `UnicodeEncodeError` on non-ASCII senders ("Mäsak") | Search by ASCII substring of the email address (`masak`), not display name |
| IMAP `SINCE` is server internal date, not `Date:` header | Accept ~1d drift or post-filter on parsed `Date` |
| Outlook `text/plain` part is often empty | Strip HTML; stdlib `html.parser` is enough, no BeautifulSoup needed |
| Inline images may have `Content-Disposition: inline` (no "attachment") and no filename | Filter on `ctype.startswith("image/")` + non-empty `get_payload(decode=True)` |
| `gh issue create --body "…"` mangles Estonian/Cyrillic chars | Use `--body-file` |
| Customer's `#NN` is their ticket ID, not GitHub's — keep it verbatim in the title | Don't try to align to GitHub issue numbering |

## Red Flags — STOP

- About to `gh issue create` without running `AskUserQuestion` on scope → confirm first
- About to invent a new image-hosting scheme → check existing issues' body URLs first
- About to commit customer screenshots to `main` → look for a release tag or user-attachments pattern instead
- About to loop over emails and create one issue each → group by thread first

## Template

See `fetch_mails_template.py` in this directory — ready to adapt. Handles IMAP connect, `SINCE`+`FROM` search, HTML-strip body extraction, quote trimming, thread grouping, and attachment extraction with a per-thread manifest. Set `BRIDGE_PASS`, edit the CONFIG block, run.

## Where project-specific facts belong

Label names, the repo's image-hosting release tag, and the customer's ticket-numbering scheme are repo-specific — store them in project memory (in the repo's memory directory), not in this skill.
