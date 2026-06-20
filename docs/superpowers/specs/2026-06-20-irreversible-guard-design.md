# irreversible-guard — design

**Issue:** #56 — New plugin: irreversible-guard — PreToolUse gate for irreversible-only operations
**Date:** 2026-06-20
**Status:** design approved, ready for implementation plan

## Problem

AI agents occasionally execute genuinely irreversible, catastrophic operations — "prompts are
not permissions." A `DO-NOT` line in CLAUDE.md does not bind: agents in long contexts
demonstrably ignore prose constraints, and the hard-won community conclusion is that enforcement
must live in hooks, not instructions.

This plugin is scoped **deliberately to irreversible blast-radius only** — not general friction.
Reversible risk is acceptable; the bar for blocking is *no practical local undo*. An over-broad
guard that blocks reversible work is one the user disables by Thursday, and "workarounds are where
the real incidents live."

### Evidence (real systems audited 2026-06-20)

- **PocketOS/Railway** (ai-agent-book ch.18): a Cursor agent found a Railway token, issued
  `volumeDelete` against the GraphQL API to "clear conflicting state," and destroyed the prod DB +
  co-located backups in 9 seconds (30h outage). Its own log acknowledged instructions forbade
  destructive actions and called overriding them "the most efficient way."
- **Aruannik** (`/mnt/data/ai/est-biz-aruannik`): Hetzner + Docker; the dev container is close to
  the public site. Real blast-radius commands are **transport-wrapped**:
  `ssh aruannik-live 'rm -rf /opt/aruannik/data/*'`,
  `docker exec <prod-ctr> sqlite3 /app/data/promo_codes.db "DROP TABLE …"`,
  `docker compose -f docker-compose.production.yml down -v`. An existing read-only SSH
  forced-command wrapper already encodes the "live access is read-only" intent. Incident
  2026-03-22: a manual edit on the live server broke deploys for 11 PRs over 2 days.
- **Varustame** (`/mnt/data/ai/varustame.ee`): .NET 9 / Postgres / Hetzner / Docker Compose.
  Catastrophic shapes: `docker compose -f docker-compose.production.yml down -v` (destroys
  `postgres-data`), `dotnet ef database drop`, `docker exec <prod> psql … "DROP TABLE annetused;"`,
  `ssh root@hetzner "rm -rf /srv/varustame/*"`. Routine-and-safe locally: `rm -rf bin/ obj/`,
  `docker compose down -v` on the test stack, `dropdb varustame_restore_drill` (quarterly drill).
- **Novarc** (ai-agent-book research): 236K-line PHP, no git, no tests, **root SSH to live prod** —
  "the feedback loop and the blast radius are the same machine. A careless agent run is not a
  failed CI build — it is a production incident."

### Book guidance (ai-agent-book ch.4, ch.18)

- Enforce with **PreToolUse hooks + exit code 2** — the agent reads *why* it was blocked and
  self-corrects deterministically, regardless of how degraded its context is.
- **De-obfuscate before matching**: a naive `rm -rf` regex dies the moment the agent wraps it in a
  heredoc, prefixes it with `DEBUG=true`, or chains it with `&&`. Unwrap heredocs, split on
  `&&`/`||`/`;`, strip `VAR=value` prefixes, then match each sub-command.
- **Calibrate friction to blast radius**: "a hook that blocks `rm` everywhere is friction you'll be
  tempted to disable by Thursday; a hook that blocks `rm` only where the blast radius is real costs
  you nothing the rest of the week."
- Every gate must trace to a failure mode you've actually seen.

## Scope

**In (v1):** a stateless, single-command irreversible-operations gate as a `PreToolUse` hook on the
`Bash` tool.

**Out (deferred to a follow-up issue):** the runaway-retry / token-spend circuit-breaker. It is a
fundamentally different mechanism — it requires persistent cross-invocation state, time windows, and
its own false-positive profile — and bundling it would muddy the crisp, testable command-gate that
delivers most of the value.

## The bar (inclusion criterion)

> Block a command only when it has **no practical local undo**.

Reversible operations — including git-recoverable destructive ops (force-push keeps the remote ref;
deleting tracked files is recoverable via git) — never block. They pass, or at most warn.

## Architecture

A single de-obfuscating matcher invoked as a `PreToolUse` hook. Decision flow:

```
PreToolUse(Bash) payload
   │
   ├─ extract command string (jq-free; python stdlib json)
   ├─ load defaults (rules/deny-set.json) + optional project config (.claude/irreversible-guard.json)
   │
   ├─ DE-OBFUSCATE into "effective atoms":
   │     unwrap heredoc bodies
   │     split on && || ; | and newlines
   │     strip leading VAR=val env prefixes
   │     recurse through TRANSPORT prefixes (ssh / docker exec / docker compose exec /
   │        bash -c / sh -c / eval), carrying a context tag = {host|container|compose-file}
   │
   ├─ classify each atom → BLOCK | WARN | PASS
   │     (apply allow[] first — the escape hatch — then tiers)
   │
   └─ command outcome = most severe atom outcome
         BLOCK → exit 2 + reason on stderr
         WARN  → exit 0 + additionalContext note (non-blocking)
         PASS  → exit 0, silent
```

### Component boundaries

- `hooks/irreversible-guard.py` — the matcher. Pure function core (`classify(command, config) ->
  outcome+reason`) wrapped by thin stdin/stdout/exit-code I/O. Testable without the harness.
- `rules/deny-set.json` — the default tiered pattern set, as **data not code**, so patterns are
  reviewable/extensible and the matcher stays generic (repo "no hardcoded specifics" rule).
- `hooks/hooks.json` — wires the matcher to `PreToolUse` with `matcher: "Bash"`.
- `.claude/irreversible-guard.json` — optional per-project config (escape hatch + extensions).
- `tests/` — fixture-driven green/red proof.

## The deny-set (two tiers)

### Tier 1 — BLOCK ALWAYS (irreversible in every environment)

No environment detection needed: these have no undo anywhere, so they block unconditionally. The
allowlist is the only escape.

| Category | Match |
|---|---|
| Filesystem nuke | `rm -r`/`rm -rf` whose target resolves to a protected root: `/`, a top-level `/<dir>`, `~`/`$HOME`/`${HOME}` (incl. bare home glob `~/*`), the repo root (cwd == git toplevel), a `..`-escape above cwd, persistent-data roots under `/opt`, `/srv`, `/data`, `/var/lib`, or any `rm` with `--no-preserve-root`. **Scoped relative dirs PASS** (`node_modules`, `.next`, `build`, `dist`, `bin`, `obj`, `venv`, `target`, `__pycache__`, `coverage`). |
| Disk / format | `dd of=/dev/…`; `mkfs`/`mkfs.*`; `wipefs` |
| IaC teardown | `terraform destroy`; `tofu destroy` |
| Cloud delete (curated, config-extensible) | `fly volumes destroy`, `flyctl volumes destroy`; `railway volume delete`; `aws s3 rb`; `aws s3 rm … --recursive`; `aws ec2 delete-volume`; `aws rds delete-db-instance`/`delete-db-cluster`; `gcloud sql instances delete`; `gcloud compute disks delete`; `heroku pg:reset`; `kubectl delete (namespace\|ns\|pv\|pvc)` |

### Tier 2 — BLOCK only when the command names prod, else PASS

These are catastrophic against production but **routine and locally reversible** (re-migrate a dev
DB, re-up a local stack). Blocking them everywhere is the disable-by-Thursday friction the book
warns against, and would violate the bar (locally reversible). So they block **only** when a prod
marker is explicit in the command itself.

| Match |
|---|
| `DROP DATABASE` / `DROP TABLE` / `TRUNCATE` (and `dotnet ef database drop`) issued via a DB client (`psql`, `mysql`, `mongosh`, `sqlite3`), incl. heredoc-wrapped |
| `docker compose … down -v` / `--volumes`; `docker volume rm`; `docker volume prune` |

**"Prod marker" is explicit, not ambient.** A Tier-2 atom blocks when its command or carried
context tag matches a prod pattern: default `*prod*`, `*production*`, `*-live` (configurable via
`prod_markers`). Sources of the marker: the transport host (`ssh aruannik-live …`), the container
(`docker exec varustame-prod-api …`), the compose file (`-f docker-compose.production.yml`), or a
connection string / env-var name (`$PROD_DATABASE_URL`). If no prod marker is present, the op is
treated as local-and-reversible → PASS. This sidesteps the false-negative failure of `NODE_ENV`
sniffing (rejected during brainstorming): everything that is irreversible *regardless* of
environment already lives in Tier 1 and blocks unconditionally.

### WARN ALWAYS (recoverable; non-blocking note)

| Match | Why warn not block |
|---|---|
| `git push --force` / `-f` / `--force-with-lease` | remote keeps the old ref (reflog) |
| `git reset --hard` | discards uncommitted work — no undo, but local & frequent |
| `git clean -fdx` / `-fd` | discards untracked/ignored files — local |

## De-obfuscation details

- **Tokenization:** `shlex.split` (quote-aware) per atom — the reason the matcher is Python.
- **Heredocs:** detect `<<['"]?TAG`, capture the body up to `TAG`, and treat the body as additional
  atoms (this is how `psql … <<EOF \n DROP TABLE … \n EOF` is caught).
- **Separators:** split top-level (quote-aware) on `&&`, `||`, `;`, `|`, and newlines.
- **Env prefixes:** strip leading `NAME=value` tokens from each atom before matching the verb.
- **Transport recursion:** when atom[0] ∈ {`ssh`, `docker` (+`exec`), `docker`/`docker-compose`
  (+`exec`), `bash -c`, `sh -c`, `eval`}, extract the inner command string, recurse, and tag the
  inner atoms with the transport target (host/container/compose-file) so Tier-2 prod-marking
  survives. Bounded recursion depth (e.g. 5) to avoid pathological nesting.

## Configuration — `.claude/irreversible-guard.json` (optional, stdlib JSON)

```json
{
  "allow":        ["substring-or-/regex/ never blocked — the pressure valve"],
  "extra_block":  ["additional always-block patterns"],
  "prod_markers": ["*prod*", "*production*", "*-live"],
  "warn_only":    ["downgrade a specific default-block pattern to warn"]
}
```

`allow` is evaluated **first** (highest precedence) so a project can always unblock a false
positive. JSON (not the `.local.md`+YAML house convention) to keep the matcher dependency-free
(stdlib `json`, no PyYAML).

## Error handling / fail mode

- **python3 absent:** emit a one-line warning to stderr and **exit 0 (fail-open)**. Hard-failing
  closed would brick every Bash tool call. python3 is documented as a prerequisite. (Tradeoff:
  fail-open means no protection if python3 is missing; acceptable because the target environments
  all ship python3, and the alternative bricks the agent.)
- **Malformed payload / unreadable config / parse error:** stderr note, exit 0 (PASS). Never block
  on the guard's own bug.
- **deny-set.json missing/corrupt:** the matcher ships defaults inline as a fallback so it degrades
  to "Tier 1 defaults" rather than "no protection."

## Output contract (Claude Code PreToolUse)

- **BLOCK:** `exit 2`; reason on **stderr** (fed back to the agent), naming the matched pattern, the
  tier, why it is irreversible, and how to override (allowlist).
- **WARN:** `exit 0` + JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "additionalContext":"<note>"}}` — the agent sees the caution and proceeds.
- **PASS:** `exit 0`, no output.

## Testing strategy

Fixture-driven, asserting real exit codes against synthetic PreToolUse payloads.

- `tests/cases.tsv` — rows of `command <TAB> expected(BLOCK|WARN|PASS)`.
- `tests/run.sh` — for each row, build a PreToolUse JSON payload (`{"tool_name":"Bash",
  "tool_input":{"command":"…"},"cwd":"…"}`), pipe to the hook, assert exit code + outcome; print a
  green/red summary; non-zero exit on any mismatch.

**Required coverage (satisfies #56 acceptance criteria + evidence-driven additions):**

- **BLOCK positives**, each replicated **bare, heredoc-wrapped, `&&`-chained, `ENV=`-prefixed,
  `ssh prod`-wrapped, and `docker exec prod`-wrapped**:
  `volumeDelete`-class (`fly volumes destroy`, `railway volume delete`), `DROP TABLE` via `psql`,
  `terraform destroy`, `rm -rf /` / `rm -rf ~` / `rm -rf $HOME` / `rm -rf /opt/aruannik/data/*`,
  `dd of=/dev/sda`, prod `docker compose -f docker-compose.production.yml down -v`.
- **PASS negatives (must NOT block):** `rm -rf node_modules`, `rm -rf .next`, `rm -rf build`,
  `rm -rf bin/ obj/`, scoped relative `rm`, plain `git push`, `dotnet ef database update`,
  local `docker compose down -v` (no prod marker), `dropdb varustame_restore_drill`.
- **WARN:** `git push --force`, `git reset --hard`, `git clean -fdx`.

## Plugin layout

```
plugins/irreversible-guard/
  .claude-plugin/plugin.json
  hooks/
    hooks.json                 # PreToolUse, matcher: "Bash" → python3 irreversible-guard.py
    irreversible-guard.py      # de-obfuscating matcher (pure-core + thin I/O)
  rules/
    deny-set.json              # default tiered patterns (data)
  tests/
    run.sh
    cases.tsv
  README.md                    # incl. end-user Installation section (3 scopes)
```

Plus: bump version in **both** `plugins/irreversible-guard/.claude-plugin/plugin.json` and the root
`.claude-plugin/marketplace.json`; add the new plugin entry to `marketplace.json`. README documents
the python3 prerequisite.

## Acceptance criteria (from #56, made concrete)

- Blocks `volumeDelete`-class, `DROP TABLE`, and `terraform destroy`/`rm -rf` fixtures — including
  heredoc-wrapped, `&&`-chained, env-prefixed, and **transport-wrapped (`ssh`/`docker exec` to a
  prod target)** variants.
- Permits ordinary `git push`, scoped `rm` (`node_modules`/`build`/`bin`/`obj`), reversible file
  edits, and local (non-prod) Tier-2 ops.
- Warns (non-blocking) on `git push --force`, `git reset --hard`, `git clean -fdx`.
- `tests/run.sh` is green.

## Decisions deliberately deviating from the brainstorm (flag for review)

1. **Two-tier deny-set** rather than one flat unconditional block. Tier 1 honors "block
   unconditionally" for everything irreversible-everywhere; Tier 2 blocks the locally-reversible
   ops *only* when the command explicitly names prod. This is faithful to the bar (don't block
   reversible work) and avoids the disable-by-Thursday friction, while keeping zero false-negatives
   on the truly irreversible. The "prod marker" reads the command's own explicit target — it is not
   the ambient `NODE_ENV` sniffing that was rejected.
2. **Python, not bash.** The matcher's parsing correctness is the security property; `shlex` makes
   quote/heredoc/transport handling robust and testable. Documented python3 prerequisite; fail-open
   if absent.
3. **JSON config**, not `.local.md`+YAML, to stay stdlib-only (no PyYAML).
