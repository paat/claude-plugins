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

If resuming, skip to Step 3 with the existing state.

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

Write `brief.md` using the user's SaaS idea description.

**Copy the human-tasks template:**
```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md .startup/human-tasks.md
```

Tell both agents that handoff and brief templates are available at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Step 3: Spawn Agent Team

Use `TeamCreate` to create the agent team with both founders. Use `TaskCreate` to create their initial work items.

1. **Business Founder** (teammate: `business-founder`)
   - First task: Read `brief.md`, research the market (web + Reddit + browser), break the idea into features, write the first handoff to tech founder
   - Has web access, browser access, research tools

2. **Tech Founder** (teammate: `tech-founder`)
   - Initial message:
     > Read `.startup/brief.md` to understand the product vision. While waiting for the first handoff from the business founder, plan preliminary architecture ideas and write initial thoughts to `.startup/docs/architecture.md`. Do NOT start implementing until you receive a handoff from the business founder. Handoff and brief templates are at `${CLAUDE_PLUGIN_ROOT}/templates/`.
   - Has code tools only, no web access

## Step 4: Start the Loop

Send the initial message to the business founder:

> Read `.startup/brief.md`. This is our investor's SaaS idea. Your job:
> 1. Research the market, competition, and customer pain points (save to `.startup/docs/` in Estonian)
> 2. Research similar solutions in other countries — extract features, UX patterns, and pricing from international competitors (save to `.startup/docs/rahvusvaheline-analüüs.md`)
> 3. Check Estonian legal requirements for this type of business
> 4. Break the idea into prioritized features
> 5. Write the first handoff to tech founder: `.startup/handoffs/001-business-to-tech.md`
> 6. Add any human-only tasks to `.startup/human-tasks.md`
> 7. Update `.startup/state.json` (iteration: 1, phase: requirements)
> 8. After writing the handoff, send a message to the team lead: "Handoff 001 ready for tech founder."
>
> Handoff and brief templates are at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Loop Control

The loop continues until the business founder writes `.startup/go-live/solution-signoff.md`. The Stop hook enforces this after iteration 2+ — earlier iterations allow free exit for testing.

**Iteration limit**: If `state.json` iteration reaches `max_iterations` (default: 20), alert the human investor and ask whether to continue or wrap up.

**Deadlock handling**: If either founder sends you a message saying they're stuck, escalate to the human investor with context about the deadlock.

## Communication to Investor

When communicating with the human investor:
- The business founder speaks **Estonian**
- The tech founder speaks **English**
- You (team lead) speak **English** for status updates
