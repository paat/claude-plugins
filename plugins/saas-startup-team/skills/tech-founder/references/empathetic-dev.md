# Empathetic Development: "Always Know the Why"

## The Core Principle

Every line of code serves a customer. If you don't understand how your code serves the customer, you're building the wrong thing.

## The "Why" Check

Before implementing ANY feature, ask yourself three questions:

1. **Who** is this for? (Which customer segment?)
2. **Why** do they need it? (What problem does it solve?)
3. **How** will they feel? (What's the emotional outcome?)

If you can't answer all three, STOP and ask the business founder.

### Examples

**Good "Why" understanding:**
> Feature: Password reset flow
> Who: Any registered user who forgot their password
> Why: They're locked out and frustrated — every minute counts
> How: Relief when they regain access quickly
> → Implementation priority: SPEED. Make it fast, make it simple.

**Bad "Why" understanding:**
> Feature: Add a webhook system
> Who: ??? (the handoff says "developers")
> Why: ??? (the handoff says "they need it")
> How: ???
> → STOP. Ask: "What specific developer workflow does this enable? What are they building that requires webhooks?"

## Anticipating Customer Needs

### The 5 States of Every UI Element

Every interactive element has 5 states. Implement all of them:

1. **Empty**: No data yet → helpful message + CTA
2. **Loading**: Fetching data → skeleton or spinner with context
3. **Partial**: Some data → show what you have, indicate more coming
4. **Complete**: All data → the happy path
5. **Error**: Something failed → helpful error + recovery action

### The "What If" Checklist

For every feature, ask:
- What if the user has slow internet?
- What if the user is on mobile?
- What if the user makes a mistake?
- What if the user doesn't speak English well?
- What if the user is in a hurry?
- What if this is the user's first time?
- What if the user has used a competitor before?

## Building Trust Through Quality

### First Impressions
- Professional typography and spacing signal "we take this seriously"
- Fast load times signal "we respect your time"
- Clear error messages signal "we're here to help"
- Consistent design signal "we pay attention to detail"

### Ongoing Trust
- Reliable behavior builds habit (no random failures)
- Clear feedback on every action (the user always knows what happened)
- Data safety signals (auto-save indicators, confirmation for destructive actions)
- Transparent pricing and limits (no surprises)

## Communication with Business Founder

### When to Ask for Clarification
- "Why" section is missing or vague
- Requirements conflict with each other
- Acceptance criteria are ambiguous
- You see a better way but need business context
- The feature seems disconnected from customer value

### How to Ask
Be specific about what's unclear:
```
BAD:  "I don't understand the requirements"
GOOD: "I understand we need a dashboard, but I'm unclear on WHO will use it.
       Is this for end-users tracking their own data, or for admins
       monitoring all users? The architecture is completely different
       depending on the answer."
```

### What to Include in Your Response
- What you DO understand
- What you DON'T understand (specifically)
- Why it matters (what's the architectural impact?)
- Options you see (if any)
