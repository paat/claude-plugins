# session-preflight

SessionStart hook that runs a fast, read-only environment preflight and prints
a one-screen status block into the session context: auth checks, expected
tokens (shell env **and** known env files), required CLIs, and an identity
line (host, user, repo, branch, container marker) so the agent never acts on
wrong-host assumptions. Failures never block the session — they surface loudly
at the top so the first tool call is not wasted on a 401, a missing CLI, or a
token that was "inaccessible" while sitting in a workspace `.env` the whole
time.

## Mission fit

Dead-on-arrival sessions from credential/environment gaps are one of the most
common autonomous-loop failure classes: the session burns its first minutes
discovering an expired token or a sanitized PATH. Checking once, before the
model acts, costs zero tokens (pure shell) and converts those failures into a
visible first-line remedy.

## What it does

On SessionStart (always exit 0, ~1s, read-only):

1. **Identity line** — `host=… user=… repo=… branch=…` plus a `(container)`
   marker when `/.dockerenv` exists.
2. **Required CLIs** — each configured CLI checked on PATH. Without a
   manifest, defaults to `git jq gh`.
3. **Auth checks** — selected **by name** from a fixed built-in catalog
   (`github`, `npm`, `docker`, `gcloud`, `aws`, `codex`), each run with a 10s
   timeout. The manifest never supplies command text: a repo-local file must
   not gain arbitrary code execution at session start, and failure output
   names only the check, never a command that could embed a secret. Without a
   manifest, checks `gh auth status` when `gh` is installed.
4. **Expected tokens** — each configured variable checked in the shell
   environment first, then in configured file locations plus `.env` /
   `.env.local` in the workspace. A token found only in a file is reported as
   present-but-not-exported so the agent sources it instead of declaring it
   inaccessible.

Output shape:

```
[session-preflight] host=devbox user=abc repo=myapp branch=main (container)
[session-preflight] ATTENTION — 1 check(s) failed; fix or work around these BEFORE relying on them:
  !! auth:github FAILED (gh auth status)
[session-preflight] ok: cli:git cli:jq cli:gh token:API_KEY (env)
```

## Requirements

- bash 4+. `jq` enables the manifest and token checks (without it the hook
  degrades to identity + default CLI checks). `git`, `gh` optional.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install session-preflight@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this
  repository, via `.claude/settings.local.json`.

## Configuration (optional)

Create `.claude/preflight.json` in a project:

```json
{
  "clis": ["git", "jq", "gh", "docker", "node"],
  "auth": ["github", "npm"],
  "tokens": [
    {"env": "OPENAI_API_KEY", "files": [".env", "~/.config/openai/env"]},
    {"env": "PLANE_API_TOKEN", "files": [".env.local"]}
  ]
}
```

- `clis` — replaces the default `git jq gh` list.
- `auth` — catalog names only (`github npm docker gcloud aws codex`); an
  unknown name is reported, not executed. `{"name": "github"}` object form is
  also accepted.
- `tokens.files` — absolute, `~/`, or workspace-relative paths; `.env` and
  `.env.local` in the workspace are always checked as a fallback.

Without a manifest the hook still prints the identity line, default CLI
checks, and `gh auth status`.

## Testing

```bash
bash plugins/session-preflight/tests/run.sh
```
