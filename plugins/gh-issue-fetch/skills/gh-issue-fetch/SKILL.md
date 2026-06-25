---
name: gh-issue-fetch
description: Use when you need to SEE images/screenshots attached to a GitHub issue (they are auth-gated and 404 for normal fetches), or to resolve an epic's child task-list with progress. Triggers on "look at issue #N", "the issue has a screenshot", "what's left in epic #N". For plain issue text/listing/search, use `gh` directly instead.
---

# gh-issue-fetch

## When to use
- An issue references a screenshot you cannot open (GitHub `user-attachments` URLs 404 without auth).
- You need an epic (parent issue with a `- [ ] #NNN` checklist) resolved into child states + progress.

## When NOT to use
- Plain issue text, listing, or search — use `gh issue view`, `gh issue list`, `gh search issues` directly. This plugin deliberately does not wrap them.

## Usage
Run the script (it is read-only toward GitHub):

    "${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" issue <n> -R owner/repo
    "${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" epic  <n> -R owner/repo [--with-images]
    "${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" epics      -R owner/repo [--label epic]

`-R` defaults to the current repo's remote. It prints `OUTDIR=<dir>`; then **Read** `<dir>/issue.md` and the images under `<dir>/assets/`.

## Notes
- Images download with the gh token; failures are recorded in `manifest.json` and marked inline in `issue.md` — check there if an image is missing.
- Project-specific facts (e.g. a non-default epic label) belong in the repo's project memory, passed via `--label`, not hardcoded here.
