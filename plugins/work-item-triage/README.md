# work-item-triage

Decide whether a work item deserves implementation, or whether a proposed issue deserves filing.
One evidence-based decision card compares the claimed outcome with present behavior, prior decisions,
obligations and the smallest adequate response. Doing no new development is a first-class result.

## Mission Fit

Autonomous delivery should spend effort on demonstrated needs and preserve necessary commitments.
This plugin supplies a durable triage decision and next-action queue before filing or implementation,
including non-code work, without taking over delivery or scheduling.

## Two directions

`existing` assesses open items, their history and linked delivery; it can recommend a minimal fix,
consolidation, verification, concrete deferral or closure. `proposed` checks whether a draft merits
a durable issue, including no filing, appending to an owner, immediate bounded work or a limitation.
Both use the same card and evidence rules, with separate necessity and readiness fields.

The plugin never files issues itself. For an accepted draft, it delegates by instruction to the
installed `saas-startup-team:issue-file` skill, whose filing flow runs its PII gate. Without that
skill, it returns the draft and stops with an explicit warning that it has had no PII review.
No other plugin is a runtime dependency and no external plugin scripts are sourced.

## Dependencies

- Bash 4+, standard POSIX utilities and `mktemp` for temporary files/directories.
- `jq` for normalized JSON and register validation/rendering.
- `python3` (standard library only) for configured-source parsing and action hashes.
- `git` when pinning inspected code to its commit.
- Authenticated `gh` for GitHub sources. Plane sources use caller-configured commands;
  install/document any dependencies required by those commands in the target repository.

## Use

Ask the `work-item-triage` skill to assess a tracker scope or a proposed issue, with an output
directory and optional code checkout. Analysis is the default; use apply only for covered actions.
The skill is identical on Claude Code and Codex; no command wrappers or host-specific workflow
copies are maintained. Resolve `WIT_ROOT` to the installed plugin root before direct script use.

```bash
"$WIT_ROOT/scripts/wit-read.sh" --system github --scope "$TRACKER_SCOPE" > "$SNAPSHOT"
"$WIT_ROOT/scripts/wit-register.sh" --snapshot "$SNAPSHOT" --decisions "$DECISIONS" \
  --output-dir "$OUTPUT_DIR" --code-ref "$CODE_REFERENCE"
```

The skill prepares `DECISIONS`; the writer validates coverage/enums and owns all durable output.
Omit the code reference for non-code work. Detailed contracts are loaded on demand from
[decision-card.md](skills/work-item-triage/references/decision-card.md) and
[adapters.md](skills/work-item-triage/references/adapters.md).
Plane reuses the repo-local `sources:` configuration shape, including optional `search`.
Without search, duplicate lookup falls back to listing and local matching and reports that limit.

## Durable results and handoff

Each run appends `OUTPUT_DIR/work-item-triage/RUN_ID/` containing `register.json`, `summary.md`,
`queue.md` and `applied.json`; `pointer.json` names the newest run. Previous assessments remain
unchanged, with per-item source/fetch/history/code provenance and links to superseded decisions.
Use a caller-selected output location appropriate for its evidence; artifacts are not PII-reviewed
by this plugin. Public summaries must retain useful links without copying private source material.

The queue separates priority from eligibility, preserving dependencies, minimum scope, next task
and stop/refresh conditions. Link it from normal repository/tracker entry points so a fresh session
can identify eligible work without repeating the census. The consumer must actually enforce any
claimed exclusion; see [handoff.md](skills/work-item-triage/references/handoff.md).

## Mutation and enforcement boundaries

`wit-read.sh` has no tracker mutation operation and receives only read verbs from configured sources.
`wit-apply.sh` is the sole tracker-writing helper: authorized comments/closures, re-read before write,
deterministic action markers, readback and separate execution results. Unknown/ambiguous writes
stay unresolved. Providers need not offer atomic writes or native idempotency.
Configured commands are trusted code and must honor their read contract. The host agent still has
a general shell; these plugin boundaries do not sandbox the entire session.

Every queue row reports `native`, `instruction-only` or `unavailable` enforcement and its mechanism.
Instruction links alone do not change unattended selectors. A `maintain:blocked` label without an
active ledger entry may still be selected; inspect the installed consumer before claiming otherwise.
The plugin introduces no label taxonomy, scheduler or automatic implementation.

## Validation

Run `bash plugins/work-item-triage/tests/run-tests.sh` from the repository root. Stubbed tracker tests
cover schemas, page/history completeness, evidence limits, immutable provenance, read-only analysis,
repeat-safe application and GitHub/Plane parity. Fixtures cover ten required scenarios and non-code
work. A live two-repository pilot remains separate operational validation, not a code-test claim.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install work-item-triage@paat-plugins --scope user`
- **Install for all collaborators on this repository** (project scope) — committed, shared with the team:
  `/plugin install work-item-triage@paat-plugins --scope project`
- **Install for you, in this repo only** (local scope) — just you, just this repo:
  `/plugin install work-item-triage@paat-plugins --scope local`

For Codex, install `work-item-triage` from the repository's generated `paat-plugins` marketplace.
