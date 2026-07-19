---
name: bootstrap
description: Initialize project structure for the saas-startup-team plugin — creates docs/ and .startup/ directories, updates .gitignore and CLAUDE.md. Idempotent (safe to re-run).
user_invocable: true
---

# /bootstrap — Initialize Project Structure

Set up a project for the saas-startup-team plugin without starting the agent loop. This command is idempotent — running it multiple times is safe and will not overwrite existing content.

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

**Admission seam.** `bootstrap-plan.sh` only *records* provenance; it does not gate. When
mission-control drives an autonomous bootstrap it enforces admission first — Slot B
capacity, the pre-launch WIP cap, the validated-confidence bar, and the 72h human veto
window — reading `.startup/provenance.json`, then invokes this step. Company registration,
banking, and signing stay human.

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
set -uo pipefail

# 1. Canonical entrypoint: check.sh (copy template, make executable)
if [ ! -f check.sh ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/templates/check.sh" check.sh
  chmod +x check.sh

  # Detection: append INERT commented suggestions only. REQUIRED_SUITES stays
  # empty, so a mis-detection can never produce a falsely-green gate.
  if [ -f package.json ]; then
    {
      echo ""
      echo "# DETECTED package.json — consider:"
      if command -v jq >/dev/null 2>&1 && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
        echo "#   REQUIRED_SUITES+=(frontend_tests); frontend_tests() { run_suite frontend_tests 'npm test'; }"
      fi
      if command -v jq >/dev/null 2>&1 && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
        echo "#   REQUIRED_SUITES+=(lint); lint() { run_suite lint 'npm run lint'; }"
      fi
      [ -f tsconfig.json ] && echo "#   REQUIRED_SUITES+=(typecheck); typecheck() { run_suite typecheck 'npx tsc --noEmit'; }"
    } >> check.sh
  fi
  if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.cfg ]; then
    {
      echo ""
      echo "# DETECTED Python project — consider:"
      echo "#   REQUIRED_SUITES+=(backend_tests); backend_tests() { run_suite backend_tests 'pytest -q'; }"
    } >> check.sh
  fi
fi

# 2. CI workflow: .github/workflows/ci.yml (copy template, substitute STACK_SETUP)
if [ ! -f .github/workflows/ci.yml ]; then
  mkdir -p .github/workflows
  cp "${CLAUDE_PLUGIN_ROOT}/templates/ci-workflow.yml" .github/workflows/ci.yml

  # Build the runtime-setup block. Install command depends on which lock/manifest
  # files exist so CI does not fail before ./check.sh (npm ci needs a lockfile;
  # pip -r needs requirements.txt).
  setup=""
  if [ -f package.json ]; then
    if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      setup='      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n          cache: npm\n      - run: npm ci'
    else
      setup='      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n      - run: npm install'
    fi
  elif [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.cfg ]; then
    if [ -f requirements.txt ]; then
      pyinstall='pip install -r requirements.txt'
    else
      pyinstall='pip install -e .'
    fi
    setup="      - uses: actions/setup-python@v5\n        with:\n          python-version: \"3.12\"\n      - run: $pyinstall"
  else
    # No stack detected: leave a marker for the tech-founder to fill in.
    setup='      # [TECH-FOUNDER: add language/runtime setup for your stack, then\n      #  install deps, before ./check.sh runs.]'
  fi
  # Replace the whole {{STACK_SETUP}} token line. GNU sed expands \n in the
  # replacement to newlines, producing the multi-line YAML block.
  sed -i "s|.*{{STACK_SETUP}}.*|$setup|" .github/workflows/ci.yml
fi

# 3. Branch-protection [HUMAN] task (sequenced, idempotent).
mkdir -p .startup docs
if [ ! -f docs/human-tasks.md ]; then
  if [ -f .startup/human-tasks.md ]; then
    cp .startup/human-tasks.md docs/human-tasks.md
  else
    cp "${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md" docs/human-tasks.md
  fi
fi
if ! grep -q "Require the CI check (branch protection)" docs/human-tasks.md; then
  cat "${CLAUDE_PLUGIN_ROOT}/templates/branch-protection-task.md" >> docs/human-tasks.md
fi
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
