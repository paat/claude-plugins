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

**First, strip flags.** If the arguments contain `--full`, set `FULL_MODE=1` and
remove the token from the argument list before resolving the input form below.
`FULL_MODE` forces the normal gated path (Step 1.5 is skipped entirely). All other
arguments resolve as usual; `--full` is never treated as spec text.

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

## Step 1.5: Trivial Fast-Path Routing (single issue only)

Go straight to **Step 2** (skip this whole section) if ANY hold:
- `FULL_MODE` is set (the `--full` flag forced the gated path);
- the delivery resolved to more than one issue, a `--milestone`, a file spec, or
  free text — the fast path handles a **single GitHub issue** only;
- the issue carries any gated label (below).

Otherwise classify the single issue. **Bias: if any check is uncertain, do NOT
fast-path — fall through to Step 2.** A wrong fast-path call ships an unreviewed
edit; a wrong gated call only costs tokens.

### Gated labels — never fast-path

Read the issue labels. If any matches (case-insensitive substring) `bug`, `monitor`,
`customer-issue` (incident/regression — also blocked by the Step 3 regression-test
gate), `security`, `auth`, `payment`, `billing`, `data`, `migration`, `regression`,
`hotfix`, `incident`, `production` — or a repo-specific equivalent — go to Step 2.

### Tweak-eligible rubric (ALL must hold)

- The change is pure copy/text, CSS/visual styling, a **non-sensitive
  presentation/product-copy constant**, or docs/comments.
- No logic or behavior change, no new dependency, no data-model/migration change.
- The exact change is objectively specified in the issue (no design judgment).

If eligible, announce one line, then take the **Trivial Path**:
> Issue #<n> classified as trivial — taking the fast path (bare edit, CI-gated, no agents).

If not eligible, go to **Step 2**.

### Trivial Path

Define the fallback once — **"reset and go gated"** means:
```bash
# discard any uncommitted edit, leave the tweak branch, restore the gated role
git checkout -f "${default}"
git branch -D "tweak/${slug}" 2>/dev/null || true
if [ -f .startup/state.json ]; then
  jq '.active_role = "business-founder-maintain"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```
Then continue at **Step 2**. Use this on every abort below.

1. **Set the edit role** so the `enforce-delegation` hook lets the orchestrator edit
   code directly (no agent is dispatched here):
   ```bash
   if [ -f .startup/state.json ]; then
     jq '.active_role = "team-lead-tweak"' .startup/state.json \
       > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
   fi
   ```
2. **Branch + edit.** `slug=` a hyphenated lowercase form of the issue title (≤40
   chars); `git checkout -b "tweak/${slug}" "${default}"`. Read the relevant file(s);
   make the **minimal** edit the issue specifies. No founders, QA, or tribunal.
3. **Containment self-check — mechanical, on the real diff.** The classification was a
   guess; the diff is the truth. Run:
   ```bash
   changed=$(git diff "${default}" --name-only)
   nfiles=$(printf '%s\n' "$changed" | grep -c .)
   nlines=$(git diff "${default}" --numstat | awk '{a+=$1+$2} END{print a+0}')
   denylist='(^|/)(auth|login|session|oauth|passwd|password|payment|billing|invoice|checkout|stripe|security|secret|crypto|token)|\.env|(^|/)\.github/|[Dd]ockerfile|(^|/)migrations?/|\.sql$|(^|/)package(-lock)?\.json$|(^|/)(yarn\.lock|pnpm-lock\.yaml)$|\.(lock|min\.js|map)$|(^|/)(dist|build|vendor|node_modules)/'
   if [ "$nfiles" -gt 3 ] || [ "$nlines" -gt 15 ] || printf '%s\n' "$changed" | grep -iqE "$denylist"; then
     echo "Containment breach (files=$nfiles lines=$nlines or sensitive path) — reset and go gated"
     # → run the "reset and go gated" block, then Step 2
   fi
   ```
   (The denylist is a mechanical backstop; the rubric's judgment about sensitive
   surfaces still applies on top of it.)
4. **Commit — keep hooks.**
   ```bash
   git add -A
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-staged-size.sh" || {
     echo "Aborting: staged tree has oversized/ignored files." >&2; exit 1; }
   git commit -m "tweak: <summary> (#<n>)"
   ```
   **Never pass `--no-verify`** — project pre-commit hooks (lint/type-check) are part
   of the CI backstop.
5. **Push + PR with the closing-metadata contract, and capture the PR number.**
   ```bash
   git push -u origin HEAD
   gh pr create --title "tweak: <summary> (#<n>)" --body "Fixes #<n>

   Trivial fast-path delivery (bare edit, CI-gated, no agents)."
   pr_num=$(gh pr view --json number --jq .number)   # explicit — never guess from branch
   ```
6. **Pre-merge CI gate.** A green merge requires that the PR has **at least one CI
   check AND every check passes** — a repo with no CI cannot satisfy the bare-ship
   backstop, so "no checks" is treated as not-green (gated), never as a free pass.
   Count the checks first, then wait:
   ```bash
   n_checks=$(gh pr checks "$pr_num" 2>/dev/null | grep -c .)   # 0 if none reported
   if [ "${n_checks:-0}" -eq 0 ]; then
     checks_status=1                                            # no CI → not-green
   else
     gh pr checks "$pr_num" --watch --fail-fast; checks_status=$?
   fi
   ```
   - `checks_status` **0** (checks exist and all passed) → run the **role reset only**
     (`jq '.active_role="business-founder-maintain"' …` — keep the branch/commit),
     `git checkout "${default}"`, then hand **`$pr_num`** to **Step 3 item 3** (merge
     `--squash --delete-branch` + close the issue) and continue to **Step 4**
     (deploy watch). No tribunal, no founder, no QA.
   - `checks_status` **non-zero** (a check failed, OR no CI checks exist — both are
     not-green) → main was never touched. Close the trivial PR
     (`gh pr close "$pr_num" --delete-branch`), then run the **"reset and go gated"**
     block and re-deliver this issue on the normal gated path (Step 2). Inside
     `/maintain` this fallback runs in the same inline `/goal-deliver`, so it does
     not trip a cooldown.

A red **deploy** after a green merge is the post-merge case — the existing **Step 4**
deploy-fix handling, unchanged.

## Step 2: Plan Into Manageable Chunks (use judgment)

Break the work into **PR-sized chunks** — each a coherent unit that produces one
PR (the `/improve` sweet spot, ~15–30 min of implementation). Order them so any
chunk's dependencies merge first; note which chunks depend on which.

Recommended (not mandatory): dispatch the **business founder**
(`${CLAUDE_PLUGIN_ROOT}/agents/business-founder-maintain.md`) to draft the chunk
plan against `docs/business/brief.md`, `docs/research/`, and `docs/legal/`, and
to **push back** (citing docs) on anything that conflicts with legal/strategy;
then dispatch the **tech founder**
(`${CLAUDE_PLUGIN_ROOT}/agents/tech-founder-claude-maintain.md` — feasibility/dependency
reasoning is judgment, so use the Claude engine here; later per-chunk implementation
still routes by engine per the engine-selection guidance) for a quick feasibility
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
   if the arbiter returns **zero critical and zero high**, the gate is closed
   (leftover medium/low → YAGNI triage: file a follow-up only if real and worth
   acting on, else drop with a PR-body note). While any critical/high remains:
   - **Rounds 1–2:** fix directly (tech founder), push, re-run.
   - **Round 3+:** step-back mode — simplify, descope (remove mechanism + file
     follow-up), or have the arbiter down-rate the class; never guard-pile.
   - **Round 10:** notify the investor (still grinding) without stopping.
   - **Round 20:** stop and escalate to the investor with the standing finding.
   Then **skip the chunks that depend on it** and continue with independent ones.
3. **Merge.** `gh pr merge "<pr url>" --squash --delete-branch`, close the chunk's
   issues (`gh issue close <n> --comment "Delivered in <pr url>"`), then
   `git checkout "${default}" && git pull --ff-only`. Continue to the next chunk.
   Note: if a chunk resolves an incident-labeled issue (`bug`/`monitor`/`customer-issue`)
   the merge is **blocked by the regression-test gate** unless the PR diff adds a test —
   ensure the tech founder's Bug Fix Protocol test landed in the PR (or record
   `Regression-Test: none — <reason>` in the PR body) before merging.

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
