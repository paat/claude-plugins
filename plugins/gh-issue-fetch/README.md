# gh-issue-fetch

Download auth-gated GitHub issue images locally and resolve epic task-lists — so Claude can read issue screenshots and reason about epic progress.

GitHub `user-attachments` image URLs return 404 without a valid auth token; this plugin downloads them into a local directory with relative links so Claude can open them. For epics (parent issues containing a `- [ ] #NNN` checklist), it resolves each child's real state and rolls up progress.

**Read-only toward GitHub** — it never writes to GitHub, creates issues, or leaves comments.

## Dependencies

- `gh` CLI, authenticated with `repo` scope (`gh auth login`).
- `jq` — JSON parsing.
- `curl` — authenticated image download.
- `file` — MIME-type sniffing (used when the server omits `Content-Type`).

## Usage

### `issue` — fetch an issue with its images

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" issue <n> \
  [-R owner/repo] [--no-images] [--max-assets N] [--max-bytes BYTES] [--strict]
```

Downloads the issue body + comments, rewrites image URLs to relative paths, and saves everything under `/tmp/gh-issue-<owner>-<repo>-<n>/`.

### `epic` — resolve an epic's child task-list

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" epic <n> \
  [-R owner/repo] [--with-images] [--strict]
```

Fetches the parent issue, resolves every `- [ ] #NNN` / `- [x] #NNN` child to its real GitHub state, and writes a roll-up table (checkbox progress + real-state progress) to `issue.md`.

### `epics` — list all epics with progress

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" epics \
  [-R owner/repo] [--label epic]
```

Lists open issues that carry the epic label and prints a one-line progress summary (`#N  done/total  Title`) for each.

### Flags

| Flag | Default | Description |
|---|---|---|
| `-R owner/repo` | current repo remote | Target repository |
| `--no-images` | off | Skip image download (issue text only) |
| `--with-images` | off | Also download images when running `epic` |
| `--max-assets N` | 50 | Cap on assets to download per issue |
| `--max-bytes BYTES` | 52428800 | Per-asset size cap (bytes) |
| `--strict` | off | Exit non-zero if any asset fails to download |
| `--label L` | `epic` | Label filter for `epics` subcommand |

### Output layout

```
/tmp/gh-issue-<owner>-<repo>-<n>/
  issue.md        — issue body + comments, image URLs rewritten to relative paths
  assets/
    001.<ext>     — first downloaded image (extension from MIME sniff)
    002.<ext>     — second, etc.
  manifest.json   — metadata for each asset (URL, status, bytes, MIME type)
```

If an image fails to download, `issue.md` marks it inline and `manifest.json` records the failure; the script exits 0 by default (use `--strict` to make failures fatal).

### Example

```bash
# Fetch issue #42 with images
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" issue 42 -R owner/repo

# Then read the output directory printed as OUTDIR=...
```

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install gh-issue-fetch@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.
