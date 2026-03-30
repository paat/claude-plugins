# Knowledge Management Redesign — saas-startup-team Plugin

**Date:** 2026-03-30
**Status:** Approved
**Scope:** Plugin changes + per-project migration guide (est-biz-aruannik as first target)

---

## Problem

The saas-startup-team plugin stores all artifacts in `.startup/`, a dotfile directory that is:

1. **Invisible to plain Claude Code sessions** — research, legal analysis, pricing strategy, and architecture docs are buried where only the plugin loop finds them
2. **Bloating git history** — operational churn (handoffs, reviews with PNGs, state.json) is git-tracked, wasting repo space and review tokens
3. **Mixing durable knowledge with ephemeral state** — market research and handoff #247 sit side by side with no distinction

Real-world impact (est-biz-aruannik): 39 MB in `.startup/`, 437 commits touching it, 35 MB of review PNGs in git history, 364 handoff files tracked across 337 commits.

## Goals

- Any Claude Code session (plugin or plain) can find and use project research
- Operational loop state never hits git
- Clear guidance on when to use the plugin loop vs plain Claude Code
- New projects get proper structure from day one via `/bootstrap`

## Non-Goals

- Automated staleness detection for research docs (future work)
- Auto-generated knowledge index (future work)
- Changing the handoff protocol, loop control, or agent lifecycle

---

## Design

### 1. Knowledge Location Restructure

**Durable knowledge moves to `docs/` at repo root (git-tracked):**

```
docs/
├── research/        ← market size, customer pain points, competition, international
├── legal/           ← GDPR, Estonian business law, compliance analyses
├── architecture/    ← tech stack decisions, system design rationale
├── ux/              ← UX audit findings, accessibility gaps
├── seo/             ← keyword strategy, content optimization research
└── business/        ← brief, pricing strategy, business plans
```

**Ephemeral loop state stays in `.startup/` (gitignored):**

```
.startup/
├── state.json
├── handoffs/
├── reviews/
├── signoffs/
├── go-live/
├── human-tasks.md
└── .idle-*
```

**File mapping from current to new:**

| Current | New | Rationale |
|---|---|---|
| `.startup/docs/turu-uurimine.md` | `docs/research/turu-uurimine.md` | Market research is durable |
| `.startup/docs/kliendi-tagasiside.md` | `docs/research/kliendi-tagasiside.md` | Customer feedback is durable |
| `.startup/docs/konkurentsianaluus.md` | `docs/research/konkurentsianaluus.md` | Competition analysis is durable |
| `.startup/docs/rahvusvaheline-analuus.md` | `docs/research/rahvusvaheline-analuus.md` | International benchmarking is durable |
| `.startup/docs/hinnastrateegia.md` | `docs/business/hinnastrateegia.md` | Pricing is durable |
| `.startup/docs/oiguslik-*.md` | `docs/legal/` | Legal analyses are durable |
| `.startup/docs/architecture*.md` | `docs/architecture/` | Architecture decisions are durable |
| `.startup/docs/ux-*.md` | `docs/ux/` | UX findings are durable |
| `.startup/docs/seo-*.md` | `docs/seo/` | SEO research is durable |
| `.startup/brief.md` | `docs/business/brief.md` | Project brief is foundational |
| `.startup/handoffs/*` | stays in `.startup/` | Operational churn, gitignored |
| `.startup/reviews/*` | stays in `.startup/` | Screenshots, gitignored |
| `.startup/state.json` | stays in `.startup/` | Ephemeral state, gitignored |
| `.startup/signoffs/*` | stays in `.startup/` | Milestone approvals, gitignored |
| `.startup/go-live/*` | stays in `.startup/` | Solution signoff, gitignored |

### 2. .gitignore Changes

Append to `.gitignore` in projects using the plugin:

```gitignore
# Startup plugin operational state (ephemeral, not knowledge)
.startup/state.json
.startup/handoffs/
.startup/reviews/
.startup/signoffs/
.startup/go-live/
.startup/human-tasks.md
.startup/.idle-*
```

### 3. Git History Cleanup (Per-Project Migration)

For existing projects (est-biz-aruannik), use `git filter-repo` to remove from all history:

- `.startup/handoffs/` — 364 files, 337 commits of diffs
- `.startup/reviews/` — 323 files, 35 MB of PNGs
- `.startup/state.json` — 301 commits of JSON churn
- `.startup/signoffs/`
- `.startup/go-live/`
- `.startup/.idle-*`

Keep in history: `.startup/docs/` (moved to `docs/` in a final commit), `.startup/brief.md`.

Requires force push. One-time, irreversible operation. Local files remain on disk.

### 4. CLAUDE.md Integration

`/bootstrap` adds two sections to CLAUDE.md:

#### Project Knowledge section

```markdown
## Project Knowledge

Research and design decisions live in `docs/`. Consult these before making changes:

- **Business brief**: `docs/business/brief.md` — what we're building and why
- **Pricing**: `docs/business/hinnastrateegia.md` — pricing tiers and rationale
- **Market research**: `docs/research/` — market size, customer pain points, competition
- **Legal/compliance**: `docs/legal/` — GDPR, Estonian business law, AI categorization
- **Architecture**: `docs/architecture/` — tech stack decisions and rationale
- **UX findings**: `docs/ux/` — audit results, accessibility gaps
- **SEO research**: `docs/seo/` — keyword strategy, content optimization

When adding features or changing behavior, check relevant docs first.
When completing research, save findings to the appropriate `docs/` subdirectory.
```

Note: The specific file pointers (like `hinnastrateegia.md`) are examples — `/bootstrap` generates these by scanning what actually exists in `docs/`.

#### Workflow Guidance section

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

### 5. New `/bootstrap` Command

**Purpose:** Initialize project structure for the plugin without starting the agent loop. Idempotent.

**Steps:**
1. Create `docs/` subdirectories if missing: `research/`, `legal/`, `architecture/`, `ux/`, `seo/`, `business/`
2. Create `.startup/` subdirectories if missing: `handoffs/`, `reviews/`, `signoffs/`, `go-live/`
3. Append ephemeral state entries to `.gitignore` if not present
4. Add `## Project Knowledge` and `## Workflow Guidance` to CLAUDE.md if not present
5. Prompt for project brief, save to `docs/business/brief.md` (skip if exists)
6. Initialize git repo if needed, commit scaffolding

**Does NOT:** start the agent loop, create `state.json`, spawn agents.

**`/startup` calls `/bootstrap` first** (idempotent), then proceeds with loop initialization.

### 6. Plugin Component Changes

#### Agent Definitions

**business-founder.md:**
- Research output path: `.startup/docs/` → `docs/research/`, `docs/business/`, `docs/legal/`
- Named files stay the same (e.g., `turu-uurimine.md`), just in new directories

**tech-founder.md:**
- Architecture output: `.startup/docs/architecture.md` → `docs/architecture/architecture.md`

**lawyer.md:**
- Legal analysis output: `.startup/docs/õiguslik-*.md` → `docs/legal/õiguslik-*.md`

**ux-tester.md:**
- UX findings output: `.startup/docs/ux-*.md` → `docs/ux/`

#### Hooks

**auto-commit.sh:**
- Stop auto-committing handoffs, reviews, signoffs (gitignored now)
- Add auto-commit for `docs/` writes (research is worth tracking)

**enforce-delegation.sh:**
- Orchestrator allowed paths: add `docs/` alongside `.startup/` and `CLAUDE.md`

**auto-learn.sh:**
- No change — still fires on local handoff writes, still appends to CLAUDE.md `## Learnings`

**All other hooks:** No changes.

#### Templates

- `startup-brief.md` output path → `docs/business/brief.md`
- Handoff templates: research references update from `.startup/docs/` to `docs/`

#### Scripts

- `status.sh` — no change (reads local `.startup/state.json`)

---

## Migration Guide (Existing Projects)

For est-biz-aruannik and any project already using the plugin:

1. Move `.startup/docs/*` → `docs/` subdirectories (categorize files)
2. Move `.startup/brief.md` → `docs/business/brief.md`
3. Update `.gitignore`
4. Add `## Project Knowledge` and `## Workflow Guidance` to CLAUDE.md
5. Commit the moves
6. Run `git filter-repo` to remove ephemeral files from history
7. Force push

Steps 1-5 are safe and reversible. Step 6-7 are destructive and one-time.

---

## Version

This is a minor version bump: 0.12.0 → 0.13.0. The handoff protocol, loop control, and agent lifecycle are unchanged. Only file paths and gitignore behavior change.
