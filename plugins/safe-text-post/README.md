# safe-text-post

File-based text posting with unicode lint and read-back verification. Kills
the empty-comment / corrupted-PR-body failure class: curly quotes terminating
inline string literals, zero-width characters silently corrupting JSON,
ARG_MAX truncation, and shell-quoting damage to multi-line `--body` strings —
all of which read as success until someone opens the tracker.

## Mission fit

The largest recorded mechanical-friction class in autonomous delivery is text
that posts empty or corrupted. Every occurrence costs a detect–delete–repost
loop, or worse, ships a broken customer-facing artifact. The reliable shape is
always the same: write the payload to a file, post from the file, fetch it
back, compare. This plugin makes that shape one command.

## What it provides

- **`skills/safe-text-post`** — the posting discipline: file-based always,
  lint before posting, read-back before reporting done, top-level-await
  browser JS convention, and the manual pattern for non-GitHub REST targets.
- **`scripts/safe-post.sh`** — the GitHub helper:
  - `lint <file>` — rejects empty/whitespace-only payloads and invisible
    zero-width characters (exit 4). Curly quotes and non-ASCII letters are
    legitimate content — the round-trip proves they survive.
  - `post --via issue-comment|issue-body|pr-body --repo O/R --number N
    --file F` — lints, posts via `gh api -F body=@file` (request body, never
    argv — ARG_MAX-safe by construction), then fetches the stored content and
    byte-compares it to the file (insensitive only to trailing newlines at
    EOF, which targets commonly canonicalize). Exit 6 means the stored content differs:
    treat the post as corrupted, delete and repost.
  - `verify` — standalone read-back comparison for content posted by other
    means (e.g. `gh pr create --body-file`).

## Requirements

- bash 4+, `gh` (authenticated), GNU `grep` (`-P` for the zero-width
  lint; without it the lint degrades to the empty-payload check).

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install safe-text-post@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this
  repository, via `.claude/settings.local.json`.

## Testing

```bash
bash plugins/safe-text-post/tests/run.sh
```
