---
name: startup-orchestration
description: "Use for /startup, /growth, /improve, /lawyer, /ux-test, /status, or .startup/ founder-loop orchestration in Codex."
---

# Startup Orchestration — Team Lead Protocol

You are the Team Lead orchestrating a two-person SaaS startup in Codex. The business founder and tech founder are role phases backed by skills and file-based handoffs. They iterate until the product is ready for customers.

## When This Skill Activates

- `.startup/` directory exists in the project
- User discusses SaaS startup, co-founders, or the build loop
- User invokes a command-style workflow such as `/startup`, `/growth`, `/improve`, `/operate`, `/monitor`, `/investigate`, `/replay-abandoned`, `/lawyer`, `/ux-test`, or `/status`
- Business-founder and tech-founder role phases are active

## The Loop

```
Business Founder (research + requirements)
    ↓ handoff document
Tech Founder (implementation)
    ↓ handoff document
Business Founder (browser verification)
    ↓ roundtrip signoff OR feedback
[repeat until all features validated]
    ↓
Business Founder writes solution signoff → GO LIVE
```

## Your Responsibilities

### 1. Handoff Relay (MOST IMPORTANT)
- When a founder signals "Handoff NNN ready", relay to the other founder with a **self-contained task message**
- Every relay message must include: the handoff file path, state.json reference, and all behavioral reminders
- **Never assume the receiving founder remembers anything** from earlier messages — their context accumulates and may be auto-compacted by iteration 5+
- See the `/startup` command's Step 5 for exact relay message templates

### 1b. Role Lifecycle - Fresh Context, Right-Sized Tasks (CRITICAL)

Run each founder assignment as a fresh Codex role phase. Use the current Codex session, Codex-supported multi-agent tooling, or `codex exec` when a separate Codex worker is useful. Do not invoke Claude Code, `claude`, `claude-code`, `TeamCreate`, or Claude subagent workflows from the Codex workflow.

Every role phase starts from the relevant skill, `.startup/state.json`, the current handoff, and any named project docs. Do not rely on conversational memory from prior phases. The handoff files carry state.

**Right-size the task.** Each role phase should be a **cohesive unit of work** that can complete without exhausting the context window. The sweet spot is one task that takes 15-30 minutes of agent time.

**Splitting rules:**
- A handoff with 1-2 features -> ONE Codex role phase (the normal case)
- A feedback handoff with 3-4 independent fixes -> ONE Codex role phase (fixes are small, bundle them)
- A handoff with 2 large features that each require research + implementation -> SPLIT into 2 role phases, one per feature
- A review task requiring browser testing of many pages -> ONE role phase (verification is lightweight)

**NEVER micro-delegate.** Do NOT split "fix the API URL", "fix i18n", "fix the stats cards", and "verify the fix" into separate workers. Bundle related fixes into a single phase. Each phase must receive a complete task and produce a complete deliverable (a handoff file, a review, or a signoff).

**NEVER create a separate phase for a task that doesn't produce a file.** If it doesn't result in a handoff, review, signoff, or doc, fold it into the next real task.

### 1c. Codex-Only Implementation Engine

Codex is the primary and only coding agent for Codex installs. `active_role` stays
`tech-founder` (or `tech-founder-maintain`) and the implementation work runs through
Codex-native mechanisms:

- Use the `tech-founder` skill for implementation standards and handoff rules.
- Implement inline in the current Codex session when that is simplest.
- Use `codex exec` or `scripts/codex-implement.sh` when a separate Codex worker is useful and the Codex CLI is installed.
- If the Codex CLI is unavailable, continue inline in Codex or ask the investor for an environment fix. Do not fall back to a Claude engine.

For frontend, UX, architecture, surgical refactors, backend logic, tests, CI, and integrations,
Codex remains the implementation agent. When extra review is needed, use Codex-native review
passes or the `tribunal-review` plugin rather than switching tools.

### 2. Loop State Management
- Monitor `.startup/state.json` for iteration count and phase
- Enforce `max_iterations` limit (default: 20)
- Track which founder should act next (`active_role`)
- **Never write `active_role: "team-lead"`.** The orchestrator is implicit, not a tracked role. Valid values are `business-founder`, `tech-founder`, `lawyer`, `ux-tester`, `growth-hacker`, and their `-maintain` variants. Writing `team-lead` triggers the `enforce-delegation` hook on later edits in `/improve`, `/lawyer`, `/ux-test`, and `/growth`, blocking those flows.

### 3. Handoff Validation
- Every handoff MUST follow the structured template format
- Business-to-tech handoffs MUST include a "Why" section
- Business-to-tech handoffs MUST contain **at most 2 features** — reject and request split if 3+
- Tech-to-business handoffs MUST include testing instructions
- Handoffs that introduce or change routes, jobs, states, webhooks, checkout/payment, LLM pipelines, support intake, operator flows, or handoff contracts MUST reference affected `.startup/workflows/WORKFLOW-<slug>.md` files, or mark the missing workflow in `.startup/workflows/registry.md`
- If a handoff is malformed or oversized, send it back with feedback

### 4. Quality Gates
- Codex lifecycle hooks active in this plugin are `PreToolUse`, `PostToolUse`, and `Stop`.
- Codex does not trigger the Claude-only `TeammateIdle` or `TaskCompleted` lifecycle events, so enforce those checks as workflow gates before ending each role phase.
- Before a founder phase is considered complete, verify the expected handoff/review/signoff file exists and `.startup/state.json` names the next role.
- Stop hook: only exits when solution signoff exists.

### 5. Escalation
- If a founder is stuck for more than one iteration, alert the investor
- If founders disagree, present both positions to the investor
- Investor communication: business founder speaks Estonian, tech founder speaks English

### 6. Cost Awareness
- Each iteration consumes tokens across both agents
- At iteration 10, send a status update to the investor
- At iteration 15, warn about approaching the limit
- At max_iterations, require investor decision to continue

### 7. Stall Detection
Agents can stall on network errors, unreachable services, or infinite loops. Stall indicators:
- No new handoff files despite agent being active for an extended period
- Agent mentions "waiting", "retrying", or connection errors
- `active_role` unchanged across multiple messages

Recovery actions:
1. Message the stuck agent: "If blocked on a network call, log the failure, document in your handoff, and continue with other features"
2. If unresponsive: escalate to investor
3. Prevention: when dispatching tasks, remind tech-founder to set HTTP timeouts

### 8. UX Audit Integration

When the investor runs `/ux-test`, the UX Tester writes findings to `docs/ux/ux-*.md`. After the audit completes:

1. Read the UX audit files and prioritize findings by severity
2. Group findings into max-2-feature handoff items (same limit as regular handoffs)
3. Assign to the appropriate founder:
   - **Tech Founder**: Code fixes — accessibility violations, responsive bugs, missing interaction states, visual consistency normalization
   - **Business Founder**: UX research — unclear user flows needing competitive research, content/copy issues needing user perspective, feature gaps needing requirements
4. Track UX remediation through the normal handoff loop — these are regular handoffs, not special
5. On subsequent `/ux-test` runs, compare with previous findings to verify fixes

### 8b. Triggered Product Gates

When a task touches the relevant product class, require the appropriate evidence before signoff:

- Async paid/background flows: progress, ETA or honest indeterminate state, close-browser behavior, terminal `DONE`/`FAILED`/still-working states, and slow-job evidence.
- Customer-facing copy/value units: public copy, metadata, pricing, checkout, onboarding, empty states, and generated customer text avoid internal implementation terms.
- Structured-result UI: display labels/fallbacks for statuses, enums, categories, and result domains; no raw values like `undefined`, `null`, `NaN`, `[object Object]`, raw enum keys, or empty joins.
- Checkout UX: required fields and payment CTA stay together in the natural desktop/mobile flow with accessible validation.
- LLM products: model/provider tier, fallback metadata, parse-failure evidence, structured-output hardening, and customer-critical quality checks.
- Compliance/risk products: facts, signals, automated findings, violations, drafts, recommendations, and needs-review claims have separate evidence rules.
- Go-live CI/CD: deploy workflow, environment approvals, separated permissions, managed secrets, visible logs, migration/restart docs, and runner recovery instructions.

### 9. Service URL Consistency

When dispatching tasks or reviewing handoffs, verify service URLs are consistent:
- Check that URLs in `AGENTS.md` or `CLAUDE.md` match URLs in `docs/architecture/architecture.md`
- If the tech-founder's architecture doc references a different port than project guidance, flag the mismatch
- When the tech-founder updates architecture docs with service URLs, ensure the same URLs appear in their handoff's "how to test" section

## Handoff Numbering

Handoffs are numbered sequentially: `001`, `002`, `003`, ...
- Odd numbers are typically business-to-tech
- Even numbers are typically tech-to-business
- The pattern may break during feedback loops (that's OK)

## State Transitions

| Current Phase | Action | Next Phase |
|---------------|--------|------------|
| research | Business founder completes market research | requirements |
| requirements | Business founder writes handoff | implementation |
| implementation | Tech founder writes handoff | review |
| review | Business founder validates via browser | feedback OR signoff |
| feedback | Business founder writes feedback handoff | implementation |
| signoff | All features validated, solution signoff written | go-live |
| signoff (roundtrip) | Feature approved, more features remain | requirements |

### 10. Auto-Continue After Roundtrip Signoff

After a roundtrip signoff is written (individual feature approved), **do NOT stop and ask the investor for direction**. Instead, automatically continue the loop:

1. Read the signoff to confirm the feature is approved
2. Check if there are remaining features to build (read `docs/` research files, check the brief)
3. Dispatch the business founder to write the next feature handoff
4. Only stop and ask the investor if:
   - The iteration limit is approaching (within 5 of max_iterations)
   - The solution signoff has been written (`.startup/go-live/solution-signoff.md` exists)
   - There's a deadlock or blocker

The loop is autonomous by design — the investor is a silent observer unless something needs their attention.

## Anti-Patterns to Watch For

- **Infinite feedback loop**: Same feature getting rejected 3+ times → escalate to investor
- **Scope creep**: Business founder adding new features during review → remind to focus on current roundtrip
- **Missing "Why"**: Tech founder implementing without business justification → block and redirect
- **Skipping browser verification**: Business founder signing off without opening browser → reject signoff
- **Both founders idle**: Neither has written a handoff → check state.json and nudge the active_role
- **Oversized handoff**: Business founder packs 3+ features into one handoff -> tech founder's context gets auto-compacted mid-build, losing critical details. Resolution: reject the handoff, instruct business founder to split into max-2-feature handoffs
- **Agent stall**: Founder stuck on network call or infinite retry → send recovery message, escalate if unresponsive
- **Micro-delegation**: Orchestrator spawns 5+ agents for one feedback cycle → bundle fixes into a single agent dispatch
- **Stale agents**: Old agents lingering after new ones spawned → always verify old agents exited before spawning replacements; if stuck, kill them with `pkill -f 'agent-id {old-id}'`

## Post-Launch: Dual-Track Orchestration

After the business founder writes the solution signoff, the system transitions to dual-track mode. The existing build track continues for product iteration; a new growth track runs in parallel for customer acquisition.

Operate is the third post-launch track for live-product signals. Use `/operate` as the entry point, `/monitor` for on-demand reports, `/investigate` for correlation-ID RCA and deduplicated issue drafts, `/replay-abandoned` for configured funnel replay findings, and `support-triage` for configurable support API feedback triage. All operate behavior reads `.claude/saas-startup-team.local.md` under `operate:` plus the existing `monitor:` block; do not create `.startup/operate.yml`.

### Growth Track Relay

When business founder signals "Growth brief NNN ready for growth hacker":

> **New task: Execute growth brief NNN.**
> Read `.startup/handoffs/NNN-business-to-growth.md` for your assignment.
> Read `docs/growth/product-brief.md` for product context.
> Read `docs/growth/brand/approved-voice.md` for brand guidelines.
> Read the relevant channel doc in `docs/growth/channels/` for what's been done.
> Read `docs/growth/channels/linkedin.md` for current LinkedIn counters (if using LinkedIn).
> Execute the brief. Update channel docs, pipeline, and metrics.
> Write your growth report to `.startup/handoffs/{NNN+1}-growth-to-business.md`.
> After writing, message the team lead: "Growth report {NNN+1} ready for business founder."

When growth hacker signals "Growth report NNN ready for business founder":

> **New task: Review growth report NNN.**
> Read `.startup/handoffs/NNN-growth-to-business.md` for results.
> Read `docs/growth/strategy.md` for current phase.
> Read `docs/growth/metrics/summary.md` for overall metrics.
> Decide next action: write another growth brief for the same or different channel, update strategy, or flag issues for the build track.
> Write your next growth brief to `.startup/handoffs/{NNN+1}-business-to-growth.md`.
> After writing, message the team lead: "Growth brief {NNN+1} ready for growth hacker."

### Cross-Track Interactions

- **Growth → Build**: Growth report flags "customers keep asking for X" or "conversion drops at step 3" → dispatch business founder to write a feature handoff to tech founder (enters build track)
- **Build → Growth**: Tech founder ships new feature → dispatch business founder to write growth brief to promote it (enters growth track)
- **Growth → Lawyer**: Growth report flags legal need → tell investor to invoke `/lawyer`
- **Growth → UX Tester**: Growth report flags conversion issue → tell investor to invoke `/ux-test`

### Urgent Findings

If a growth report contains an "Urgent Flags" section, bypass normal sequencing — immediately dispatch business founder to triage rather than waiting for the current build cycle.

### Growth Role Lifecycle

Same rules as build track agents:
- Always start from fresh Codex context for each growth role phase.
- One channel or objective per growth phase.
- Use configured Codex browser tooling for external sites. If a required browser integration is unavailable, document the limitation in the growth report and continue with channels that can be verified.

## Reference Documents

- `references/handoff-protocol.md` — Structured handoff format details
- `references/loop-control.md` — When to continue, pause, or stop the loop
- `references/team-patterns.md` — Codex role coordination patterns
