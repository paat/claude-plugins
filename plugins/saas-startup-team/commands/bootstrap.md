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

Append the following to `.gitignore` if not already present. Check each line individually — some projects may already have partial entries:

```gitignore
# Startup plugin operational state (ephemeral, not knowledge)
.startup/state.json
.startup/state-archive.json
.startup/state.json.bak-*
.startup/state.json.lock
.startup/handoffs/
.startup/reviews/
.startup/signoffs/
.startup/go-live/
.startup/test-data/
.startup/.idle-*

# Dependencies & package stores (NEVER commit — an in-repo pnpm store can be GBs and a single
# prebuilt binary >100 MB makes the repo unpushable to GitHub, recoverable only by history rewrite)
node_modules/
.pnpm-store/
.pnpm/
.yarn/
bower_components/

# Build output & caches
.next/
dist/
build/
out/
.turbo/
.cache/
coverage/
*.log
```

**Check before appending:** Read `.gitignore` and only add lines that are not already present.

> A freshly scaffolded project — the exact case `/bootstrap` is built for — often has no
> `.gitignore` yet, and a dev-container pnpm store configured with `store-dir=.pnpm-store` lives
> *inside* the repo. Without these entries a later broad `git add` sweeps the entire store into
> history. Because `.gitignore` does not untrack already-committed paths, the only recovery is
> `git filter-repo` + force-push. The dependency/build block above is what prevents that.

## Step 4: Update CLAUDE.md — Project Knowledge

If CLAUDE.md does not already contain a `## Project Knowledge` section, add it.

Scan the `docs/` subdirectories to generate the content dynamically:

1. List files in each `docs/` subdirectory
2. For each non-empty subdirectory, add a bullet with the directory and a description of its contents
3. For key individual files (like `brief.md`), add specific file-level pointers

**Template** (adapt based on what actually exists in `docs/`):

```markdown
## Project Knowledge

Research and design decisions live in `docs/`. Consult these before making changes:

- **Business brief**: `docs/business/brief.md` — what we're building and why
- **Market research**: `docs/research/` — market size, customer pain points, competition
- **Legal/compliance**: `docs/legal/` — GDPR, Estonian business law, compliance
- **Architecture**: `docs/architecture/` — tech stack decisions and rationale
- **UX findings**: `docs/ux/` — audit results, accessibility gaps
- **SEO research**: `docs/seo/` — keyword strategy, content optimization
- **Growth**: `docs/growth/` — growth strategy, channel metrics, pipeline, outreach templates
- **Workflow registry**: `.startup/workflows/registry.md` — routes, jobs, states, handoff contracts, and QA coverage

When adding features or changing behavior, check relevant docs first.
When completing research, save findings to the appropriate `docs/` subdirectory.
When introducing or changing a workflow, update `.startup/workflows/registry.md` and the affected `WORKFLOW-<slug>.md` spec.
```

Only include bullets for subdirectories that exist. If a subdirectory has notable files, list them specifically (e.g., `docs/business/hinnastrateegia.md` for pricing).

## Step 5: Update CLAUDE.md — Workflow Guidance

If CLAUDE.md does not already contain a `## Workflow Guidance` section, add it:

```markdown
## Workflow Guidance

### Use `/startup` (agent loop) when:
- Starting a new product or major pivot — needs market research, competition analysis, pricing
- Building 3+ features that need business justification and browser verification
- You want structured business-to-tech-to-review cycles with quality gates

### Use plain Claude Code when:
- Bug fixes, hotfixes, deployment issues
- SEO tweaks, content updates, copy changes
- Single feature where you already know the "why"
- Ops/infrastructure work (docker, nginx, CI)
- Quick research tasks (use `/lawyer` or `/ux-test` standalone)

### Use `/growth` (growth track) when:
- Product is live and ready for customers — need to acquire paying users
- Want to run outreach, content marketing, ad campaigns, community engagement
- Pre-launch audience building (`/growth --pre-launch`)

### Use `/improve` (one-shot fixes) when:
- Product is complete (solution signoff exists) but needs minor tweaks
- Bug fixes, styling changes, copy updates on a shipped product
- Changes that don't need market research or new feature design

### Either way:
- Save research findings to `docs/` (not ad-hoc locations)
- Check relevant `docs/` before making design decisions
- Update `docs/` when decisions change
- Update `.startup/workflows/` when routes, jobs, states, or handoff contracts change
```

## Step 6: Project Brief

If `docs/business/brief.md` does not exist, ask the user:

> "Describe your SaaS idea in a few sentences — what does it do, who is it for, and what problem does it solve?"

Save the response to `docs/business/brief.md` using the template from `${CLAUDE_PLUGIN_ROOT}/templates/startup-brief.md`.

If `docs/business/brief.md` already exists, skip this step.

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
# NOTE: do NOT put fenced code blocks inside this heredoc — the test harness's
# markdown bash-block extractor stops at the first closing fence. Commands are
# shown indented as plain text instead.
mkdir -p .startup docs
if [ ! -f docs/human-tasks.md ]; then
  if [ -f .startup/human-tasks.md ]; then
    cp .startup/human-tasks.md docs/human-tasks.md
  else
    cp "${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md" docs/human-tasks.md
  fi
fi
if ! grep -q "Require the CI check (branch protection)" docs/human-tasks.md; then
  cat >> docs/human-tasks.md <<'TASK'

## [HUMAN] Require the CI check (branch protection)

Sequencing: do this ONLY after the tech-founder has finalized `check.sh` and the
first CI run on a real PR is green — otherwise you block every PR on a stub.

1. Get the exact check name from the first green PR:
   gh pr checks <pr-number>      (it is `check` or `CI / check` — copy verbatim)
2. Primary path — GitHub UI: Settings → Branches → Add branch protection rule →
   "Require status checks to pass before merging" → select that check.
3. CLI alternative (ONLY for a repo with no existing protection rule — a PUT to
   /protection REPLACES all protection settings; use the UI otherwise):

       BR=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
       CTX="check"   # replace with the exact name from step 1
       gh api -X PUT "repos/{owner}/{repo}/branches/$BR/protection" \
         -H "Accept: application/vnd.github+json" --input - <<JSON
       {
         "required_status_checks": { "strict": true, "contexts": ["$CTX"] },
         "enforce_admins": false,
         "required_pull_request_reviews": null,
         "restrictions": null
       }
       JSON

   Requires repo-admin + a token with the right scope. enforce_admins:false
   lets admins merge a red PR in an emergency — set true to bind admins too.
TASK
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
