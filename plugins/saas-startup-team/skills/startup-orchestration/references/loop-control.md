# Loop Control Reference

## When to Continue the Loop

Continue iterating when:
- Features remain unimplemented from the requirements list
- A feature failed browser verification and needs fixes
- The business founder has identified new requirements based on implementation review
- The solution doesn't yet meet the "would I pay for this?" bar

## When to Pause the Loop

Pause and alert the investor when:
- **Iteration limit approaching**: iteration >= max_iterations - 5
- **Deadlock**: Both founders have sent 2+ messages without progress
- **Scope explosion**: More than 3 new features added during review phase, OR a single handoff contains 3+ features (oversized handoff — instruct business founder to split)
- **Critical blocker**: A human task is genuinely blocking further progress
- **Budget concern**: Complex implementation requiring many more iterations

## When to Stop the Loop

The loop ends ONLY when:
1. The business founder writes `.startup/go-live/solution-signoff.md`
2. The Stop hook validates the file exists

The tech founder CANNOT end the loop. Only the business founder (customer's voice) decides readiness.

## Iteration Budget

| Iteration | Action |
|-----------|--------|
| 1-5 | Normal operation — research, first features |
| 6-10 | Progress check — are features being signed off? |
| 11-15 | Efficiency mode — focus on remaining gaps only |
| 16-19 | Wrap-up mode — finalize and prepare for go-live |
| 20 | Hard stop — investor must decide to continue or ship |

## Cost Estimation

Each iteration involves:
- Business founder: ~5K-20K tokens (research + handoff writing)
- Tech founder: ~10K-50K tokens (implementation + handoff writing)
- Estimated cost per iteration: $0.15-$1.50 (Opus pricing)
- Full 20-iteration run: $3-$30 estimated

### Context Window Budget

Each handoff implementation should fit within ~50K tokens of agent context. At 3+ features, implementation typically exceeds 100K tokens, triggering auto-compaction that loses critical details mid-build. This is why handoffs are limited to 2 features maximum — it's not just about scope discipline, it's a hard technical constraint of the agent's context window.

**Agent freshness mechanism**: The team lead tracks cumulative handoffs per agent in `state.json` (`agent_handoffs`). After 3 handoffs (~141K tokens accumulated), the team lead spawns a fresh agent via Task tool instead of messaging the persistent teammate. This gives the agent a clean context window with full system prompt fidelity. See `team-patterns.md` → "Agent Lifecycle Management" for details.

## Recovery from Bad States

### Both founders idle
1. Read `state.json` → identify `active_role`
2. Send message to the active founder: "It's your turn. Read the latest handoff and continue."

### Iteration counter out of sync
1. Count actual handoff files in `.startup/handoffs/`
2. Update `state.json` to match reality

### Missing handoff file
1. Check which founder should have written it
2. Send them a message: "Your handoff file is missing. Write [expected filename] before proceeding."

## Stall Recovery

### Agent frozen
1. Send a status check message: "Are you blocked? If so, describe the blocker in your handoff and move to the next task."
2. If no response after the message: escalate to the investor with context about the last known activity.

### Tech-founder stuck on unreachable service
1. Instruct: "Set a 10s timeout on the HTTP call. Log the connection error. Document the failing service URL/port in your handoff under 'Known Limitations'. Add a human task for the investor to verify the service. Move to the next feature that doesn't depend on this service."
2. If the tech-founder has already retried 3+ times: "Stop retrying. The service is unreachable. Document it and continue."

### Business-founder stuck on browser
1. Check the tech-founder's latest handoff for the correct URL and port.
2. If the URL/port is wrong or the dev server isn't running: message the tech-founder to fix and update the handoff.
3. If the page loads but is broken: this is a normal review finding — the business-founder should document it in the feedback handoff.

### Prevention
- When dispatching tasks to the tech-founder, always include: "Set 10s timeouts on all HTTP calls. If a service is unreachable after 3 retries, document the failure and move on."
- When dispatching review tasks to the business-founder, always include the correct localhost URL and port from the tech-founder's handoff.
- Ensure `.startup/docs/architecture.md` has up-to-date service URLs and ports.
