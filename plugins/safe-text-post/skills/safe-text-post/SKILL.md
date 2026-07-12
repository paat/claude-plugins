---
name: safe-text-post
description: Use when posting any multi-line, non-ASCII, or user-facing text to an external system — GitHub issue/PR bodies and comments, tracker comments, JSON payloads, browser-injected JS — or when a posted comment came back empty or corrupted. File-based payloads, unicode lint, and read-back verification.
---

# Safe text posting

Inline text payloads fail silently: curly quotes terminate Python/shell string
literals, zero-width characters corrupt JSON invisibly, ARG_MAX truncates
large argv, and shell quoting mangles multi-line `--body` strings — producing
empty tracker comments and corrupted PR bodies that read as success. The fix
is always the same shape: **file, post from file, read back, compare**.

## The rules

1. **File-based, always.** Write the payload with the Write tool, then post by
   file reference. Never inline multi-line or non-ASCII text into `python -c`,
   heredocs feeding interpreters, or `--body "..."` arguments.
2. **Lint before posting.** Reject invisible zero-width characters and empty
   payloads before they leave the machine.
3. **ARG_MAX by construction.** File-based posting keeps payloads out of argv;
   never expand a payload into a command line (inline >128KB fails outright).
4. **Read back and compare.** After posting, fetch the stored content and
   byte-compare it to the source file before reporting done. An unverified
   post is not done.
5. **Browser JS:** top-level `await` with a captured variable, never an async
   IIFE (it returns an unresolved Promise and you read `undefined`).

## GitHub targets

Use the bundled helper — it lints, posts via `gh api` with `-F body=@file`
(request body, not argv), and verifies the stored content:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/safe-post.sh" post \
  --via issue-comment --repo OWNER/REPO --number 42 --file /tmp/payload.md
bash "${CLAUDE_PLUGIN_ROOT}/scripts/safe-post.sh" post --via pr-body    --repo OWNER/REPO --number 7 --file /tmp/body.md
bash "${CLAUDE_PLUGIN_ROOT}/scripts/safe-post.sh" post --via issue-body --repo OWNER/REPO --number 42 --file /tmp/body.md
```

A PR comment is an issue comment (use `issue-comment` with the PR number).
Exit 4 = lint hazard (fix the payload), 5 = post failed, 6 = **verification
failed: the stored content differs — delete and repost, do not report done**.
For `gh pr create`/`gh issue create`, use `--body-file` and then
`safe-post.sh verify --via pr-body …` on the result.

## Other targets (Plane, Kimai, any REST tracker)

Same pattern by hand: write the file; send it as the request body
(`curl --data-binary @file` or the API's file form); GET the resource back;
`diff` the stored text against the file. Only a matching read-back is done.
