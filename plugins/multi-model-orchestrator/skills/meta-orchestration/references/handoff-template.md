# Handoff template

File naming: `handoff-<UTC yyyy-mm-ddThhmmZ>.md` under `${MMO_HANDOFF_DIR:-.claude/handoffs}`.
Write rules: see the skill's Preflight and Handoff discipline (handoffs are local; never commit them). When a prior handoff
exists, do not restate its protocol:
state "The protocol sections of `<prior-handoff>` remain in force verbatim; this file adds only
deltas." and record deltas.

Run lease (one orchestrator per checkout — the lease lives in the handoff directory, so a
second worktree holds its own): with each handoff write, run
`${CLAUDE_PLUGIN_ROOT}/scripts/handoff-lease.sh claim <owner> --ttl <seconds>` — before a dispatch
the ttl is that leg's deadline (`--timeout`, times the workers a `pool.sh run` could try) plus 600.
`<owner>` is an id you make up once at a fresh start (`<UTC yyyymmddThhmmssZ>-<4 random hex>`) and
record in State. Reuse it after compaction; a new session started with `--resume` claims with a new
id, so it is refused while the previous session's lease is unexpired. `release <owner>` when the run ends.

```markdown
# Handoff — <mission>: <one-line outcome>

**For:** the fresh session continuing as meta-orchestrator.
Written <UTC date> by the meta-orchestrator. Everything below was verified against the tree and
the tracker, not recalled. Supersedes <prior-handoff or "nothing">.

Read in this order before acting: <this file> → <grounding doc(s)> → <epic issue>.

## Brief

<the original mission brief, verbatim, then every override in force (autonomy bounds, stop
conditions, provider/model restrictions) with where each came from. A fresh session has no other copy.>

## Stop here first

<ONE next action, already decided. State the decision and why nothing else can proceed before it,
so the successor starts with a decision, not a question.>

## State

- Working branch(es) (epic branch in strategy A; item branches in B): `<branch>` at `<sha>`;
  default branch untouched: <yes/no + evidence>.
- Merged so far: <N> PRs (<#list>).
- In flight: <PR #, CI status, "ready for review, not merged" / blocked-on>.
- In-flight legs: `<repo path, branch, runner + mode + model, output path, exit marker path,
  expected artifact paths, baseline the gate measures against, dispatch time (UTC),
  one line on what the leg was told, how completion will be observed, literal resume command>`
  — or `none`.
- Worktree: <branch, clean/dirty + why>.
- Lease owner: `<owner id>`.
- Usage: <per provider: tightest window %, reset UTC, as-of; or `unknown`>.

## OPERATOR ACTIONS REQUIRED

- <refused or unavailable privileged action; items that do not depend on it continue>.

## Decisions ratified — do not re-litigate

- <decision> — recorded at <issue comment / doc §>.
- Research memo: `<path>` — <fact settled>.

## Provisional research — re-open when better evidence appears

- Research memo: `<path>` — defaulted `UNKNOWN`; re-open when better evidence appears.

## Queue (in order)

1. <item + its preconditions and evidence paths>
2. ...
N. Browser QA + UX pass on the PR(s) under close-out.
N+1. `tribunal-review:closing-tribunal-loop` per the delivery strategy; merge at zero
     critical/high.

## Issues: blocking vs not

- Blocking merge: <#...>
- Enablement, not merge blockers: <#...>
- Found, not blocking — must NOT be sequenced behind this epic: <#...>

## Rules learned (imperatives; keep the incident count that earned each)

- <rule> — paid for <N> time(s).

## Worker reliability

<pushbacks that caught orchestrator errors, misreports, exit codes, which model handled what.>

## Judgment calls decided

<choice — recommended default taken, reason, how to reverse; the human may overrule any of these inline when resuming.>
```
