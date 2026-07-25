# Follow-up issue template (tribunal descope / out-of-scope)

When triage decides "file follow-up" rather than "fix in this PR", file a real
GitHub issue (or comment on a pre-existing one if cited). Dense and actionable
so the next person can fix without re-deriving context.

```markdown
## Context

Brief note on which PR surfaced this and why it's deferred (e.g., out of
original issue scope, requires separate design decision, blocked on X).

## Current behaviour

File:line citation + 2-3 lines of code or behaviour description.

## Failure scenario

Concrete repro: a specific input that triggers the bug, expected vs
actual output. Use a table when contrasting pre- vs post-state.

## Fix sketch

The smallest change that closes the bug. One paragraph or short code
block. Include any acceptance test that should pin the fix.

## Severity

Low / Medium / High / Critical, with one sentence on customer impact
and triggering preconditions ("only bites returning customers who…").

## Discovered by

Tribunal review of PR #N, finding T-XXX (consensus type, confidence), round R.
```

**Cross-link both directions:** the round PR comment and/or commit message
references the issue (`tracked at #N`) AND the issue references the PR
(`Discovered by tribunal review of PR #N`).
