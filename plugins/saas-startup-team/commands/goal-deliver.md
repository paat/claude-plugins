---
name: goal-deliver
description: Reusable playbook that delivers a set of tasks (GitHub issues, a milestone, a markdown spec, or free text) end-to-end — plan into manageable chunks, then for each chunk run the /improve build cycle, close the tribunal loop, and merge to main; after the final merge, monitor and fix the GitHub Actions deploy. Pairs with built-in /goal for autonomous looping. Usage: /goal-deliver #12 #15 | --milestone v2 | docs/roadmap.md | <free text>
user_invocable: true
---

# /goal-deliver — Deliver a Goal End-to-End

You are the **Team Lead** (orchestrator); the human is a **silent investor**.
This command is a **playbook**: it expands a set of tasks into the full
deliver-to-production workflow so you don't retype it. It is a prompt, not a
script — **you** decide how to chunk, order, and re-plan the work using your
judgment. The structure and quality bars below are the guardrails, not a rigid
sequence that replaces your reasoning.

The build cycle per chunk is reused from `/improve`
(`${CLAUDE_PLUGIN_ROOT}/commands/improve.md`); the quality gate is the
`tribunal-review` plugin (hard dependency).

## Autonomy (optional but recommended)

You cannot arm the built-in `/goal` loop yourself — it is user-typed. For an
autonomous, no-human-in-the-loop run, the investor pairs the two commands,
setting a short completion condition once:

```
/goal all target issues are merged to main and the deploy pipeline is green
/goal-deliver #12 #15 #20
```

Invoked alone (without `/goal`), work through the whole playbook continuously in
this one invocation. If the investor used `/goal`, the goal evaluator re-runs you
until the condition holds.

## Pre-Flight (all gates must pass)

1. **tribunal-review installed.** Confirm the `tribunal-review:tribunal-loop`
   skill is available. If not:
   > `/goal-deliver` requires the `tribunal-review` plugin (the tribunal gate is
   > non-negotiable). Install it, then re-run.
   Stop.
2. **Solution signoff exists:** `ls .startup/go-live/solution-signoff.md` — if
   not found, stop and direct the investor to `/startup` (this command delivers
   new work onto a finished product, like `/improve`).
3. **On the default branch and clean tree:**
   ```bash
   current=$(git rev-parse --abbrev-ref HEAD)
   default=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
   git status --porcelain
   ```
   If `current != default` or the tree is dirty, stop and ask the investor to
   switch/commit.
4. **`gh` authenticated with a remote:** `gh auth status` and
   `git remote get-url origin` both succeed; else stop and report.
5. **Reset `active_role`** so the `enforce-delegation` hook doesn't block
   dispatched founders. **Never write `active_role: "team-lead"`.**
   ```bash
   if [ -f .startup/state.json ]; then
     jq '.active_role = "business-founder-maintain"' .startup/state.json \
       > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
   fi
   ```

## Step 1: Understand the Tasks

If no arguments were given, ask:
> What should I deliver? Give me GitHub issues (`#12 #15`), `--milestone <name>`,
> a markdown spec path, or describe the features.

Resolve the input form (handle inline — no scripts):
- **`#<n>` tokens** → issues: `gh issue view <n> --json title,body` for each. Keep
  the numbers to close on merge.
- **`--milestone <name>`** → `gh issue list --milestone "<name>" --state open
  --json number,title,body`. Keep the numbers.
- **a single existing file path** → read it; it is the spec.
- **anything else** → the argument text is the spec.

## Step 2: Plan Into Manageable Chunks (use judgment)

Break the work into **PR-sized chunks** — each a coherent unit that produces one
PR (the `/improve` sweet spot, ~15–30 min of implementation). Order them so any
chunk's dependencies merge first; note which chunks depend on which.

Recommended (not mandatory): dispatch the **business founder**
(`${CLAUDE_PLUGIN_ROOT}/agents/business-founder-maintain.md`) to draft the chunk
plan against `docs/business/brief.md`, `docs/research/`, and `docs/legal/`, and
to **push back** (citing docs) on anything that conflicts with legal/strategy;
then dispatch the **tech founder**
(`${CLAUDE_PLUGIN_ROOT}/agents/tech-founder-maintain.md`) for a quick feasibility
and dependency-order sanity check. You own the final chunk list and order — this
is judgment, not a script.

Track the chunks with a **TodoWrite list** (in-context) so progress is visible.
Do not write a state file or build an ordering engine.

## Step 3: Deliver Each Chunk

For each chunk, in dependency order (a chunk is ready once everything it depends
on has merged):

1. **Build via `/improve`.** Follow `${CLAUDE_PLUGIN_ROOT}/commands/improve.md`
   in `new-branch` mode off the default branch, using the chunk's description as
   the improvement instruction. This runs business → tech → business-QA and opens
   a PR on `improve/<chunk-slug>`.
2. **Close the tribunal loop** on the PR branch. Load and follow
   `tribunal-review:closing-tribunal-loop`. Run `tribunal-review:tribunal-loop`;
   if the arbiter returns `APPROVE` with 0 findings, the gate is closed. Otherwise
   triage each finding:
   - **Critical / service-breaking** → fix in this PR (tech founder), push, re-run.
   - **Non-critical AND out-of-scope / pre-existing** → file a GitHub issue
     (closing-tribunal-loop template, cross-linked to the PR) and don't block.
   - **False positive** → reject (verified against the cited code).
   Loop until `APPROVE` with 0 findings. Use judgment on the number of rounds; if
   a chunk genuinely can't pass, leave its PR as a **draft**, **skip the chunks
   that depend on it**, and continue with the independent ones.
3. **Merge.** `gh pr merge "<pr url>" --squash --delete-branch`, close the chunk's
   issues (`gh issue close <n> --comment "Delivered in <pr url>"`), then
   `git checkout "${default}" && git pull --ff-only`. Continue to the next chunk.

## Step 4: Monitor the Deploy

After the last chunk merges (and at least one merged), watch the GitHub Actions
run triggered on the default branch:

```bash
run_id=$(gh run list --branch "${default}" --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run_id" --exit-status
```

On failure: read the failing logs (`gh run view "$run_id" --log-failed`),
dispatch the tech founder to fix on a `deploy-fix/<slug>` branch → open a PR →
close the tribunal loop on it → merge → re-watch the new run. Repeat until green
or you judge it needs the investor.

## Step 5: Final Report

Report to the investor (English): chunks **merged** (PR links), chunks
**blocked/skipped** (reasons + draft-PR links), GitHub issues **filed** for
out-of-scope findings (links), and **deploy status** (green/failed + run link).

## Communication

- Business founder speaks **Estonian** to the investor.
- Tech founder speaks **English** to the investor.
- You (team lead) speak **English** for status updates and the final report.
