# irreversible-guard

A `PreToolUse` gate that blocks Bash commands with **no practical local undo** before they run.
Agents occasionally execute genuinely catastrophic, irreversible operations — "prompts are not
permissions." A `DO-NOT` line in a rules file does not bind a long-context agent; enforcement has to
live in a hook. This plugin is that hook, scoped **deliberately to irreversible blast-radius only** —
reversible risk is left alone, so it is not friction you disable by Thursday.

## Mission Fit

`irreversible-guard` is safety infrastructure. It protects autonomous SaaS delivery loops
from catastrophic shell actions while leaving reversible local work unblocked.

## What it does

On every `Bash` tool call it de-obfuscates the command — unwrapping heredocs, splitting on
`&&`/`||`/`;`/`|`, stripping `VAR=value` prefixes, and **recursing through transport wrappers**
(`ssh host '…'`, `docker exec <ctr> …`, `docker compose … exec`, `bash -c`, `eval`) — then matches
each resulting sub-command against a tiered deny-set:

- **Tier 1 — blocked always** (irreversible in every environment): `rm -rf` of protected roots
  (`/`, `~`/`$HOME`, the repo root, `/opt`,`/srv`,`/data`,`/var/lib`, `..`-escapes,
  `--no-preserve-root`); `dd of=/dev/…`, `mkfs`, `wipefs`; `terraform/tofu destroy`; cloud volume/DB
  delete verbs (`fly volumes destroy`, `railway volume delete`, `aws s3 rb`, `aws ec2 delete-volume`,
  `aws rds delete-db-instance`, `gcloud sql instances delete`, `gcloud compute disks delete`,
  `heroku pg:reset`, `kubectl delete namespace|pv|pvc`).
- **Tier 2 — blocked only when the command names production** (catastrophic against prod, routine
  and reversible locally): `DROP TABLE`/`DROP DATABASE`/`TRUNCATE`/`dotnet ef database drop` via a DB
  client; `docker compose down -v`, `docker volume rm|prune`. The "prod marker" is explicit in the
  command — a transport host/container/compose-file/connection string matching `*prod*`,
  `*production*`, or `*-live` (configurable). No prod marker → treated as local & reversible → allowed.
- **Warn (non-blocking)**: `git push --force`/`--force-with-lease`, `git reset --hard`,
  `git clean -fdx` — recoverable, so they proceed with a caution note.
- **Footgun signatures** — known self-inflicted failure shapes, caught before execution:
  - `pkill -f <pattern>` whose pattern also matches this shell's own command line (the classic
    exit-143 self-kill) → **blocked**, with the `pgrep`-first / `'[w]orker.py'` self-excluding fix
    suggested. A self-excluding pattern passes. `pkill`/`killall` of the agent's own runtime by
    name (`bash`, `node`, `claude`, `codex`, …) is blocked too.
  - Heredoc bodies containing curly quotes that feed an interpreter or poster (`python`, `node`,
    `gh`, `curl`, DB clients) → **warn**, suggesting a file-based payload. Writing the same text
    into a plain file is fine and stays silent. Invisible zero-width characters anywhere in a
    command always warn.
  - `gh pr|issue create/comment/edit` with a multi-line or >1 KB inline `--body` → **warn**,
    suggesting `--body-file`.
  - The signature list is data-driven: `rules/footgun-signatures.json` ships the detector switches
    plus a `regex` list (`{id, pattern, action: block|warn, message}`), and new lessons append new
    signatures without code changes.

Outcomes: **BLOCK** → the tool call is denied (exit 2) and the reason is fed back to the agent so it
self-corrects; **WARN** → a caution is added to context and the call proceeds; **PASS** → silent.

## Requirements

- **python3** (stdlib only — no pip packages). If python3 is absent the guard **fails open** (allows
  the command) rather than bricking every Bash call.
- bash 4+.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install irreversible-guard@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — committed to the repo and
  shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this repository, via
  `.claude/settings.local.json`.

## Configuration (optional)

Create `.claude/irreversible-guard.json` in a project to tune behavior:

```json
{
  "allow":        ["rm -rf /var/lib/myapp/scratch", "/terraform\\s+destroy.*-target=module.dev/"],
  "extra_block":  ["\\bnpm\\s+publish\\b"],
  "prod_markers": ["*prod*", "*production*", "*-live", "my-prod-host"],
  "warn_only":    ["terraform destroy"]
}
```

- **`allow`** (highest precedence) — patterns never blocked; your escape hatch for a false positive.
  A value wrapped in `/…/` is a regex; otherwise it is a substring match.
- **`extra_block`** — additional always-block (Tier 1) regex patterns, e.g. project-specific cloud
  delete verbs.
- **`prod_markers`** — substrings (leading/trailing `*` are ignored) that mark a Tier-2 op as
  production-bound. Overrides the defaults.
- **`warn_only`** — downgrade a would-be block to a warning.
- **`footgun_regex`** — additional footgun signatures, same shape as the entries in
  `rules/footgun-signatures.json`.
- **`footgun_disable`** — built-in detector ids to switch off (`self_kill`, `heredoc_hazards`,
  `inline_body`). `allow` patterns also override footgun blocks.

Defaults live as data in `rules/deny-set.json` and can be edited directly when vendoring the plugin.
`deny-set.json` **replaces** the loader's built-in fallback category-by-category (it is not merged),
so when editing it keep every category complete — a category you drop reverts to the minimal
in-code fallback, not to the shipped default. The in-code `DEFAULT_RULES` is only that fallback
(used when `deny-set.json` is missing/unreadable); it is intentionally minimal, not a copy of the
full set.

## Testing

```bash
cd plugins/irreversible-guard
python3 -m unittest discover -s tests -v   # unit tests (matcher + rules schema)
bash tests/run.sh                          # integration: real exit codes through the hook
```
