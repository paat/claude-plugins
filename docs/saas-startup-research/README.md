# SaaS Startup Team — Research Documentation

Research compiled for the `saas-startup-team` Claude Code plugin, which simulates a two-person SaaS startup using Agent Teams.

## Research Files

| # | File | Topic |
|---|------|-------|
| 01 | [Multi-Agent Loops](01-multi-agent-loops.md) | Ralph Wiggum loop variants, stopping conditions, prior art (snarktank/ralph, frankbria/ralph, Flow-Next, Google ADK LoopAgent) |
| 02 | [AI Startup Simulations](02-ai-startup-simulations.md) | ChatDev, MetaGPT, CrewAI, AutoGen — role-based teams, structured handoffs, lessons learned |
| 03 | [File-Based Coordination](03-file-based-coordination.md) | Maildir queues, task directories, agent handoff markers, AgentFS, best practices |
| 04 | [Claude Code Extension Points](04-claude-code-extension-points.md) | All hook events, skills, subagents, commands, MCP, agent teams, plugin manifest |
| 05 | [Two-Agent Iterative Patterns](05-two-agent-iterative-patterns.md) | Pair programming agents, orchestration patterns, handoff best practices, anti-patterns |
| 06 | [Agent Teams Reference](06-agent-teams-reference.md) | Claude Code Agent Teams: configuration, hooks, messaging, delegate mode, limitations |
| 07 | [February 2026 Latest](07-feb-2026-latest.md) | Cutting-edge developments from Jan-Feb 2026, 5 cross-cutting themes, design implications |

## Key Research Insights

### 1. Two Agents is the Sweet Spot
All multi-agent frameworks struggle above 5-7 agents due to quadratic communication overhead. Our two-agent model (business + tech founder) with structured file handoffs is the simplest viable pattern for iterative development.

### 2. Ralph Loop + Open Spec = Our Architecture
The business founder writes structured specifications (the "Open Spec"), the tech founder executes in a persistent loop (the "Ralph Loop"). This combination has been validated as best practice by the community in early 2026.

### 3. Orchestration Matters More Than Model Quality
Quality gates (hooks), structured handoffs (templates), and clear completion criteria (two-level signoff) produce better results than upgrading to more capable models. This justifies our heavy investment in the coordination layer.

### 4. Information Asymmetry Creates Accountability
Our design where the tech founder has NO web access is unique among multi-agent frameworks. It forces the business founder to be thorough in research and handoff quality — a feature, not a limitation.

### 5. File-Based State Carries Context
Each agent gets a fresh context window (Agent Teams native behavior). Handoff documents carry state forward, not LLM memory. This mirrors the Ralph Loop insight and prevents context pollution.

### 6. Cost Awareness is Critical
The $20K C compiler incident shows unbounded loops are dangerous. Our max_iterations limit (default: 20) with warnings at iterations 10 and 15 provides necessary guardrails.

### 7. Hooks as Permission Budgets
TeammateIdle and TaskCompleted hooks serve as "permission budgets" that constrain agent behavior without requiring constant human oversight — aligned with emerging governance patterns for autonomous AI agents.
