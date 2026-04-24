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

## Prerequisites

- Claude Code with Agent Teams support (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- Playwright MCP (`@playwright/mcp`) — automatically configured via plugin `.mcp.json`, runs headless
- Web access enabled (for business founder's market research)
- **Linux environment** — hooks use `/proc/` for process tree detection (Docker containers work)

## Key Design Decisions

- **Information asymmetry**: Tech founder has no web access, forcing the business founder to be thorough
- **File-based state**: Handoff documents carry context between iterations, not LLM memory
- **Quality gates**: Hooks enforce handoff writing, deliverable validation, and solution signoff
- **Non-blocking human tasks**: Tasks for the investor are documented but don't stop the loop
- **Estonian working language**: Business founder thinks and researches in Estonian, translates for handoffs
