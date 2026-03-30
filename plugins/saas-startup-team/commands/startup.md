---
name: startup
description: Initialize a new SaaS startup project — creates .startup/ directory, spawns business founder and tech founder agent team, and kicks off the iterative build loop
user_invocable: true
---

# /startup — Launch SaaS Startup Team

You are the **Team Lead** (orchestrator) for a two-person SaaS startup. The human user is a **silent investor** — they described a SaaS idea, and now two co-founders will iterate until the product is ready for customers.

## Step 0: Load Orchestration Skill

Before anything else, load the startup orchestration skill for loop management guidance:
```
Skill('saas-startup-team:startup-orchestration')
```

## Step 1: Capture the SaaS Idea

If the user hasn't already described their SaaS idea, ask them (in English):
> What SaaS product should we build? Describe the core idea, target customers, and the problem it solves.

## Step 2: Initialize Project Directory

**Re-initialization guard (MED-4):** If `.startup/state.json` already exists, show the current state (iteration, phase, handoff count) and ask the investor:
> An existing startup session was found at iteration N (phase: X). Would you like to:
> 1. **Resume** the existing session
> 2. **Reset** and start fresh (this will delete all previous progress)

If resuming, run `/bootstrap` first (idempotent — ensures docs/ structure exists for migrated projects), then skip to Step 3 with the existing state.

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

Initialize `state.json`:
```json
{
  "iteration": 0,
  "max_iterations": 20,
  "phase": "research",
  "active_role": "business-founder",
  "status": "active",
  "started": "<current ISO timestamp>"
}
```

Write `docs/business/brief.md` using the user's SaaS idea description (skip if `/bootstrap` already created it).

**Copy the human-tasks template:**
```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md .startup/human-tasks.md
```

Tell both agents that handoff and brief templates are available at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Step 2b: Initialize CLAUDE.md for Auto-Learning

The PostToolUse hook will auto-populate a `## Learnings` section in the project's CLAUDE.md as agents write handoffs, reviews, and signoffs. Ensure the section exists:

1. If no `CLAUDE.md` exists at git root, create it with:
   ```markdown
   # Project Learnings

   ## Learnings

   <!-- Auto-populated by the saas-startup-team plugin PostToolUse hook -->
   ```
2. If `CLAUDE.md` exists but has no `## Learnings` section, append:
   ```markdown

   ## Learnings

   <!-- Auto-populated by the saas-startup-team plugin PostToolUse hook -->
   ```
3. If `CLAUDE.md` already has a `## Learnings` section, do nothing.

## Step 2c: Ensure Git Repository

The auto-commit hook requires a git repo. Ensure one exists:

1. Check if in a git repo: `git rev-parse --show-toplevel`
2. If **not** in a git repo: `git init && git add -A && git commit -m "Initial commit before startup loop"`
3. If **already** in a git repo: `git add -A .startup/ && git commit -m "Initialize .startup/ directory" --no-verify`

## Step 2d: Reset Session State

Clean up state from previous sessions to prevent stale data:

1. Remove idle counter files:
   ```bash
   rm -f .startup/.idle-count-* .startup/.idle-handoff-snapshot-*
   ```
2. If resuming an existing session, skip this step (idle counters reflect real state).

## Step 3: Spawn Agent Team

Before spawning the agent team, clean up orphaned processes from previous sessions:

```bash
# Kill orphaned Claude agent processes (from crashed previous sessions)
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
# Kill orphaned Playwright MCP servers
pkill -f 'playwright-mcp' 2>/dev/null || true
# Brief pause for cleanup
sleep 1
```

Spawn the initial agent pair using the **Task tool** (one-shot agents, NOT TeamCreate). Agent Teams persistent teammates cannot be dismissed — they accumulate as zombie processes. All agent dispatches (initial and subsequent) use the same one-shot pattern described in Step 5.

1. **Business Founder** — spawn via Task tool with `subagent_type: "general-purpose"`:
   - Tell the agent to read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for its identity, tools, and behavioral constraints
   - Task: Read `brief.md`, research the market (web + Reddit + browser), break the idea into features, write the first handoff to tech founder
   - Has web access, browser access, research tools

2. **Tech Founder** — spawn via Task tool with `subagent_type: "general-purpose"`:
   - Tell the agent to read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder.md` for its identity, tools, and behavioral constraints
   - Task: Read `docs/business/brief.md` to understand the product vision. Plan preliminary architecture ideas and write initial thoughts to `docs/architecture/architecture.md`. Do NOT start implementing until you receive a handoff from the business founder. Handoff and brief templates are at `${CLAUDE_PLUGIN_ROOT}/templates/`.
   - Has code tools only, no web access

**IMPORTANT: Do NOT use TeamCreate.** Agent Teams persistent teammates cannot be terminated once spawned. Use the Task tool for ALL agent dispatches — initial and subsequent. Each Task agent exits cleanly when done.

## Step 4: Start the Loop

Send the initial message to the business founder:

> Read `docs/business/brief.md`. This is our investor's SaaS idea. Your job:
> 1. Research the market, competition, and customer pain points (save to `docs/research/` in Estonian)
> 2. Research similar solutions in other countries — extract features, UX patterns, and pricing from international competitors (save to `docs/research/rahvusvaheline-analuus.md`)
> 3. Check Estonian legal requirements for this type of business
> 4. Break the idea into prioritized features
> 5. Write the first handoff to tech founder: `.startup/handoffs/001-business-to-tech.md`
> 6. Add any human-only tasks to `.startup/human-tasks.md`
> 7. Update `.startup/state.json` (iteration: 1, phase: requirements)
> 8. After writing the handoff, send a message to the team lead: "Handoff 001 ready for tech founder."
>
> Handoff and brief templates are at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Step 5: Relay Handoffs Between Founders

**This is your core loop responsibility.** When a founder signals "Handoff NNN ready for [other founder]", you MUST relay it with an explicit, self-contained task message. The receiving founder's context accumulates across iterations — they may have auto-compacted and lost earlier details. Every relay message must be complete enough to act on WITHOUT relying on prior conversation history.

**NEVER write handoffs yourself.** The team lead is an orchestrator, not a founder. Even when the investor gives specific technical instructions, ALWAYS route them through the appropriate founder. The business founder has accumulated product context (UX patterns, competitor analysis, Estonian nuances, edge cases from browser testing) that the team lead does not have. Pass investor instructions to the business founder and let them write the handoff — they will enrich it with context you lack.

### Agent Lifecycle — Always Fresh, Right-Sized

**Always spawn a fresh agent for every relay.** Never reuse agents — context bloat from prior handoffs degrades agent quality. Each dispatch starts with a clean context window.

Before spawning a new agent, **kill ALL stale agents** (not just same role — kill everything):
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

**Do NOT use TeamCreate for relays.** TeamCreate spawns persistent teammates that cannot be dismissed — they accumulate as zombie processes eating ~500MB each. Use the **Task tool** which spawns one-shot agents that exit cleanly when done.

**Fresh spawn via Task tool** — pass ALL of the following in the Task prompt:
- The agent's role identity: "You are the {role} of an Estonian SaaS startup. You speak {language}."
- The agent definition file path: `${CLAUDE_PLUGIN_ROOT}/agents/{agent-name}.md` — tell the agent to read it for tools/model/behavioral constraints
- The full relay message (same self-contained message you'd send to a persistent teammate)
- Instruction: "After completing your work and writing the handoff/review/signoff file, report back with a summary of what you did and the filename."

Use `subagent_type: "general-purpose"` for the Task tool.

**Right-size the task.** Each agent dispatch must be a cohesive unit of work that produces exactly ONE deliverable file (handoff, review, or signoff). The sweet spot is 15-30 minutes of agent time.

| Scenario | Dispatches |
|----------|-----------|
| 1-2 feature handoff | 1 agent |
| Feedback with 3-4 independent fixes | 1 agent (fixes are small, bundle them) |
| 2 large independent features | 2 agents, one per feature, each writes its own handoff |
| Browser review of implementation | 1 agent |

**NEVER micro-delegate.** Do NOT spawn separate agents for each individual fix. Bundle all fixes from a review into a single agent dispatch. If a task doesn't produce a file (handoff, review, signoff, or doc), it shouldn't be a separate agent — fold it into the next real task.

### When Business Founder signals "Handoff NNN ready for tech founder":

Send to tech founder:
> **New task: Implement handoff NNN.**
> Read `.startup/handoffs/NNN-business-to-tech.md` for full requirements.
> Read `.startup/state.json` for current iteration and phase.
> Check `docs/architecture/architecture.md` for your previous architecture decisions.
> Implement the features, then write your handoff to `.startup/handoffs/{NNN+1}-tech-to-business.md`.
> Set 10s timeouts on all HTTP calls. If a service is unreachable after 3 retries, document the failure and move on.
> After writing the handoff, message the team lead: "Handoff {NNN+1} ready for business founder."

### When Tech Founder signals "Handoff NNN ready for business founder":

Read the tech founder's handoff to extract the localhost URL and port, then send to business founder:
> **New task: Review handoff NNN.**
> Read `.startup/handoffs/NNN-tech-to-business.md` for implementation details.
> Read `.startup/state.json` for current iteration and phase.
> Open browser to `{localhost URL from handoff}` and verify the implementation visually using Playwright.
> Write your review to `.startup/reviews/` and then either:
> - Write a roundtrip signoff if the feature meets production quality
> - Write a feedback handoff to `.startup/handoffs/{NNN+1}-business-to-tech.md` if changes are needed
> After writing, message the team lead: "Review complete" or "Handoff {NNN+1} ready for tech founder."

### After Roundtrip Signoff

When you read the business founder's review and see a roundtrip signoff was written:
1. Announce the signoff result to the investor (brief one-liner)
2. **Immediately dispatch the business founder** to write the next feature handoff — do NOT wait for investor input
3. The business founder should read their research docs and the brief to decide the next priority feature
4. Only pause the loop if iteration limit is approaching or the business founder signals solution signoff

### Why explicit relay matters

Each founder is a persistent teammate whose context grows across iterations. By iteration 5+, auto-compaction may have removed earlier conversation details. The relay message must contain ALL information the founder needs to act — file paths, state references, and behavioral reminders. Never assume the founder "remembers" anything from earlier messages.

## Loop Control

The loop continues until the business founder writes `.startup/go-live/solution-signoff.md`. The Stop hook enforces this after iteration 2+ — earlier iterations allow free exit for testing.

**Iteration limit**: If `state.json` iteration reaches `max_iterations` (default: 20), alert the human investor and ask whether to continue or wrap up.

**Deadlock handling**: If either founder sends you a message saying they're stuck, escalate to the human investor with context about the deadlock.

## Communication to Investor

When communicating with the human investor:
- The business founder speaks **Estonian**
- The tech founder speaks **English**
- You (team lead) speak **English** for status updates
