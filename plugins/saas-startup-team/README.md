# saas-startup-team

A Claude Code plugin that simulates a two-person SaaS startup team using **Agent Teams** (experimental). A non-technical business co-founder and a technical developer co-founder iterate via file-based handoffs until both agree the product is ready to go live.

## How It Works

The human user is a **silent investor** — they describe a SaaS idea and watch two AI co-founders build it:

- **Business Founder** (blue): Does all real-world research (web, Reddit, browser). Defines requirements, verifies implementations via browser. Speaks Estonian to the investor, English to the developer.
- **Tech Founder** (green): Pure builder. No web access — relies only on LLM training knowledge and the business founder's handoff documents. Stops and asks when the "why" is unclear.
- **Lawyer** (magenta): On-demand legal consultant. Reviews compliance, GDPR, contracts, and Estonian business law. Invoked via `/lawyer`.
- **UX Tester** (cyan): On-demand usability auditor. Runs browser-based accessibility and UX audits against live pages. Invoked via `/ux-test`.

The founders iterate through structured file-based handoffs until the business founder declares the product ready for customers.

## Architecture

```
Human (Silent Investor)
  ↓ describes SaaS idea
  ↓ /saas-startup-team:startup
Team Lead (Orchestrator)
  ├── Business Founder (teammate, web + browser access)
  ├── Tech Founder (teammate, code tools only)
  ├── Shared TaskList
  └── File-based handoffs in .startup/
```

## Commands

| Command | Purpose |
|---------|---------|
| `/saas-startup-team:startup` | Initialize project, spawn agent team, start the loop |
| `/saas-startup-team:status` | Show iteration count, handoff history, human tasks |
| `/saas-startup-team:nudge` | Unstick a deadlock or redirect a founder |
| `/saas-startup-team:lawyer` | Spawn lawyer agent for legal/compliance review |
| `/saas-startup-team:ux-test` | Spawn UX tester for accessibility and usability audit |
| `/saas-startup-team:improve` | One-shot improvements on a completed product |
| `/saas-startup-team:goal-deliver` | Deliver a set of tasks (issues, milestone, spec, or free text) end-to-end: plan into chunks, ship each via `/improve` + closing tribunal loop + merge to main, then monitor and fix the GitHub Actions deploy. Pairs with built-in `/goal` for autonomy. Requires the `tribunal-review` plugin. |
| `/saas-startup-team:ads` | Design a Google Ads campaign — spawns the `google-ads-strategist` plugin's `ads-strategist` (hard dependency) to design, browser-verify, and create the campaign in PAUSED state for investor review. The `/growth` loop also delegates here automatically. |

## The Loop

```
Business Founder: research → requirements → handoff
  ↓
Tech Founder: read handoff → implement → handoff back
  ↓
Business Founder: browser verification → signoff or feedback
  ↓
[repeat for each feature]
  ↓
Business Founder: solution signoff → GO LIVE
```

## Signoff System

Two levels:
1. **Roundtrip Signoff**: Per-feature validation (requirement → implementation → browser QA → signoff)
2. **Solution Signoff**: The business founder declares the entire product customer-ready

Only the business founder can end the loop — they are the customer's voice.

## File Structure

The `.startup/` directory is created at project root:

```
.startup/
├── brief.md              # Investor's SaaS idea
├── state.json            # Loop state (iteration, phase, active role) — auto-compacted
├── state-archive.json    # Historical keys moved out of state.json (append-only)
├── human-tasks.md        # Tasks only the human can do (non-blocking)
├── handoffs/             # Structured handoff documents
├── docs/                 # Research documents (Estonian)
├── signoffs/             # Per-feature roundtrip signoffs
├── reviews/              # Browser verification notes
└── go-live/              # Solution signoff (ends the loop)
```

### state.json compaction

`state.json` uses schema v2. A PostToolUse hook runs `compact-state.sh` after every Write and archives old handoff keys (`handoff_NNN_*`) plus other non-allowlisted entries into `state-archive.json` once the inline window (last 10 handoffs) is exceeded. The inline state stays under ~30 lines regardless of project age. Run `/status --compact --yes` on existing projects to migrate one-shot (a timestamped `.bak` is written first). Tune the window with `STARTUP_INLINE_HANDOFFS=N` if needed.

### Learnings capture

A PostToolUse hook (`auto-learn.sh`) fires after every handoff/review/signoff/go-live write under `.startup/` and extracts up to 3 reusable project learnings into `CLAUDE.md`. Entries that clearly fit an existing `docs/learnings/<topic>.md` file are routed there directly; uncertain or new-topic learnings stage in the `### Recent (unsorted)` section of `CLAUDE.md`.

To keep `CLAUDE.md` lean, the hook caps `### Recent (unsorted)` at **10 entries** (tune with `SAAS_LEARNINGS_MAX=N`). It counts the staged bullets deterministically in bash, and once the section nears the cap the same systemMessage instructs Claude to migrate the surplus (oldest first) into the best-fit `docs/learnings/` topic file — creating the file and a `## Domain Learnings` index line when no topic fits — so the staging area self-heals back to ≤ cap. Run `/saas-startup-team:learnings-migrate` for a human-in-the-loop sweep of whatever remains.

### Google Ads records

Google Ads campaigns live under `docs/ads/<campaign>/` (owned by the `google-ads-strategist` plugin — briefs, iterations, verification screenshots, learnings). `docs/growth/channels/ads.md` is a lightweight index into them (campaign slug, status, link) and retains the `Approved budget:` / `Total spend:` summary lines the budget hard-stop hook reads. Meta/LinkedIn ads are logged inline in `ads.md`.

## Prerequisites

- Claude Code with Agent Teams support (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- Playwright MCP (`@playwright/mcp`) — automatically configured via plugin `.mcp.json`, runs headless
- Web access enabled (for business founder's market research)
- **Linux environment** — hooks use `/proc/` for process tree detection (Docker containers work)
- **`jq` and `awk`** — required by hook scripts (`auto-learn.sh`, state compaction, JSON validation)
- **google-ads-strategist plugin** — required for any Google Ads work (hard dependency). Google Ads is delegated to its `ads-strategist` agent; `growth-hacker` no longer creates Google Ads campaigns itself. There is no manifest-level dependency field, so this is enforced behaviorally: `/ads` and the `/growth` loop fail with an install instruction if the plugin is absent.

## Key Design Decisions

- **Information asymmetry**: Tech founder has no web access, forcing the business founder to be thorough
- **File-based state**: Handoff documents carry context between iterations, not LLM memory
- **Quality gates**: Hooks enforce handoff writing, deliverable validation, and solution signoff
- **Pre-merge safety net**: `/bootstrap` scaffolds a canonical `check.sh` full-suite entrypoint and a `pull_request` CI workflow, and queues a branch-protection task.
- **Non-blocking human tasks**: Tasks for the investor are documented but don't stop the loop
- **Estonian working language**: Business founder thinks and researches in Estonian, translates for handoffs
