# Review prompt templates

The reviewer must be a DIFFERENT provider than the worker that wrote the commits; pick it with
`${CLAUDE_PLUGIN_ROOT}/scripts/pool.sh pick --tier <T> --mode review --deny <worker provider>`. Canonical
verdict tokens are `APPROVE` / `NEEDS_WORK` — always emit these; the runners' gate also
tolerates close variants (`APPROVED`, `NEEDS WORK`) but orchestration decisions key on the
canonical form. Reviewers that must
EXECUTE probes: Codex legs use `--mode review`; Claude, Grok, and Muse review modes are read-only-tooled,
so execute-probe legs on those providers use `--mode probe` with the prompt contract below: the
leg keeps its shell, and the runner exits 6 without a verdict line and 7 when the repository
changed. Every leg goes through
`${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh --author <worker provider>` — never a hand-grep.
Its exit 0 is the merge signal. Omit `--author` only when the brief restricts the run to one provider.

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

Same reviewer as the adversarial round. Send after each fix cycle (up to 5, per the skill's step 6).

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

## Runner mode per reviewer

| Reviewer | Mode | Why |
|---|---|---|
| Codex | `--mode review` | runner enforces APPROVE/NEEDS_WORK |
| Local Qwen | `--mode review` | read-only; `--mode implement` would pass `--yolo` to a reviewer |
| agy | `--mode review` | diff-only from an empty directory; the runner fails 7 if the repo changed |
| Claude / Grok / Muse probe legs | `--mode probe` | shell kept to verify by execution; runner enforces the verdict and an unchanged repository |
| Grok, any review leg | `--effort low` or `medium`, `--timeout` 600 or more | friction report 2026-11-20: `low` reviews took 150–300 s and 4 of 10 timed out under a tighter cap; both `high` reviews failed |

## Local Qwen review leg

`run-qwen-local.sh --mode review --base <range>` only. It is read-only in that mode; `--mode
implement` would hand the reviewer write access (`--yolo`). It needs `--base` because the worker
has no shell and cannot run git itself, and it exits `75` when the one local slot is unavailable —
substitute the card's allowed fallback at once rather than waiting.

It reads the diff; it cannot run anything, and neither can an agy leg (`run-agy.sh --mode review
--base <range>`). Never hand either a template that requires verification by execution. Neither
may be the only reviewer, and that is enforced, not advisory: pass every leg
through `scripts/review-gate.sh --leg <provider>=<final-message-file>`, which exits 3 on a set
containing no independent provider. Use the local leg as an extra decorrelated lens beside a
reviewer that can execute.
