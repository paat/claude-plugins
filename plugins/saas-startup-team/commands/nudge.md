---
name: nudge
description: Unstick a deadlocked startup loop — manually send direction to a stuck founder or resolve a conflict between founders
user_invocable: true
---

# /nudge — Unstick the Startup Loop

The human investor intervenes to resolve a deadlock or redirect a founder.

## When to Use

- A founder is stuck and hasn't made progress
- The founders disagree on an approach
- The investor wants to change direction or priorities
- The loop has been going too long without visible progress
- A specific human task is blocking progress

## Actions

1. **Read current state**: Check `.startup/state.json` to understand where things stand
2. **Read latest handoffs**: Understand what each founder last communicated
3. **Ask the investor** what direction to give (if not already specified):
   > What guidance do you want to give? Options:
   > - Redirect the business founder's research focus
   > - Clarify requirements for the tech founder
   > - Resolve a disagreement between founders
   > - Change priorities or scope
   > - Mark a human task as completed

4. **Send the investor's direction** to the appropriate founder via agent team messaging
5. **Update state.json** if needed (e.g., change phase or active_role)

## Nudge Templates

### Redirect Business Founder
> [Investor direction]: Focus on [specific area]. The current research direction is [issue]. Please [specific action] and update the handoff.

### Clarify for Tech Founder
> [Investor direction]: The business justification for [feature] is [explanation]. This matters because [customer reason]. Please proceed with implementation.

### Resolve Disagreement
> [Investor decision]: We will go with [approach] because [reason]. [Founder A], please [action]. [Founder B], please [action].

### Change Scope
> [Investor direction]: Let's [add/remove/reprioritize] [feature]. The reason is [explanation]. Business founder: update the requirements. Tech founder: adjust implementation plan.
