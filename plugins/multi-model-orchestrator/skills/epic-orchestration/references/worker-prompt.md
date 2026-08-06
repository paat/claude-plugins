# Worker prompt template

Instantiate per issue and pass on stdin to the runner named by the route card
(`run-codex.sh --mode implement`, `run-grok.sh --mode implement`, or `run-claude.sh
--mode implement`). Feed **Hard-won constraints** from the handoff's rules-learned section and
from prior review findings on this epic, phrased as prohibitions.

```markdown
# Task: implement GitHub issue #<NNN> (<owner/repo>) — <one-line restatement of the invariant>

You are the workhorse coder. Spawn your own subagents when the task splits cleanly; size their
model and reasoning effort to each subtask.

## Setup

Work in <worktree/repo path>:
`git fetch origin && git checkout -b <feat/NNN-slug> <epic-branch>`
Read `gh issue view <NNN>` fully — the body AND every comment. Grounding docs: <paths>.
Already landed on the epic branch and relevant here: <PRs/commits or "nothing">.

## Core requirements

1. <observable behavior, not implementation>
2. <known trap that must become a regression test>
3. <failure-path behavior: degrade/route, never silently drop>

## Hard-won constraints

- <prior review cause as a prohibition, e.g. "No literal phrase-list gates; use the existing
  binding structure">
- <e.g. "Route or downgrade, never delete">

## Out of scope

<explicit exclusions, or omit the section>

## Verify (run, report honestly; exact numbers)

<explicit suite list: typecheck · lint · <named test suites> · <project gates>>
New regression tests: expected red before the fix — if one is green, report it prominently and
carry on.

## Deliverable

Commit(s) on `<feat/NNN-slug>`, explicit path adds, reference #<NNN>. **No push, no PR.**
Final message: design summary (what you chose and why), per-requirement evidence, regression
list, suite results with exact numbers, anything you were told to do that you did not do.
```
