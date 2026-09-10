# Fresh-session handoff

Each run renders `queue.md` with at most ten rows per section. Priority expresses importance;
readiness controls whether a task can start. A required blocked item retains its high priority.
The implement-now section excludes deferred, blocked and unknown-readiness work regardless of rank.

A usable row identifies the item/source reference, minimum response, priority, readiness,
dependency/owner/evidence prerequisites, next concrete task, and stop/refresh condition.
The register remains the historical assessment; changed assessments require a new linked run.

## Entry-point connection

Prepare a link to the current run or stable pointer for the repository instructions fresh sessions
actually load. Identify the source file when an entry point is generated or symlinked.
When output is not shared across checkouts, draft a tracker summary with the next task, minimum
scope, blockers and durable source links. Retain private evidence locally and report unpublished
links as handoff limits. Any filing draft must state: **This draft has had no PII review.**

The entry-point instruction should direct a fresh session to check queue prerequisites before
delivery, select the first eligible task, and stop/refresh when the stated condition changes.
Validate by reading only that entry point and its linked artifact: the next task and its blockers
must be recoverable without a new census. Report a missing accessible link as unfinished handoff.

## Inspect the actual consumer

Read the target's selector/configuration; installed versions may differ. Name the verified control
and report one of these classes per row:

| Class | Claim allowed |
|---|---|
| `native` | The consuming selector demonstrably enforces this specific eligibility condition |
| `instruction-only` | An agent preflight can obey it; unattended selection remains unchanged |
| `unavailable` | No verified consumer mechanism preserves the requested decision |

### Worked example — one known consumer

The following is an example, not a contract for other consumers. Inspect that consumer's own
selection code before claiming a handoff controls it. One known maintain selector has these levers:

- `needs-human`, any assignee and `epic` may be hard exclusions.
- A `depends on #N` / `blocked by #N` clause in title/body can block until the dependency is
  closed with delivery merged to the default branch. A comment alone may not be parsed.
- An active blocked-ledger entry with `number`, `reason`, `cooldown_until`, supplied through
  `--blocked-file`, can encode a date-based deferral. A label alone cannot substitute for the ledger.
- Priority may sort only severity labels, age and item number; triage priority and `steering`
  may have no effect. Severity changes require their own authorization and semantic justification.

In this example, `maintain:blocked` without an active ledger row may be cleanup-only and still queued.
Never claim low-value triage is a native exclusion merely because its decision was commented.
Recommend an existing dependency or ledger mechanism only with evidence; changes remain proposals.
Entry-point links are instruction-only unless the consumer proves otherwise.
Do not add a scheduler or label taxonomy to disguise unavailable enforcement.
