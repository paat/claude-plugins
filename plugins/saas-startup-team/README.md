# saas-startup-team

Portable SaaS delivery plugin for Claude Code and Codex: Plan → isolated Build →
Independent Review → Release, with bounded maintenance and domain gates.

## Installation

- **Install for you** (user scope): `/plugin install saas-startup-team@paat-plugins`
- **Install for all collaborators on this repository** (project scope): commit
  `.claude/settings.json` with the plugin enabled
- **Install for you, in this repo only** (local scope): `.claude/settings.local.json`

## Canonical capabilities

| Skill | Role |
|-------|------|
| `lifecycle` | `/startup` — intake, discovery only on evidence gaps, triggered specialists, deliver |
| `deliver` | `/improve`, `/goal-deliver`, `/tweak`, startup implementation |
| `product-discovery` / `product-acceptance` | Requirements and independent go-live judgment |
| `lawyer` | Legal/compliance; evidence tiers; UNVERIFIABLE is not disproven |
| `growth` | Lifecycle-gated acquisition within spend envelope |
| `ux-review` | Independent usability/a11y; host browser when available |
| `operate` | `/monitor`, `/investigate`, `/replay-abandoned` |
| `maintain` | One bounded externally scheduled tick (maintain-v3) |
| `epic` | `/epic <n>` — serial multi-issue epic train (one branch/PR; see below) |
| `epic-compose` | `/epic-compose` — scan open issues → file one focused epic for `/epic` |

Slash commands and Codex `saas-startup-team-*-workflow` skills are **generated aliases**
only — no workflow policy in `commands/`. Regenerate via
`scripts/generate_workflow_aliases.py` from `integrity/entrypoints.json`.

## Evidence and gates

One deterministic CLI:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" schema|pii|legal|spend|regression|acceptance|release …
```

| Gate | Use |
|------|-----|
| `schema` | JSON syntax |
| `pii` | Secret/PII patterns (`--mode secrets` for hooks; full for issue filing) |
| `legal` | Verdict frontmatter; `--validate` / `--enforce` |
| `spend` | `envelope` / `ads` hard-stop / `linkedin` advisory |
| `regression` | Incident-linked `gh pr merge` requires a test or override |
| `acceptance` | Packs select/render/verify-report/verify-public-route |
| `release` | `signoff` (solution signoff) / `poll` (CI/deploy status) |

Hooks: one path-scoped dispatcher (`hooks/dispatch.sh`) for PreToolUse Write|Edit/Bash
and PostToolUse Write|Edit. Critical rules fail closed; advisory rules fail open with
warnings. Hooks never commit or mutate orchestration state. Credential/token prevention
runs before write when the host supplies content on blocking PreToolUse; full PII scan
is `gate.sh pii` (used by issue filing). Schema/spend pre-write run only when content is
present so corrective Edits are not blocked on stale on-disk state.

Legal policy remains in `skills/lawyer` — `CONFIRMED` needs Tier A verbatim quotes;
corpus silence is `UNVERIFIABLE-IN-CORPUS`, never disproof.

## Delivery and maintenance

- **Delivery playbook** (sole): `references/delivery-playbook.md`
- **Maintenance policy** (sole): `references/workflows/maintain-policy.md`
- **Epic trains** (1.1): `skills/epic/SKILL.md` + `docs/legacy/epic-invariants.md`

`/epic <n>` runs a **serial** multi-issue train for one GitHub epic with a child
checklist (`- [ ] #N`). One branch `epic/<n>-…`, one draft PR, per-child `deliver`
(no merge to main mid-train), tribunal hard-required for execution, children closed
only after the epic PR merges. Plan only: `/epic --plan <n>`. Parser:
`scripts/epic_plan.py` (no network). Active-epic guard: `scripts/epic_active.py`
(cooperative; mutating improve/maintain refuse when another epic PR is open).

`/epic-compose [--dry-run]` scans issues and files one focused epic then auto-runs `/epic <n>` (use `--compose-only` to skip implement).

Git issues, branches, PRs, CI, deployments, and immutable terminal release facts are
authoritative. No founder loop state machine, numbered conversational handoffs, or
Stop/yield control on the normal path.

Short maintain locks only (scheduler/issue/release).

## External scheduling

Cadence lives outside the plugin. Examples:

```cron
# Maintain one tick per scheduler interval
0 */6 * * * cd <repo> && <assistant> "/maintain-loop --once"

# Nightly monitor
0 6 * * * cd <repo> && bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" monitor-nightly \
  && <assistant> "/monitor-nightly"
```

## Codex

Command workflows ship as plugin skills. Implementation is Codex-only on Codex hosts
(no Claude Code fallback). Parent conducts; workers implement via `codex-cast.sh` (`--json-out`) gated by
`isolated-build-assert.py`. `/epic` / default `/epic-compose` are meta-orchestrators.

## Browser / UX

Unconditional pinned Playwright MCP loading is off. UX review uses host browser
capability when available; missing tools → `tool-unavailable`, never PASS from empty
sessions.

## Prerequisites

- Claude Code or Codex; `bash` 4+, `git`, `gh`, `jq`, `awk`, `sed`, `python3`,
  `curl`, `npm`/`npx` (optional growth tooling), coreutils
- Dev container recommended (YOLO mode; container is the security boundary)
- `/lawyer`: `EST_DATALAKE_API_KEY` and reachable `DATALAKE_URL` (default
  `https://datalake.r-53.com`)
- Optional: `google-ads-strategist` for Google Ads (always PAUSED at create)
- Optional: `tribunal-review` for merge-path closing loops


### Operate phase

Config `operate:` / `monitor:` in `.claude/saas-startup-team.local.md`. Modes via
`skills/operate`. Nightly monitor uses `monitor-checks.sh` custom-checks and
`repro_recipe`; filing via `scripts/monitor-dedup.sh` / `issue-file.sh` (PII via
`gate.sh pii`). Workflow registry under `.startup/workflows/`. Health:
`scripts/health-preflight.sh`. Demand: `scripts/market-scout.sh`. Packs:
`scripts/gate.sh acceptance` (or `acceptance-packs.sh`).

## Migration (1.0.0 major)

**Breaking.** Full guide: `docs/legacy/migration-1.0.0.md` and `CHANGELOG.md`.

- Canonical delivery: `deliver` skill (`goal-deliver` / `improve` / `tweak` aliases)
- Maintain: one externally scheduled `maintain-v3` tick; drain via `legacy-drain.sh`
- Gates: `hooks/dispatch.sh` + `scripts/gate.sh`; no auto-commit / founder Stop loop
- Domain references: `references/<domain>/` (loaded on demand)
- Intermediate notes: `docs/legacy/migration-1.0-meta-removed.md`,
  `docs/legacy/migration-1.0-hooks-gates.md`
