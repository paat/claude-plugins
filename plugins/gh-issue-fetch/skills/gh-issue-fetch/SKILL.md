---
name: gh-issue-fetch
description: "Use to inspect GitHub issue screenshots/images behind auth or resolve epic child task lists; use gh directly for plain text."
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
