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

**Ephemeral loop state (gitignored):**
```
.startup/
├── handoffs/
├── reviews/
├── signoffs/
└── go-live/
```

```bash
mkdir -p docs/{research,legal,architecture,ux,seo,business,growth/{channels,leads,metrics/weekly,brand,content/blog,content/outreach-templates}}
mkdir -p .startup/{handoffs,reviews,signoffs,go-live}
```

## Step 2: Create .gitkeep

Create `.startup/.gitkeep` so the directory survives `git clone`:

```bash
touch .startup/.gitkeep
```

This file should be git-tracked. Everything else in `.startup/` is gitignored.

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
.startup/human-tasks.md
.startup/test-data/
.startup/.idle-*
```

**Check before appending:** Read `.gitignore` and only add lines that are not already present.

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

When adding features or changing behavior, check relevant docs first.
When completing research, save findings to the appropriate `docs/` subdirectory.
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
```

## Step 6: Project Brief

If `docs/business/brief.md` does not exist, ask the user:

> "Describe your SaaS idea in a few sentences — what does it do, who is it for, and what problem does it solve?"

Save the response to `docs/business/brief.md` using the template from `${CLAUDE_PLUGIN_ROOT}/templates/startup-brief.md`.

If `docs/business/brief.md` already exists, skip this step.

## Step 7: Initialize Git and Commit

1. If not already in a git repo, run `git init`
2. Stage and commit the scaffolding:

```bash
git add docs/ .startup/.gitkeep .gitignore CLAUDE.md
git commit -m "chore: bootstrap project structure for saas-startup-team plugin"
```
