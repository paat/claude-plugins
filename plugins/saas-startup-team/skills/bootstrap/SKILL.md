---
name: bootstrap
description: "Idempotent project scaffold for saas-startup-team (docs/, .startup/, gitignore, CLAUDE.md snippets)."
---

# Bootstrap

Idempotent project scaffold. Do not init `.startup/state.json` loop fields;
status comes from Git/PR/CI/deploy and durable docs.

## Step 1: Create Directory Structure

Create the following directories if they don't exist:

**Durable knowledge (git-tracked):**
```
docs/
├── research/        ← market size, customer pain points, competition, international
├── legal/           ← GDPR, Estonian business law, compliance analyses
├── architecture/    ← tech stack decisions, system design rationale
├── ux/              ← UX audit findings, accessibility gaps
├── seo/             ← keyword strategy, content optimization research
└── business/        ← brief, pricing strategy, business plans
```

**Startup metadata and loop state:**
```
.startup/
├── workflows/       ← Workflow registry/specs (git-trackable, shared test oracle)
├── handoffs/
├── reviews/
├── signoffs/
└── go-live/
```

```bash
mkdir -p docs/{research,legal,architecture,ux,seo,business,growth/{channels,leads,metrics/weekly,brand,content/blog,content/outreach-templates}}
mkdir -p .startup/{workflows,handoffs,reviews,signoffs,go-live}
```

## Step 2: Create .gitkeep

Create `.startup/.gitkeep` and `.startup/workflows/.gitkeep` so the directory and workflow registry survive `git clone`:

```bash
touch .startup/.gitkeep
touch .startup/workflows/.gitkeep
```

These files should be git-tracked. Runtime state, handoffs, reviews, signoffs, and go-live artifacts are gitignored; `.startup/workflows/` is intentionally git-trackable so route/job/state contracts can be reviewed with code.

## Step 3: Update .gitignore

Append the plugin's ignore rules from `${CLAUDE_PLUGIN_ROOT}/templates/gitignore-block.txt`, checking each line individually so partial pre-existing entries are not duplicated:

```bash
while IFS= read -r line; do
  [ -z "$line" ] && continue
  grep -qxF "$line" .gitignore 2>/dev/null || printf '%s\n' "$line" >> .gitignore
done < "${CLAUDE_PLUGIN_ROOT}/templates/gitignore-block.txt"
```

The block covers ephemeral `.startup/` state plus dependency trees and build output. A
freshly scaffolded project — the exact case `/bootstrap` is built for — often has no
`.gitignore` yet, and a dev-container pnpm store configured with `store-dir=.pnpm-store`
lives *inside* the repo; without these entries a later broad `git add` sweeps the entire
store into history, recoverable only by `git filter-repo` + force-push.

## Step 4: Update CLAUDE.md — Project Knowledge

If CLAUDE.md does not already contain a `## Project Knowledge` section, append the template
at `${CLAUDE_PLUGIN_ROOT}/templates/claude-md-project-knowledge.md`, then adapt it to what
actually exists in `docs/`: scan the `docs/` subdirectories, keep a bullet only for each
non-empty subdirectory, and add file-level pointers for key individual files (e.g.
`docs/business/brief.md`, or `docs/business/hinnastrateegia.md` for pricing).

## Step 5: Update CLAUDE.md — Workflow Guidance

If CLAUDE.md does not already contain a `## Workflow Guidance` section, append the template
at `${CLAUDE_PLUGIN_ROOT}/templates/claude-md-workflow-guidance.md`.

## Step 5b: Engineering principles (CLAUDE.md + AGENTS.md)

Ensure KISS / YAGNI / DRY are project guidance for every host that loads root
instruction files. Shared helper (idempotent; requires all three principle labels
or refreshes a managed block; resolves AGENTS.md symlinks safely):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ensure-engineering-principles.sh" --root .
```

## Step 6: Project Brief

If `docs/business/brief.md` already exists, skip this step.

**Non-interactive (plan file).** When a plan file is supplied — `--plan-file <path>` or
`$SAAS_BOOTSTRAP_PLAN` — render the brief and record provenance without prompting:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap-plan.sh" --plan-file "<path>"
```

The plan is JSON or frontmattered markdown supplying the `startup-brief.md` fields
(`idea_description` mandatory; `investor_notes`, `budget`, `timeline`, `target_market`
optional). It fails closed — a missing plan or empty `idea_description` exits non-zero
instead of prompting — and writes `.startup/provenance.json`
(`{idea_id, source:"plan-file", plan_sha256, validated_confidence, experiment_evidence,
created_at}`) from the plan's optional provenance fields.

**Interactive (no plan file).** Ask the user:

> "Describe your SaaS idea in a few sentences — what does it do, who is it for, and what problem does it solve?"

Save the response to `docs/business/brief.md` using the template from `${CLAUDE_PLUGIN_ROOT}/templates/startup-brief.md`.

**Provenance only.** `bootstrap-plan.sh` records `.startup/provenance.json` for plan
integrity and audit; it does not gate admission. Company registration, banking, and
signing stay human.

## Step 6.25: Scaffold the workflow registry

Create the workflow registry used by business planning, tech implementation, and UX QA. Idempotent — existing files are left untouched.

```bash
mkdir -p .startup/workflows
touch .startup/workflows/.gitkeep
if [ ! -f .startup/workflows/registry.md ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/templates/workflow-registry.md" .startup/workflows/registry.md
fi
if [ ! -f .startup/workflows/WORKFLOW-template.md ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/templates/workflow-spec.md" .startup/workflows/WORKFLOW-template.md
fi
```

When a new route, webhook, background job, state machine, checkout/payment flow, LLM pipeline, support intake, or operator workflow is introduced, copy `WORKFLOW-template.md` to `WORKFLOW-<slug>.md`, fill it, and add it to `registry.md`.

## Step 6.5: Scaffold the pre-merge safety net

Scaffold the CI gate and the canonical full-suite entrypoint so every project
inherits a pre-merge safety net. Idempotent — existing files are left untouched.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap-scaffold.sh"
```

## Step 7: Initialize Git and Commit

1. If not already in a git repo, run `git init`
2. Stage and commit the scaffolding. Run the large-file/store guard between staging and committing
   so a stray dependency tree or >50 MB blob aborts the commit with an actionable message instead
   of silently entering history:

```bash
git add docs/ .startup/.gitkeep .gitignore CLAUDE.md check.sh .github/workflows/ci.yml
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-staged-size.sh" || exit 1
git commit -m "chore: bootstrap project structure for saas-startup-team plugin"
```

