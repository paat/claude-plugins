# Provider Policy

## Panel selection and risk tiers

By default the tribunal selects **3 distinct available reviewer legs** (`TRIBUNAL_PANEL_SIZE`,
default `3`, range `2..8`) for the PR risk tier (`TRIBUNAL_RISK`: `T1`–`T4`; unset uses `T2`)
from `scripts/review-panel.tsv` (override with `TRIBUNAL_REVIEW_PANEL=<file>`, environment only).
Rows are ranked in preference order (`tier<TAB>provider<TAB>model<TAB>effort`, where `-` passes no
effort); only Codex reaches `xhigh` at `T4` because maximum-effort reviewers over-report.

- `TRIBUNAL_<PROVIDER>=on` forces that leg into the panel (all forced legs run even if they exceed
  `TRIBUNAL_PANEL_SIZE`).
- `TRIBUNAL_<PROVIDER>=off` excludes that leg from selection.
- Explicit `TRIBUNAL_<PROVIDER>_MODEL` and `TRIBUNAL_<PROVIDER>_EFFORT` settings always override
  the table row.
- Remaining available rows in table order become the automatic backup order unless the operator
  sets `TRIBUNAL_BACKUP_LEGS`.

## Providers

- Codex (`codex` CLI): repo-walking with unrestricted execution inside the development-container
  security boundary; the review prompt prohibits changes.
- OpenCode (`opencode` v2+ CLI on OpenCode Go): repo-walking via
  `opencode run --standalone --format json --agent plan -m "opencode-go/<model>[#<effort>]"`
  (`--agent plan` denies edit tools); OpenCode v1 is refused.
- Claude (`claude` CLI): reads the complete captured diff and a scratch checkout pinned to
  its head through Read/Glob/Grep only; restricted/safe mode, empty settings sources,
  strict empty MCP, and `dontAsk` permissions. Repository content is untrusted data.
  Truncated captures fail; smoke has no tools. `--effort` is omitted on Haiku models.
- Grok (`grok` CLI): repo-walking with read-only tools allowlist (`read_file,list_dir,grep` in both
  inspect and finalize), sandbox default `none` (`TRIBUNAL_GROK_SANDBOX`), `bypassPermissions`,
  isolated host config, web search off; T3 defaults to 8 inspect turns (`TRIBUNAL_GROK_MAX_TURNS`).
- Muse (`muse` CLI): repo-walking via `muse exec --yolo` with write, shell, and web tools off
  (`TRIBUNAL_MUSE_MODEL=default` passes no `--model`).
- DeepSeek (`dsh` CLI + `DEEPSEEK_API_KEY` or dsh credentials): repo-walking with read-only
  sandbox, approval disabled, and session uploads, telemetry, and web tools disabled.
- Gemini (`agy` CLI): diff plus web/CVE lens.
- Qwen (`qwen` CLI): repo-walking on its configured transport.

## Native review commands

Checked 2026-11-17. Sources: [Codex developer commands](https://developers.openai.com/codex/cli/reference)
and `codex exec review --help`; [Claude Code `/code-review`](https://code.claude.com/docs/en/code-review-local);
for the other harnesses, the installed CLI's `--help` and bundled skill files.
A leg runs its harness's own review command first where that command can review a pinned range
headlessly under the leg's existing restrictions. No native command emits the review schema,
accepts the context block, or reports the files it read, so its report (capped at 16 KiB) joins
the context block as leads and the verdict pass verifies them. The native call gets 180 s of the
600 s leg budget. A failed or empty native run is recorded in `summary.note` and on the wrapper's
stderr, and the verdict pass runs without it. `TRIBUNAL_NATIVE_REVIEW=off` skips the call.

| Leg | Native command | Used |
|---|---|---|
| Codex 0.169.0 | `codex exec review --base <base oid>` in a clone pinned to the reviewed head | yes; `--output-schema` is ignored and a prompt cannot be combined with `--base` |
| Claude Code 2.1.326 | `/review <level> <captured diff file>` under `claude -p` | yes; `/review` always runs the bundled `/code-review`; level is the leg effort capped at `high`; `--json-schema` suppresses the review |
| Grok 1.0.88 | `/review --main` | no; reviews against `origin/main` on a clean tree only and needs write and shell tools the leg denies |
| Qwen 0.25.3 | `qwen review run` | no; targets a PR or the working tree, defaults to `yolo` |
| OpenCode 2.3.0 | `/review [commit\|branch\|pr]` | no; expansion under `opencode run` is unconfirmed |
| Muse 1.4.20, agy 1.5.9, dsh 0.2.2 | none | no |

## Grok recovery

`TRIBUNAL_GROK_RECOVERY=permit` (default) keeps low-effort finalization under the read-only tools
allowlist (instructed not to use tools) when inspection times out or returns incomplete output.
`reject` turns a recovered verdict into a named `grok_recovery_rejected` failed leg, excluded from
quorum; unknown phase on a nonempty diff also fails. Sealed at collect time as `grok_recovery`.

## Backups for plan-limited and sub-quorum runs

A leg failing on a plan limit (402, usage limit, quota, resource/balance/credits exhausted, or
OpenCode `provider.{go,free,budget,model-budget}-limit`; never a timeout) emits an error starting
with `plan limit:`. After the first pass, the collector runs idle installed backup legs — one per
plan-limited leg, and enough to cover any shortfall when `ok` legs are below `TRIBUNAL_MIN_OK_LEGS`
— using the selection's backup order (or `TRIBUNAL_BACKUP_LEGS`, comma-separated providers or
`off`). Original failed legs remain `failed`.

## APPROVE quorum

`TRIBUNAL_MIN_OK_LEGS` (default `2`, range `2..8`; `1` is rejected because a one-leg `APPROVE` is
not allowed) is the per-environment floor of `ok` legs required for `APPROVE`. It is
environment-only and sealed into `manifest.json` inside `panel_policy` alongside `panel_size` and
the selected `panel`.
