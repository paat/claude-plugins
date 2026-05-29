# `/goal-deliver` — Deliver-a-Goal Playbook Macro

**Date:** 2026-05-29 (revised — lean playbook design)
**Plugin:** saas-startup-team
**Status:** Approved design — ready for implementation

## Overview

`/goal-deliver` is a **playbook macro**: a reusable slash command that expands a
set of tasks into the full deliver-to-production workflow so the investor never
retypes it. Given GitHub issues, a milestone, a markdown spec file, or a
free-text description, the orchestrator plans the work into manageable chunks
and, for each chunk, runs the `/improve` build cycle → closing tribunal loop →
merge to main, then monitors the GitHub Actions deploy after the final merge.

The command is a **prompt, not an engine**. It deliberately contains no bash
state machine. Chunk boundaries, ordering, dependencies, re-planning, and
when-to-stop are left to the orchestrator's judgment — the command supplies the
structure and the standards, not a rigid script that dictates the next move.
This keeps Claude in control of the flow (the explicit design goal: *don't box
the orchestrator*).

### Why no scripts

An earlier revision proposed two helper scripts (`goal-input.sh` for input
classification and `goal-chunks.sh` for a `plan.json` state machine with
`next`/`block-dependents`/topological ordering). That was dropped: a script that
computes "the next chunk" removes exactly the judgment the orchestrator should
exercise, and adds a maintenance surface for marginal benefit. Input handling
and chunk tracking are plain instructions instead.

### Autonomy

The investor's stated preference is the built-in `/goal` autonomous loop. A
custom command **cannot** arm `/goal` programmatically (it is user-typed only;
the condition lives in session state with no writable hook — verified against
Claude Code docs). So autonomy is achieved by the investor pairing the two
commands:

```
/goal all target issues are merged to main and the deploy pipeline is green
/goal-deliver #12 #15 #20
```

The long workflow now lives inside `/goal-deliver` (typed once, reused forever);
only a short completion condition is typed per run. The command documents this
pattern. It works without `/goal` too — invoked alone, the orchestrator runs the
workflow continuously within the one invocation.

## Input Forms (handled inline, no script)

| Form | Example | Handling |
|---|---|---|
| GitHub issues | `/goal-deliver #12 #15 #20` | `gh issue view <n> --json title,body` each; keep numbers to close on merge |
| Milestone | `/goal-deliver --milestone v2` | `gh issue list --milestone v2 --state open --json number,title,body` |
| Markdown spec file | `/goal-deliver docs/roadmap.md` | the single argument is an existing path → read it as the spec |
| Free text | `/goal-deliver add dark mode, fix nav` | otherwise → the argument text is the spec |

## Pre-Flight (hard gates)

1. **tribunal-review installed** — the `tribunal-review:tribunal-loop` skill must
   be resolvable; else stop with an install hint. Hard dependency — the gate is
   non-negotiable.
2. **`.startup/go-live/solution-signoff.md` exists** — post-completion command,
   like `/improve`; else direct to `/startup`.
3. **On the default branch** and **working tree clean**.
4. **`gh` authenticated** with a remote.
5. **Reset `active_role`** in `.startup/state.json` (to a non-team-lead value) so
   the `enforce-delegation` hook doesn't block dispatched founders. Never write
   `active_role: "team-lead"`.

## Workflow

1. **Understand the tasks** — resolve the input form, build the task spec, keep
   issue numbers.
2. **Plan into chunks (judgment)** — break the work into PR-sized chunks and
   order them so dependencies merge first. Recommended (not mandatory): route the
   plan through the business founder for product/legal context and push-back,
   then a tech-founder feasibility sanity-check — the same agents `/improve`
   uses. Track chunks with an in-context TodoWrite list (no state file).
3. **Deliver each chunk** (dependency order):
   a. Run the `/improve` flow (`commands/improve.md`) in new-branch mode off the
      default branch, using the chunk description as the improvement → a PR.
   b. Closing tribunal loop (`tribunal-review:closing-tribunal-loop`): run
      `tribunal-loop`; triage findings — **critical/service-breaking → fix in the
      PR** and re-run; **non-critical + out-of-scope/pre-existing → file a GitHub
      issue** (skill's template, cross-linked) and don't block; **false positive
      → reject**. Loop until `APPROVE` with 0 findings. If a chunk genuinely
      can't pass, leave its PR as a draft, skip chunks that depend on it, and
      continue with independent chunks.
   c. Squash-merge to main, close the chunk's issues, delete the branch, return
      to the default branch.
4. **Monitor the deploy** — after the last merge, watch the GitHub Actions run on
   the default branch (`gh run watch <id> --exit-status`). On failure: read logs,
   dispatch the tech founder to fix on a `deploy-fix/<slug>` branch → PR →
   closing tribunal loop → merge → re-watch, until green or it needs the investor.
5. **Final report** — chunks merged (PR links), chunks skipped/blocked (reasons +
   draft-PR links), issues filed (links), deploy status.

## Communication

- Business founder speaks **Estonian** to the investor.
- Tech founder speaks **English** to the investor.
- The orchestrator (team lead) speaks **English** for status and the final report.

## Versioning

Bump `saas-startup-team` in **both** `.claude-plugin/plugin.json` and the root
`.claude-plugin/marketplace.json` (0.36.0 → 0.37.0).

## Testing

Cross-file consistency assertions in `tests/run-tests.sh` (new suite, letter
**T** — A–S are taken): command exists, has `name`/`user_invocable` frontmatter,
references the `/improve` flow, references `tribunal-loop` and
`closing-tribunal-loop`, resets `active_role`, warns against `team-lead`,
documents the `/goal` autonomy pairing, and references `gh run` (deploy monitor).
The command is a prompt, so it is covered by consistency checks rather than unit
tests.

## Out of Scope

- A `plan.json` state machine / helper scripts (explicitly dropped).
- Programmatically arming built-in `/goal` (not possible; investor pairs the
  commands).
- A plugin Stop hook for hands-free autonomy (considered; not chosen — the
  `/goal` pairing avoids the scoping risk of a session-wide stop gate).
- Non-GitHub-Actions deploy pipelines; parallel chunk execution.
