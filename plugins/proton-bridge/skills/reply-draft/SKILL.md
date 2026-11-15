---
name: reply-draft
description: Use when asked to draft (not send) a reply to an email in a Proton Mail account reached through Proton Mail Bridge so that the draft carries its reply context - reply-all recipients, "Re:" subject and the original mail quoted under the text - in the user's Drafts folder over IMAP (the script works with any IMAP server). Also use to re-make an already written or user-edited draft that lacks the quoted original.
---

# Reply draft with the original quoted

A reply is three things: the recipients, the quoted original and the thread link. A message appended to Drafts has
none of them unless you build them. `scripts/reply-draft.py` builds the first two, stores the draft and reads it
back. It never sends.

## Steps

1. Find the parent mail's UID in the mailbox the user means (`INBOX` by default; on Proton, `All Mail` holds everything).
2. Write the reply body to a file: `.html` is used as HTML, anything else as plain text. Body only, no quote.
3. Create the draft:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reply-draft.py" --env-file <env file> --env-prefix <PREFIX> \
     --parent-box INBOX --parent-uid <uid> --body-file <file> --lang <en|et>
   ```
   Connection variables: `<PREFIX>_IMAP_HOST`, `<PREFIX>_IMAP_PORT`, `<PREFIX>_USER`, `<PREFIX>_PASSWORD` (default
   prefix `MAIL`). A local bridge with a self-signed certificate needs `--insecure`; implicit TLS needs `--tls ssl`.
4. Read the JSON it prints. `quote_in_stored_draft` must be `true` (exit code 0). Tell the user the Drafts UID, the
   recipients, and that nothing was sent.
5. The user already wrote or edited a draft that has no quote: add `--from-draft-uid <uid>`. Body, recipients and
   subject come from that draft, the quote from the parent, and the result is a NEW draft. The old one is left in
   place: say so and let the user delete it. Never delete or overwrite a draft the user touched.

`--dry-run out.eml` with `--parent-eml parent.eml` builds the message without any server.

## What IMAP cannot do on Proton Mail Bridge

Measured 2026-11-15 on Bridge 3.27.1 and read in the public source (github.com/ProtonMail/proton-bridge, `master`).

- `APPEND` to Drafts creates the draft without a parent (`internal/services/imapservice/connector.go`,
  `createDraftWithParser`: no `ParentID`). `In-Reply-To` and `References` are dropped, so Proton does not show the
  draft inside the conversation. The quote in the body is the reply context the reader gets; `reply_headers_kept`
  in the output says what the server did.
- A reply draft made in the Proton app reads back with `In-Reply-To` set to the parent's Message-ID. That is how to
  tell a linked draft from an appended one.
- Bridge stores only the HTML part of a draft.
- Only Bridge's SMTP path links a reply (`internal/services/smtp/smtp.go`, `getParentID`: parent looked up from
  `References` / `In-Reply-To`, then `ReplyAction`). So when the user explicitly tells you to SEND a reply, send it
  over SMTP with both headers set from the parent.

## Rules

- Drafting is not permission to send. This skill has no send step.
- Credentials come from the environment; never print them or put them on a command line.
- Inline images of the parent (`cid:`) are not carried into the quote.
- Scripts and `<style>` of the parent are removed from the quote; the rest of its HTML is kept as received.
