# Knowledge Management Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate durable project knowledge (docs/) from ephemeral loop state (.startup/) so any Claude Code session can find research, and operational churn never hits git.

**Architecture:** All research output paths in agent definitions, commands, skills, and templates change from `.startup/docs/` to `docs/{category}/`. Auto-commit hook stops committing gitignored ephemeral state and starts committing docs/ writes. A new `/bootstrap` command initializes project structure without starting the loop.

**Tech Stack:** Bash (hook scripts), Markdown (commands/skills/agents/templates)

**Spec:** `docs/superpowers/specs/2026-03-30-knowledge-management-design.md`

---

## File Map

**Create:**
- `plugins/saas-startup-team/commands/bootstrap.md` — new /bootstrap command

**Modify:**
- `plugins/saas-startup-team/agents/business-founder.md` — research output paths
- `plugins/saas-startup-team/agents/tech-founder.md` — architecture doc path
- `plugins/saas-startup-team/agents/lawyer.md` — legal output paths, context paths
- `plugins/saas-startup-team/agents/ux-tester.md` — brief path
- `plugins/saas-startup-team/commands/startup.md` — directory structure, call bootstrap
- `plugins/saas-startup-team/commands/lawyer.md` — context paths
- `plugins/saas-startup-team/commands/ux-test.md` — context paths
- `plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md` — UX doc path
- `plugins/saas-startup-team/skills/business-founder/references/market-research.md` — output path
- `plugins/saas-startup-team/skills/tech-founder/SKILL.md` — architecture doc path
- `plugins/saas-startup-team/templates/handoff-business-to-tech.md` — research references
- `plugins/saas-startup-team/scripts/auto-commit.sh` — stop committing ephemeral, add docs/ commits
- `plugins/saas-startup-team/scripts/enforce-delegation.sh` — allow orchestrator to write docs/
- `plugins/saas-startup-team/.claude-plugin/plugin.json` — version bump
- `.claude-plugin/marketplace.json` — version bump

**No changes needed** (confirmed by reading): nudge.md (no .startup/docs refs), loop-control.md (only state.json refs which stay), handoff-protocol.md (only .startup/handoffs refs which stay), business-founder SKILL.md (no direct paths), lawyer SKILL.md (no direct paths), ux-tester SKILL.md (no direct paths), tech-founder references/architecture.md (no direct paths), startup-brief.md template (no paths, just placeholders).

---

## Task 1: Update Agent Definitions (4 files)

**Files:**
- Modify: `plugins/saas-startup-team/agents/business-founder.md:47,67,71-72,77,80,85,89`
- Modify: `plugins/saas-startup-team/agents/tech-founder.md:51`
- Modify: `plugins/saas-startup-team/agents/lawyer.md:94,184`
- Modify: `plugins/saas-startup-team/agents/ux-tester.md:49`

- [ ] **Step 1: Update business-founder.md research output paths**

In `plugins/saas-startup-team/agents/business-founder.md`, replace the research output block:

```
old_string:
- Save all findings to `.startup/docs/` (written in Estonian, but filenames use ASCII-only — no diacritics in filenames for cross-platform compatibility):
  - `turu-uurimine.md` — market research
  - `kliendi-tagasiside.md` — customer feedback and pain points
  - `konkurentsianaluus.md` — competition analysis
  - `hinnastrateegia.md` — pricing strategy
  - `oiguslik-analuus.md` — legal analysis
  - `rahvusvaheline-analuus.md` — international benchmarking

new_string:
- Save all findings to `docs/` subdirectories (written in Estonian, but filenames use ASCII-only — no diacritics in filenames for cross-platform compatibility):
  - `docs/research/turu-uurimine.md` — market research
  - `docs/research/kliendi-tagasiside.md` — customer feedback and pain points
  - `docs/research/konkurentsianaluus.md` — competition analysis
  - `docs/business/hinnastrateegia.md` — pricing strategy
  - `docs/legal/oiguslik-analuus.md` — legal analysis
  - `docs/research/rahvusvaheline-analuus.md` — international benchmarking
```

- [ ] **Step 2: Update business-founder.md review notes path**

```
old_string:
- Write browser review notes to `.startup/reviews/`

new_string:
- Write browser review notes to `.startup/reviews/` (ephemeral, not git-tracked)
```

- [ ] **Step 3: Update business-founder.md git commits section**

```
old_string:
Work is auto-committed when handoff files are written by the plugin hook. Ensure all research documents in `.startup/docs/` are saved before writing your handoff — the hook stages everything in the repo.

new_string:
Work is auto-committed when research documents are written to `docs/`. Handoffs in `.startup/` are ephemeral and not git-tracked. Ensure all research documents in `docs/` are saved before writing your handoff.
```

- [ ] **Step 4: Update business-founder.md handoff protocol reference**

```
old_string:
4. Reference your research docs in `.startup/docs/`

new_string:
4. Reference your research docs in `docs/` (e.g., `docs/research/turu-uurimine.md`)
```

- [ ] **Step 5: Update tech-founder.md architecture path**

In `plugins/saas-startup-team/agents/tech-founder.md`:

```
old_string:
- Document architecture decisions in `.startup/docs/architecture.md`

new_string:
- Document architecture decisions in `docs/architecture/architecture.md`
```

- [ ] **Step 6: Update lawyer.md context paths**

In `plugins/saas-startup-team/agents/lawyer.md`:

```
old_string:
1. **Project context** — read `.startup/brief.md`, `.startup/docs/`, `.startup/handoffs/` to understand what SaaS is being built

new_string:
1. **Project context** — read `docs/business/brief.md`, `docs/`, `.startup/handoffs/` to understand what SaaS is being built
```

- [ ] **Step 7: Update lawyer.md output path**

```
old_string:
    → Write to .startup/docs/õiguslik-*.md

new_string:
    → Write to docs/legal/õiguslik-*.md
```

- [ ] **Step 8: Update ux-tester.md brief path**

In `plugins/saas-startup-team/agents/ux-tester.md`:

```
old_string:
1. Read `.startup/brief.md` to understand what the product does and who uses it

new_string:
1. Read `docs/business/brief.md` to understand what the product does and who uses it
```

- [ ] **Step 9: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/saas-startup-team/agents/
git commit -m "refactor: update agent research output paths from .startup/docs/ to docs/"
```

---

## Task 2: Update Commands (3 files)

**Files:**
- Modify: `plugins/saas-startup-team/commands/startup.md:32-43,58`
- Modify: `plugins/saas-startup-team/commands/lawyer.md:59-63,71`
- Modify: `plugins/saas-startup-team/commands/ux-test.md:57-60`

- [ ] **Step 1: Update startup.md directory structure**

In `plugins/saas-startup-team/commands/startup.md`, replace the directory structure block:

```
old_string:
Create the `.startup/` directory structure:

```
.startup/
├── brief.md              ← Fill with user's SaaS idea
├── state.json            ← Initialize loop state
├── human-tasks.md        ← Copy from ${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md
├── handoffs/             ← Empty, will fill during iterations
├── docs/                 ← Empty, business founder will populate
├── signoffs/             ← Empty, will fill as features are validated
├── reviews/              ← Empty, browser review notes go here
└── go-live/              ← Empty, solution signoff goes here
```

new_string:
Run `/bootstrap` first (idempotent — safe to re-run). This creates:
- `docs/` subdirectories: `research/`, `legal/`, `architecture/`, `ux/`, `seo/`, `business/`
- `.startup/` subdirectories: `handoffs/`, `reviews/`, `signoffs/`, `go-live/`
- `.gitignore` entries for ephemeral `.startup/` state
- `## Project Knowledge` and `## Workflow Guidance` sections in CLAUDE.md

Then create the loop-specific files in `.startup/`:

```
.startup/
├── state.json            ← Initialize loop state
├── human-tasks.md        ← Copy from ${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md
├── handoffs/             ← Ephemeral, not git-tracked
├── signoffs/             ← Ephemeral, not git-tracked
├── reviews/              ← Ephemeral, not git-tracked
└── go-live/              ← Ephemeral, not git-tracked
```
```

- [ ] **Step 2: Update startup.md brief path**

```
old_string:
Write `brief.md` using the user's SaaS idea description.

new_string:
Write `docs/business/brief.md` using the user's SaaS idea description (skip if `/bootstrap` already created it).
```

- [ ] **Step 3: Update lawyer.md context paths**

In `plugins/saas-startup-team/commands/lawyer.md`:

```
old_string:
Read the following files to build context for the Lawyer:
1. `.startup/brief.md` — what SaaS is being built
2. `.startup/state.json` — current project phase and iteration
3. Latest files in `.startup/docs/` — business founder's research
4. Latest handoff in `.startup/handoffs/` — current state of implementation

new_string:
Read the following files to build context for the Lawyer:
1. `docs/business/brief.md` — what SaaS is being built
2. `.startup/state.json` — current project phase and iteration
3. Latest files in `docs/` — research, legal, architecture docs
4. Latest handoff in `.startup/handoffs/` — current state of implementation
```

- [ ] **Step 4: Update lawyer.md output reminder**

```
old_string:
- Reminder: write analysis to `.startup/docs/õiguslik-*.md` in Estonian

new_string:
- Reminder: write analysis to `docs/legal/õiguslik-*.md` in Estonian
```

- [ ] **Step 5: Update ux-test.md context paths**

In `plugins/saas-startup-team/commands/ux-test.md`:

```
old_string:
Read the following files to build context for the UX Tester:
1. `.startup/brief.md` — what SaaS is being built, target users
2. `.startup/state.json` — current project phase and iteration
3. `.startup/docs/architecture.md` — tech stack, service URLs
4. Latest handoff in `.startup/handoffs/` — current state of implementation

new_string:
Read the following files to build context for the UX Tester:
1. `docs/business/brief.md` — what SaaS is being built, target users
2. `.startup/state.json` — current project phase and iteration
3. `docs/architecture/architecture.md` — tech stack, service URLs
4. Latest handoff in `.startup/handoffs/` — current state of implementation
```

- [ ] **Step 6: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/saas-startup-team/commands/
git commit -m "refactor: update command context paths from .startup/docs/ to docs/"
```

---

## Task 3: Update Skills and Templates (3 files)

**Files:**
- Modify: `plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md:95`
- Modify: `plugins/saas-startup-team/skills/business-founder/references/market-research.md:87`
- Modify: `plugins/saas-startup-team/skills/tech-founder/SKILL.md:48`
- Modify: `plugins/saas-startup-team/templates/handoff-business-to-tech.md:39-43`

- [ ] **Step 1: Update team-patterns.md UX output path**

In `plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md`:

```
old_string:
The UX Tester writes findings to `.startup/docs/ux-*.md`. The team lead then:

new_string:
The UX Tester writes findings to `docs/ux/ux-*.md`. The team lead then:
```

- [ ] **Step 2: Update market-research.md output path**

In `plugins/saas-startup-team/skills/business-founder/references/market-research.md`:

```
old_string:
Save findings to `.startup/docs/rahvusvaheline-analuus.md` using Estonian field names:

new_string:
Save findings to `docs/research/rahvusvaheline-analuus.md` using Estonian field names:
```

- [ ] **Step 3: Update tech-founder SKILL.md architecture path**

In `plugins/saas-startup-team/skills/tech-founder/SKILL.md`:

```
old_string:
Document ALL decisions in `.startup/docs/architecture.md`.

new_string:
Document ALL decisions in `docs/architecture/architecture.md`.
```

- [ ] **Step 4: Update handoff template research references**

In `plugins/saas-startup-team/templates/handoff-business-to-tech.md`:

```
old_string:
Links to working documents in `.startup/docs/`:
- Market research: `.startup/docs/turu-uurimine.md`
- Customer feedback: `.startup/docs/kliendi-tagasiside.md`
- Competition analysis: `.startup/docs/konkurentsianaluus.md`
- International analysis: `.startup/docs/rahvusvaheline-analuus.md`

new_string:
Links to working documents in `docs/`:
- Market research: `docs/research/turu-uurimine.md`
- Customer feedback: `docs/research/kliendi-tagasiside.md`
- Competition analysis: `docs/research/konkurentsianaluus.md`
- International analysis: `docs/research/rahvusvaheline-analuus.md`
```

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/saas-startup-team/skills/ plugins/saas-startup-team/templates/
git commit -m "refactor: update skill and template paths from .startup/docs/ to docs/"
```

---

## Task 4: Update Hook Scripts (2 files)

**Files:**
- Modify: `plugins/saas-startup-team/scripts/auto-commit.sh`
- Modify: `plugins/saas-startup-team/scripts/enforce-delegation.sh`

- [ ] **Step 1: Rewrite auto-commit.sh**

Replace the entire file. The new version:
- Removes handoff/signoff/review commit triggers (those files are gitignored now)
- Adds `docs/` write detection for auto-committing research
- Keeps the same hook interface (stdin JSON, exit codes)

Write `plugins/saas-startup-team/scripts/auto-commit.sh`:

```bash
#!/bin/bash
# auto-commit.sh — PostToolUse hook for Write events
# Auto-commits work when durable knowledge files are written to docs/.
#
# Ephemeral files (.startup/handoffs/, .startup/reviews/, .startup/signoffs/)
# are gitignored and NOT auto-committed.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: no action (non-docs file or no git repo)
# Exit 2: committed work, systemMessage on stderr

set -euo pipefail

# Read JSON from stdin
input=$(cat)

# Extract file_path from tool_input
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Determine commit type from file path
filename=$(basename "$file_path")
commit_msg=""

if echo "$file_path" | grep -qE 'docs/research/.*\.md$'; then
  commit_msg="research: ${filename%.md}"
elif echo "$file_path" | grep -qE 'docs/legal/.*\.md$'; then
  commit_msg="legal: ${filename%.md}"
elif echo "$file_path" | grep -qE 'docs/architecture/.*\.md$'; then
  commit_msg="architecture: ${filename%.md}"
elif echo "$file_path" | grep -qE 'docs/ux/.*\.md$'; then
  commit_msg="ux: ${filename%.md}"
elif echo "$file_path" | grep -qE 'docs/seo/.*\.md$'; then
  commit_msg="seo: ${filename%.md}"
elif echo "$file_path" | grep -qE 'docs/business/.*\.md$'; then
  commit_msg="business: ${filename%.md}"
elif echo "$file_path" | grep -qE '\.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$'; then
  # Handoffs are gitignored but we still auto-commit implementation code
  # that was changed alongside the handoff
  handoff_num=$(echo "$filename" | grep -oE '^[0-9]{3}')
  direction=$(echo "$filename" | sed 's/^[0-9]*-//; s/\.md$//')
  case "$direction" in
    business-to-tech) founder="business-founder" ;;
    tech-to-business) founder="tech-founder" ;;
    *) founder="unknown" ;;
  esac
  commit_msg="${founder}: handoff ${handoff_num} — ${direction}"
else
  # Not a milestone file — skip
  exit 0
fi

# Find git repo root — if not in a git repo, exit silently
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Stage docs/ and implementation files (avoid staging sensitive files like .env)
cd "$repo_root"
git add -A docs/ || true
git add -A backend/ frontend/ || true
git add -A CLAUDE.md || true

# Check if there's anything to commit
if git diff --cached --quiet 2>/dev/null; then
  # Nothing staged — skip
  exit 0
fi

# Commit with --no-verify to skip project-level pre-commit hooks
git commit -m "${commit_msg}" --no-verify || true

# Signal to Claude that we committed
echo '{"systemMessage":"Auto-committed all work: '"${commit_msg}"'"}' >&2
exit 2
```

- [ ] **Step 2: Update enforce-delegation.sh to allow docs/**

In `plugins/saas-startup-team/scripts/enforce-delegation.sh`, add a docs/ check after the .startup/ check:

```
old_string:
# Main orchestrator: only allow writes to .startup/, CLAUDE.md, and plugin files
if [[ "$file_path" =~ \.startup/ ]]; then
  exit 0
fi

new_string:
# Main orchestrator: only allow writes to .startup/, docs/, CLAUDE.md, and plugin files
if [[ "$file_path" =~ \.startup/ ]]; then
  exit 0
fi

if [[ "$file_path" =~ docs/ ]]; then
  exit 0
fi
```

- [ ] **Step 3: Update enforce-delegation.sh error message**

```
old_string:
{"systemMessage":"You are the team lead/orchestrator. Do NOT edit implementation code directly — delegate to the tech founder via a handoff document instead. Write your requirements to .startup/handoffs/NNN-business-to-tech.md and let the tech founder implement. Only .startup/ and CLAUDE.md files may be edited by the orchestrator."}

new_string:
{"systemMessage":"You are the team lead/orchestrator. Do NOT edit implementation code directly — delegate to the tech founder via a handoff document instead. Write your requirements to .startup/handoffs/NNN-business-to-tech.md and let the tech founder implement. Only .startup/, docs/, and CLAUDE.md files may be edited by the orchestrator."}
```

- [ ] **Step 4: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/saas-startup-team/scripts/auto-commit.sh plugins/saas-startup-team/scripts/enforce-delegation.sh
git commit -m "refactor: update hooks — auto-commit docs/ writes, allow orchestrator docs/ access"
```

---

## Task 5: Create /bootstrap Command

**Files:**
- Create: `plugins/saas-startup-team/commands/bootstrap.md`

- [ ] **Step 1: Write the bootstrap command**

Write `plugins/saas-startup-team/commands/bootstrap.md`:

```markdown
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
mkdir -p docs/{research,legal,architecture,ux,seo,business}
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
```

- [ ] **Step 2: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/saas-startup-team/commands/bootstrap.md
git commit -m "feat: add /bootstrap command for project initialization"
```

---

## Task 6: Update /startup to Call /bootstrap

**Files:**
- Modify: `plugins/saas-startup-team/commands/startup.md`

- [ ] **Step 1: Add bootstrap call before directory creation**

At the very beginning of the startup command's Step 2 (after the re-initialization guard), add a bootstrap call. The existing directory creation block was already replaced in Task 2 Step 1. Now ensure the startup command explicitly calls bootstrap:

Read the current state of `commands/startup.md` to find the exact insertion point after the re-initialization guard (the "If resuming, skip to Step 3" line).

The block that was replaced in Task 2 Step 1 already includes "Run `/bootstrap` first". Verify this is present. If so, no additional edit is needed for bootstrap integration.

- [ ] **Step 2: Verify the startup.md brief path was updated in Task 2**

Confirm that `commands/startup.md` now references `docs/business/brief.md` instead of `.startup/brief.md`. This was done in Task 2 Step 2.

- [ ] **Step 3: No commit needed** — changes already committed in Task 2.

---

## Task 7: Version Bump

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json**

In `plugins/saas-startup-team/.claude-plugin/plugin.json`:

```
old_string:
"version": "0.12.0"

new_string:
"version": "0.13.0"
```

- [ ] **Step 2: Bump marketplace.json**

In `.claude-plugin/marketplace.json`, find the saas-startup-team entry:

```
old_string:
      "version": "0.12.0",
      "author": {
        "name": "Andre Paat"
      },
      "source": "./plugins/saas-startup-team",

new_string:
      "version": "0.13.0",
      "author": {
        "name": "Andre Paat"
      },
      "source": "./plugins/saas-startup-team",
```

- [ ] **Step 3: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump saas-startup-team to 0.13.0"
```

---

## Task 8: Verify All Path References Updated

- [ ] **Step 1: Grep for remaining .startup/docs references**

```bash
cd /mnt/data/ai/claude-plugins
grep -r '\.startup/docs' plugins/saas-startup-team/ --include='*.md' --include='*.sh'
```

Expected: **zero matches**. If any remain, fix them.

- [ ] **Step 2: Grep for remaining .startup/brief references**

```bash
grep -r '\.startup/brief' plugins/saas-startup-team/ --include='*.md' --include='*.sh'
```

Expected: **zero matches**. If any remain, fix them.

- [ ] **Step 3: Grep for docs/ paths to verify new references exist**

```bash
grep -r 'docs/' plugins/saas-startup-team/ --include='*.md' --include='*.sh' | grep -v 'docs/plans/' | grep -v 'docs/superpowers/' | head -30
```

Expected: multiple matches in agents, commands, skills, templates showing the new `docs/research/`, `docs/legal/`, `docs/architecture/`, `docs/business/`, `docs/ux/`, `docs/seo/` paths.

- [ ] **Step 4: Fix any remaining references and commit**

If Step 1 or 2 found matches, fix them and commit:

```bash
git add -A plugins/saas-startup-team/
git commit -m "fix: remaining .startup/docs path references"
```

---

## Task 9: Test /bootstrap Command Manually

- [ ] **Step 1: Create a temporary test directory**

```bash
mkdir -p /tmp/test-bootstrap
cd /tmp/test-bootstrap
git init
```

- [ ] **Step 2: Run the bootstrap logic manually**

Execute the bootstrap steps from the command to verify they work:

```bash
# Step 1: Create directories
mkdir -p docs/{research,legal,architecture,ux,seo,business}
mkdir -p .startup/{handoffs,reviews,signoffs,go-live}

# Step 2: Create .gitkeep
touch .startup/.gitkeep

# Step 3: Verify structure
find docs/ -type d | sort
find .startup/ -type d | sort
ls -la .startup/.gitkeep
```

Expected output:
```
docs/architecture
docs/business
docs/legal
docs/research
docs/seo
docs/ux
.startup/go-live
.startup/handoffs
.startup/reviews
.startup/signoffs
```

- [ ] **Step 3: Test idempotency**

Run the same mkdir commands again — should succeed silently with no errors:

```bash
mkdir -p docs/{research,legal,architecture,ux,seo,business}
mkdir -p .startup/{handoffs,reviews,signoffs,go-live}
echo $?
```

Expected: `0`

- [ ] **Step 4: Test .gitignore entries work**

```bash
cat > .gitignore << 'GITIGNORE'
.startup/state.json
.startup/handoffs/
.startup/reviews/
.startup/signoffs/
.startup/go-live/
.startup/human-tasks.md
.startup/test-data/
.startup/.idle-*
GITIGNORE

# Create ephemeral files
echo '{"iteration":0}' > .startup/state.json
echo "# Test" > .startup/handoffs/001-business-to-tech.md
echo "# Test" > .startup/human-tasks.md

# Create tracked files
echo "# Brief" > docs/business/brief.md
echo "# Architecture" > docs/architecture/architecture.md

# Stage everything
git add -A
git status
```

Expected: `docs/business/brief.md`, `docs/architecture/architecture.md`, `.gitignore`, and `.startup/.gitkeep` are staged. `.startup/state.json`, `.startup/handoffs/`, `.startup/human-tasks.md` are NOT staged (gitignored).

- [ ] **Step 5: Clean up**

```bash
rm -rf /tmp/test-bootstrap
```

---

## Task 10: Final Commit and Summary

- [ ] **Step 1: Verify clean state**

```bash
cd /mnt/data/ai/claude-plugins
git status
git log --oneline -10
```

Expected: All changes committed across Tasks 1-7. No uncommitted changes.

- [ ] **Step 2: Review commit history**

Verify the commits make sense:
1. `refactor: update agent research output paths from .startup/docs/ to docs/`
2. `refactor: update command context paths from .startup/docs/ to docs/`
3. `refactor: update skill and template paths from .startup/docs/ to docs/`
4. `refactor: update hooks — auto-commit docs/ writes, allow orchestrator docs/ access`
5. `feat: add /bootstrap command for project initialization`
6. `chore: bump saas-startup-team to 0.13.0`
