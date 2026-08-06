# Handoff template

File naming: `handoff-<UTC yyyy-mm-ddThhmmZ>.md` under `${MMO_HANDOFF_DIR:-.claude/handoffs}`,
committed on the epic branch. Update the current handoff after every merge, verdict, or ratified
decision — never only at session end. When a prior handoff exists, do not restate its protocol:
state "The protocol sections of `<prior-handoff>` remain in force verbatim; this file adds only
deltas." and record deltas.

```markdown
# Handoff — <mission>: <one-line outcome>

**For:** the fresh session continuing as meta-orchestrator.
Written <UTC date> by the meta-orchestrator. Everything below was verified against the tree and
the tracker, not recalled. Supersedes <prior-handoff or "nothing">.

Read in this order before acting: <this file> → <grounding doc(s)> → <epic issue>.

## Stop here first

<ONE next action, already decided. State the decision and why nothing else can proceed before it,
so the successor starts with a decision, not a question.>

## State

- Epic branch: `<branch>` at `<sha>`; default branch untouched: <yes/no + evidence>.
- Merged into epic branch: <N> PRs (<#list>).
- In flight: <PR #, CI status, "ready for review, not merged" / blocked-on>.
- Worktree: <branch, clean/dirty + why>.

## Decisions ratified — do not re-litigate

- <decision> — recorded at <issue comment / doc §>.

## Queue (in order)

1. <item + its preconditions and evidence paths>
2. ...
N. Browser QA + UX pass on the epic PR.
N+1. `tribunal-review:closing-tribunal-loop` on the epic PR; merge at zero critical/high.

## Issues: blocking vs not

- Blocking merge: <#...>
- Enablement, not merge blockers: <#...>
- Found, not blocking — must NOT be sequenced behind this epic: <#...>

## Rules learned (imperatives; keep the incident count that earned each)

- <rule> — paid for <N> time(s).

## Worker reliability

<pushbacks that caught orchestrator errors, misreports, exit codes, which model handled what.>

## Open human decisions

<questions only the owner can answer; the human may pre-answer these inline when resuming.>
```
