# Review prompt templates

The reviewer must be a DIFFERENT provider than the worker that wrote the commits. Verdict token
is `APPROVE` / `NEEDS_WORK` (the runners' review gate greps exactly these). Reviewers that must
EXECUTE probes: Codex legs use `--mode review`; Claude and Grok review modes are read-only-tooled,
so execute-probe legs on those providers use `--mode implement` with the prompt contract below,
and the orchestrator greps the verdict from the output itself.

## Adversarial review

```markdown
# Adversarial review: commits <sha1> + <sha2> on <branch>

You are the independent reviewer (a different model implemented <what> per <grounding doc §>).
Verify BY EXECUTION. Read-only + execution; modify nothing — no file edits, no commits.

## PRIORITY probe
<include only when the orchestrator already suspects something: state the suspicion and the
experiment that would confirm or refute it. An unexplained empty result is a finding.>

1. <probe as an executable experiment with its expected outcome, e.g. "feed an 8-candidate
   synthetic input → exactly 4 rows">
2. <negative injection: input that must NOT pass, and what its rejection must look like>
3. <boundary probe>
4. Overengineering lens on the full diff: flag speculative abstraction, dead branches,
   scope spread.
5. Suites (same list the worker ran): <suite list>. Exact numbers.

## Output

VERDICT: APPROVE | NEEDS_WORK
PROBES: numbered results, each with observed vs expected
SUITES: table with exact counts
FINDINGS: [critical|high|medium|low] file:line — reachable failure — validating test
```

## Bounded delta re-review

Same reviewer as the adversarial round. Send after the worker's single fix cycle.

```markdown
# Delta re-review: commit <sha> on <branch>

You are the independent reviewer (a different model repaired your findings <list>).
Bounded DELTA by execution — these items only. Read-only; modify nothing.

1. <your prior finding #1: the experiment that shows it is fixed>
2. <your prior finding #2: ...>
3. No regression on prior probes: spot-rerun ONE probe per area your adversarial round covered.
4. Suites: <same list>. Exact numbers.

## Output

VERDICT: APPROVE | NEEDS_WORK
PROBES: results for the delta items + spot-reruns
SUITES: table with exact counts
```
