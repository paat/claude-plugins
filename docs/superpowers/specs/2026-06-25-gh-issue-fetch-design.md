# gh-issue-fetch — design

**Date:** 2026-06-25
**Status:** approved for planning

## Problem

In a Claude Code dev container, Claude cannot see images attached to GitHub
issues. GitHub serves issue/comment attachments from
`https://github.com/user-attachments/assets/<uuid>`. These URLs return **404 to
any unauthenticated client** — verified live: plain `curl`/WebFetch → `404`.
With the gh CLI token they download fine:

```
curl -L -H "Authorization: token $(gh auth token)" <url>   # → 200, real PNG
```

The token already carries `repo` scope. So Claude has the text of an issue (via
`gh issue view`) but is blind to every screenshot, which is often where the
actual bug repro lives.

A secondary gap: the project models **epics as a parent issue (label `epic`)
whose body holds a `- [ ] #NNN` task-list of child issues**. Plain `gh` lists
such an issue but will not traverse the checklist or roll up child progress.

## Goal

A generic, project-agnostic Claude Code plugin (repo rule: **no hardcoded
project names / labels / paths** — everything that varies is a flag with a
sensible default). One bash script + a SKILL.md.

The plugin's unique value — the things plain `gh` cannot do well:

1. **Materialize auth-gated issue/comment images to local disk** so Claude can
   `Read` them, with the issue text rewritten to point at the local files.
2. **Resolve an epic** (parent issue with a `- [ ] #NNN` task-list) into a child
   table + progress roll-up.

Plain listing and search are **intentionally not wrapped**. The SKILL.md tells
Claude to use `gh issue list` / `gh search issues` directly for ordinary text
work. This plugin is for "I need the screenshots on disk" or "resolve the epic
tree" — nothing else.

## Form factor

```
plugins/gh-issue-fetch/
  .claude-plugin/plugin.json
  README.md                         # incl. standard 3-scope Installation section
  scripts/gh-issue-fetch.sh         # the workhorse
  skills/gh-issue-fetch/SKILL.md    # when/how Claude uses it
```

Pure `bash` + `gh` + `curl` + `jq` (all present in the container; documented in
README). `set -euo pipefail`, all variables quoted, no `eval`, no execution of
anything derived from issue content.

Version bumped in **both** `plugin.json` and the root `marketplace.json` (repo
rule), enforced by the pre-push hook.

## Subcommands

### `gh-issue-fetch.sh issue <n> [-R owner/repo] [--no-images] [--max-assets N] [--max-bytes BYTES]`

1. Fetch metadata + body via `gh issue view <n> -R <repo> --json
   number,title,state,author,labels,body,url`.
2. Fetch **all** comments via `gh api --paginate
   repos/<owner>/<repo>/issues/<n>/comments` (pagination matters — `gh issue
   view --json comments` can truncate).
3. Scrape every attachment URL from body + each comment. Handle these forms:
   - `![alt](<url>)` and `![alt](<url> "title")`
   - `<img ... src="<url>">` / `src='<url>'` (attributes in any order)
   - bare `https://github.com/user-attachments/assets/<uuid>`
   - `*.githubusercontent.com/...`
   - URLs in angle brackets, with query strings, percent-encoded.
   Dedupe identical URLs across body/comments.
4. Download each (unless `--no-images`) with
   `curl -L -H "Authorization: token $(gh auth token)"` into `assets/`.
   - **Auth-on-redirect is safe by curl default:** the token goes to the
     `github.com` first hop only; curl drops the `Authorization` header on the
     cross-host 302 to the signed S3 URL (auth is in the `X-Amz-Signature` query
     string). **Do not use `--location-trusted`.** The signed URL expires in
     ~300s, so download promptly.
   - **Filenames are sequential** (`001`, `002`, …) — never derived from
     attacker-controllable URL text (no path traversal). Extension is decided by
     **sniffing the downloaded bytes** (`file --mime-type`), not by trusting the
     URL or the `Content-Type` header.
   - Enforce `--max-bytes` per asset (default e.g. 50 MB) and `--max-assets`
     (default e.g. 50); log anything skipped — no silent truncation.
   - Verify each download is a regular file and non-empty.
5. Write **`issue.md`**: title/meta header, body, then comments — with every
   downloaded URL replaced (exact-string, manifest-driven) by its **relative**
   local path (`assets/001.png`), so the file stays movable and Claude-readable.
   Failed/skipped assets are left as the original URL with a `<!-- download
   failed: HTTP nnn -->` marker beside them.
6. Write **`manifest.json`**:

   ```json
   {
     "repo": "owner/repo",
     "issue": 123,
     "assets": [
       { "url": "...", "local_path": "assets/001.png", "http_status": 200,
         "content_type": "image/png", "bytes": 56376, "sha256": "...",
         "source": "body" | "comment:<id>" }
     ]
   }
   ```
7. Print the output dir + a human-readable manifest (per-asset HTTP status).

### `gh-issue-fetch.sh epic <n> [-R owner/repo] [--with-images]`

- Produce `issue.md` for the epic itself (as above).
- Parse the body task-list (`- [ ] #NNN` / `- [x] #NNN`). For each child resolve
  actual state via `gh issue view <child> --json state,title,labels`.
- Emit a child table with **both** signals — the epic's checkbox state *and* the
  child issue's real open/closed state (they can disagree).
- Roll-up: progress bar uses **checkbox state** (reflects the parent task list);
  also report `closed/total` from real child states.
- `--with-images` also runs the `issue` image-download flow for each child.

### `gh-issue-fetch.sh epics [-R owner/repo] [--label L]`

- `--label` default `epic` (configurable — no project name baked in).
- List every issue with that label, each with `done/total` task-list progress.

## Conventions

- `-R owner/repo` defaults to the current directory's git remote.
- Output dir: `/tmp/gh-issue-<owner>-<repo>-<n>/` (owner/repo sanitized to
  `[A-Za-z0-9._-]`), containing `issue.md`, `assets/`, `manifest.json`.
- **Read-only** — never writes to GitHub. No confirmation gate needed.
- Exit non-zero only on **hard** failures (missing `gh`/`jq`/`curl`, bad repo,
  bad issue number, issue JSON unfetchable). Partial asset failures exit `0`
  with failures recorded in the manifest; `--strict` flips that to non-zero.

## Error handling / edge cases (from codex review)

- Token missing/expired → clear error, exit non-zero.
- GitHub Enterprise host mismatch (`gh` host ≠ `github.com`) → document as a
  known limitation; v1 targets `github.com`.
- Comment pagination handled via `--paginate`.
- Epic with no task-list → empty child table, not an error.
- Same URL repeated → downloaded once, all occurrences rewritten.

## Testing

- Unit-ish: a fixture issue body string with each URL form → assert the scraper
  finds exactly the expected set and the rewrite is exact-string.
- Live smoke (manual, documented): run `issue <n>` against a known issue with an
  attachment, assert `assets/001.*` is a real image (`file` says image) and
  `issue.md` links to it relatively.
- `epic`/`epics` against a known epic: assert child table + roll-up counts.

## Out of scope (YAGNI)

- Wrapping `gh issue list` / `gh search` (SKILL.md defers to gh).
- GitHub-native sub-issues API (project uses checklist convention).
- Writing/uploading to GitHub.
- GitHub Enterprise hosts.
