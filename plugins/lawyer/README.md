# lawyer

On-demand Estonian/EU legal risk analysis for SaaS projects. Queries the
est-saas-datalake once, verifies decisive claims against primary sources
(Riigi Teataja, EUR-Lex), and writes one concise Estonian decision brief to
`docs/legal/õiguslik-*.md`. Not a licensed attorney — risk levels and
mitigations, never a definitive legal opinion.

A law registry tracks the provisions your code depends on and flags them when
the law changes.

## Usage

```
/lawyer <topic>
/lawyer register <slug> <act_id> "<citation>" "<purpose>" [--force]
/lawyer unregister|ack|issue <slug>
/lawyer ack-all|status|check
```

In Codex, invoke the `lawyer` skill with the same arguments.

- **Topic run**: preflight → `check` → topic-scoped analysis → brief with
  verdict frontmatter (`verdict`, `evidence_tier`, `blocking_human_tasks`,
  `claims`) validated by `scripts/legal-verdict-gate.sh --validate`.
- **Evidence tiers**: `CONFIRMED` needs a complete verbatim Tier A sentence and
  HTTPS source URL. Datalake absence is `UNVERIFIABLE-IN-CORPUS`, never a
  refutation.
- **Law registry**: `.startup/law-registry.json` + `.startup/laws/<slug>.txt`;
  source files mark dependencies with `LAW: <slug>` comments. `check` polls the
  datalake change feed and re-checks in-force status; `ack` runs inside the PR
  that ships the code fix. See `references/law-registry.md`.
- The `lawyer` agent (Claude Code) runs the same skill as a one-shot consultant
  other workflows can dispatch.

saas-startup-team keeps its own copy of `legal-verdict-gate.sh` to gate merges
on hedged `docs/legal/*.md` verdicts; the two copies must stay byte-identical
(`tests/skill-contract.tests.sh` checks this in a repo checkout).

## Dependencies

- `bash` 4+, `curl`, `jq`, `python3`, `awk`, `sed`, `git`
- `gh` (authenticated) — only for `/lawyer issue` and interactive backlog review
- `EST_DATALAKE_API_KEY`; `DATALAKE_URL` (default `https://datalake.r-53.com`)

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install lawyer@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

Codex: `codex plugin marketplace add paat/claude-plugins`, then install
`lawyer` from the `paat-plugins` marketplace.

## Tests

```bash
bash plugins/lawyer/tests/run-tests.sh
```
