# Trivial Fast-Path Routing in `/goal-deliver` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route a single trivial GitHub issue (copy/CSS/non-sensitive constant/docs) through a bare tweak-style fast path inside `/goal-deliver`, skipping founder/QA/tribunal dispatches, while keeping the existing merge/deploy/close tail and a pre-merge CI gate.

**Architecture:** All routing lives in one new section of `commands/goal-deliver.md` ("Step 1.5"), plus a `--full` flag parsed in Step 1. On a single-issue delivery with no `--full` flag, classify against a conservative rubric + label/path denylist; if trivial, do a bare orchestrator edit on a `tweak/<slug>` branch, run a mechanical post-edit containment self-check, open a PR with the `Fixes #<n>` contract, wait for required CI checks, then hand the explicit PR number to the existing merge step. Any uncertainty, denylist hit, containment breach, or red pre-merge check resets state and falls back to the normal gated path. Multi-issue / milestone / spec deliveries never fast-path.

**Tech Stack:** Markdown command prompts (Claude Code plugin), `gh` CLI, `jq`, bash. No application code — verification is structural (grep), the repo's `.githooks/pre-push` version-sync hook, and a Codex review of each stage's diff.

## Global Constraints

- Plugins must stay generic/project-agnostic — no hardcoded company/product/path names; use the existing template/variable conventions (`${CLAUDE_PLUGIN_ROOT}`, `${default}`). (CLAUDE.md)
- Bump the plugin version in BOTH `plugins/saas-startup-team/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`, kept in sync — the `.githooks/pre-push` hook enforces this. (CLAUDE.md)
- Bash 4+ / POSIX tools only. (CLAUDE.md)
- **State invariant:** the trivial path sets `.startup/state.json` `active_role` to `team-lead-tweak`; **every** exit from the trivial path (containment abort, CI-red fallback, or successful hand-off to the gated path) must first reset `active_role` back to `business-founder-maintain` (the Pre-Flight value) so a subsequent founder dispatch is not blocked by the `enforce-delegation` hook.
- **Process:** each task is reviewed with Codex before commit, via `codex exec --dangerously-bypass-approvals-and-sandbox -` with a single combined stdin stream (prompt file + diff concatenated — NOT a heredoc, which swallows the piped stdin). The dev container is the security boundary.
- Current version: `0.63.0` → target `0.64.0` (additive feature = minor bump).

---

## Codex review helper (used by every task)

Each task's review step uses this exact pattern. Write the prompt once:

```bash
mkdir -p /tmp/gd-fastpath
cat > /tmp/gd-fastpath/review-prompt.md <<'EOF'
You are a senior reviewer. Below is a diff for the saas-startup-team plugin.
Context: /goal-deliver delivers a GitHub issue end-to-end (plan → /improve agents →
tribunal gate → merge → deploy-watch). This change adds a "trivial fast-path" that,
for a single trivially-scoped issue, does a bare orchestrator edit (no agents, no
tribunal), gated only by required PR CI checks before merge, with a mechanical
post-edit containment self-check and fallback to the full gated path on any
uncertainty or red check. Files are markdown command prompts (AI instructions),
not application code; grep + a version-sync git hook are the expected verification.
Review ONLY this diff for: correctness gaps, safety holes (a non-trivial change
slipping through to bare-ship), state leaks (active_role / dirty worktree across a
fallback), broken references to other steps/files, and shell bugs. Be concise,
concrete, most-important-first. If sound, say so plainly.
=== DIFF BELOW ===
EOF
```

Then per task: `git diff --staged > /tmp/gd-fastpath/stage.diff && cat /tmp/gd-fastpath/review-prompt.md /tmp/gd-fastpath/stage.diff | codex exec --dangerously-bypass-approvals-and-sandbox -`
Address any blocking finding before committing. Record the disposition in the commit body.

---

## Task 1: Trivial fast-path section in `/goal-deliver`

**Files:**
- Modify: `plugins/saas-startup-team/commands/goal-deliver.md` — (a) add `--full` parsing to "## Step 1: Understand the Tasks"; (b) insert a new "## Step 1.5" section between Step 1 and "## Step 2: Plan Into Manageable Chunks".

**Interfaces:**
- Consumes (existing, unchanged): `${default}` (default-branch var from Pre-Flight), `${CLAUDE_PLUGIN_ROOT}/scripts/check-staged-size.sh`, Step 3 item 3 (merge/close) and its incident regression-test gate, Step 4 (deploy watch), the `.startup/state.json` `active_role` convention (Pre-Flight sets `business-founder-maintain`).
- Produces: the routing contract — a single-issue trivial delivery is handled entirely within Step 1.5 (edit → PR → CI gate → hand explicit PR number to Step 3 item 3 → Step 4); every non-eligible case resets `active_role` and falls through to Step 2 unchanged. Introduces the `--full` flag and the `Fixes #<n>` PR-body contract.

- [ ] **Step 1: Wire the `--full` flag into Step 1 parsing**

In `## Step 1: Understand the Tasks`, immediately under the heading (before "If no arguments were given"), insert:

```markdown
**First, strip flags.** If the arguments contain `--full`, set `FULL_MODE=1` and
remove the token from the argument list before resolving the input form below.
`FULL_MODE` forces the normal gated path (Step 1.5 is skipped entirely). All other
arguments resolve as usual; `--full` is never treated as spec text.
```

- [ ] **Step 2: Insert the Step 1.5 section**

Insert the following block immediately before `## Step 2: Plan Into Manageable Chunks (use judgment)`:

````markdown
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
6. **Pre-merge CI gate.** Wait for checks and interpret conservatively:
   ```bash
   gh pr checks "$pr_num" --watch --fail-fast; checks_status=$?
   ```
   - `checks_status` **0** (all checks passed) → run the **role reset only**
     (`jq '.active_role="business-founder-maintain"' …` — keep the branch/commit),
     `git checkout "${default}"`, then hand **`$pr_num`** to **Step 3 item 3** (merge
     `--squash --delete-branch` + close the issue) and continue to **Step 4**
     (deploy watch). No tribunal, no founder, no QA.
   - `checks_status` **non-zero** (a check failed, or no checks could be determined —
     treat either as not-green) → main was never touched. Close the trivial PR
     (`gh pr close "$pr_num" --delete-branch`), then run the **"reset and go gated"**
     block and re-deliver this issue on the normal gated path (Step 2). Inside
     `/maintain` this fallback runs in the same inline `/goal-deliver`, so it does
     not trip a cooldown.

A red **deploy** after a green merge is the post-merge case — the existing **Step 4**
deploy-fix handling, unchanged.
````

- [ ] **Step 3: Verify structure & flag wiring**

Run: `grep -n "FULL_MODE\|Step 1.5: Trivial Fast-Path\|Trivial Path\|Containment self-check\|gh pr checks\|reset and go gated\|pr_num=" plugins/saas-startup-team/commands/goal-deliver.md`
Expected: `FULL_MODE` appears in both Step 1 and Step 1.5; the section heading, containment check, CI gate, the shared reset block, and explicit `pr_num` capture are all present.

Run: `grep -n "^## Step 2: Plan Into Manageable Chunks" plugins/saas-startup-team/commands/goal-deliver.md`
Expected: the Step 2 heading still exists exactly once, after the new section.

- [ ] **Step 4: Confirm referenced anchors still exist (no dangling refs)**

Run: `grep -n "check-staged-size.sh\|gh pr merge\|Monitor the Deploy\|business-founder-maintain\|regression-test gate" plugins/saas-startup-team/commands/goal-deliver.md`
Expected: `check-staged-size.sh`, the Step 3 merge command, the Step 4 deploy heading, the `business-founder-maintain` role (Pre-Flight + the new reset), and the Step 3 regression-test gate — all present.

- [ ] **Step 5: Codex review the staged diff**

```bash
git add plugins/saas-startup-team/commands/goal-deliver.md
git diff --staged > /tmp/gd-fastpath/stage.diff
cat /tmp/gd-fastpath/review-prompt.md /tmp/gd-fastpath/stage.diff | codex exec --dangerously-bypass-approvals-and-sandbox -
```
Address any blocking safety/state finding before committing. If accepted, fix and re-stage; if rejected, note why in the commit body.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(saas-startup-team): trivial fast-path routing in /goal-deliver

Single trivially-scoped issues take a bare edit + CI-gated merge instead of the
founder/QA/tribunal cycle. Conservative rubric + label/path denylist + mechanical
post-edit containment self-check; every exit resets active_role and falls back to
the gated path on any uncertainty or red pre-merge check. --full forces gated.
Multi-issue/milestone/spec never fast-path.

Codex-reviewed.

Claude-Session: https://claude.ai/code/session_014Hx3q2ryt2gLDmwzWWHoWB"
```

---

## Task 2: Doc-sync note in `/maintain`

**Files:**
- Modify: `plugins/saas-startup-team/commands/maintain.md` — add one note where it describes running `/goal-deliver` inline per issue (near "Run `/goal-deliver` inline scoped to that one issue.", ~line 258).

**Interfaces:**
- Consumes: the Task 1 routing contract (fast-path + reset-and-fallback, all internal to the inline run).
- Produces: documentation only. Confirms no maintain-level change is needed — the internal reset+fallback means a failed/aborted fast-path attempt is not a maintain "failure" and triggers no cooldown.

- [ ] **Step 1: Add the note**

After the line "Run `/goal-deliver` inline scoped to that one issue." insert:

```markdown
   > `/goal-deliver` self-routes a trivially-scoped single issue to its built-in
   > fast path (bare edit, CI-gated, no agents). If the fast path aborts before
   > merge — for any reason (containment breach, sensitive path, or red pre-merge
   > checks) — it resets state and falls back to the full gated path **inside the
   > same inline run**, so a failed fast-path attempt is not a maintain-level
   > failure and triggers no cooldown.
```

- [ ] **Step 2: Verify**

Run: `grep -n "self-routes a trivially-scoped\|aborts before" plugins/saas-startup-team/commands/maintain.md`
Expected: the note is present immediately after the inline-delivery line and mentions the abort-before-merge fallback (not just red checks).

- [ ] **Step 3: Codex review the staged diff**

```bash
git add plugins/saas-startup-team/commands/maintain.md
git diff --staged > /tmp/gd-fastpath/stage.diff
cat /tmp/gd-fastpath/review-prompt.md /tmp/gd-fastpath/stage.diff | codex exec --dangerously-bypass-approvals-and-sandbox -
```
Confirm the note matches Task 1 behavior and does not contradict maintain.md's cooldown logic.

- [ ] **Step 4: Commit**

```bash
git commit -m "docs(saas-startup-team): note /goal-deliver self-routes trivial issues in /maintain

Codex-reviewed.

Claude-Session: https://claude.ai/code/session_014Hx3q2ryt2gLDmwzWWHoWB"
```

---

## Task 3: Version bump + release verification

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json` — `"version": "0.63.0"` → `"0.64.0"`.
- Modify: `.claude-plugin/marketplace.json` — the `saas-startup-team` entry `"version": "0.63.0"` → `"0.64.0"` (line ~67).

**Interfaces:**
- Consumes: nothing.
- Produces: a synced version pair that satisfies `.githooks/pre-push`.

**Precondition:** Tasks 1 and 2 are committed, so the worktree is clean before this task starts.

- [ ] **Step 1: Bump plugin.json**

Edit `plugins/saas-startup-team/.claude-plugin/plugin.json`: change `"version": "0.63.0"` to `"version": "0.64.0"`.

- [ ] **Step 2: Bump marketplace.json**

Edit `.claude-plugin/marketplace.json`: in the `saas-startup-team` entry, change `"version": "0.63.0"` to `"version": "0.64.0"`.

- [ ] **Step 3: Verify the two versions match**

Run: `grep -n '"version"' plugins/saas-startup-team/.claude-plugin/plugin.json; grep -n -A2 '"name": "saas-startup-team"' .claude-plugin/marketplace.json | grep version`
Expected: both show `0.64.0`.

- [ ] **Step 4: Stage only the two manifests and run the version-sync hook**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
bash .githooks/pre-push origin "$(git remote get-url origin 2>/dev/null || echo none)" </dev/null
status=$?
echo "hook exit: $status"
test "$status" -eq 0
```
Expected: `hook exit: 0` and the final `test` succeeds (non-zero → the hook printed the mismatch it found; fix it). Targeted `git add` avoids staging unrelated work; this is a local dry run and does not push.

- [ ] **Step 5: Commit**

```bash
git commit -m "chore(saas-startup-team): v0.64.0 — trivial fast-path routing

Claude-Session: https://claude.ai/code/session_014Hx3q2ryt2gLDmwzWWHoWB"
```

---

## Self-Review

**Spec coverage:**
- Branch inside `/goal-deliver`, all flows → Task 1 (Step 1.5). ✅
- Single-issue-only precondition → Task 1 skip-conditions. ✅
- `/tweak`-body + `/goal-deliver`-tail (active_role, bare edit, reuse Step 3 merge + Step 4) → Task 1 Trivial Path items 1–6. ✅
- Conservative rubric + uncertainty bias → Task 1 rubric block. ✅
- Label denylist (broadened) + mechanical path/file denylist → Task 1 "Gated labels" + containment item 3 regex. ✅
- Containment post-edit self-check (file/line caps, sensitive paths) → Task 1 item 3 (executable). ✅
- Pre-merge CI gate (conservative no-checks handling) → Task 1 item 6. ✅
- Two-mode failure (pre-merge red/abort → reset+Step 2; post-merge red → Step 4) → Task 1 shared reset block + item 6 + closing line. ✅
- State invariant: active_role reset on every exit → Global Constraints + Task 1 shared reset block + item 6 green branch. ✅
- Explicit PR-number hand-off + `Fixes #<n>` contract → Task 1 items 5–6 (`pr_num`). ✅
- `--full` escape hatch wired into parsing + routing announcement → Task 1 Step 1 + Step 1.5. ✅
- Cooldown carve-out (reset+fallback internal to inline run) → Task 1 item 6 + Task 2 note. ✅
- Version bump in both manifests, synced & hook-checked → Task 3. ✅
- Deferred per-chunk routing → not implemented (correct; out of v1 scope). ✅

**Placeholder scan:** `<slug>`, `<n>`, `<summary>` are intentional runtime fill-ins inside prompt prose (copied verbatim; the command executor resolves them at run time), not plan placeholders. `$pr_num`/`$slug`/`$status` are real shell variables. No "TBD/TODO/handle edge cases" remain.

**Type/anchor consistency:** Referenced anchors — `${default}`, `${slug}`, `check-staged-size.sh`, "Step 3 item 3"/regression-test gate, "Step 4", `active_role` values `team-lead-tweak`/`business-founder-maintain`, `gh pr create`/`gh pr view`/`gh pr checks`/`gh pr close`, `FULL_MODE`, `pr_num` — all defined where used and consistent across tasks. Version strings `0.63.0`→`0.64.0` consistent in Task 3.

## Codex plan-review disposition (2026-06-27)

Reviewed each task with Codex; accepted and fixed all findings: (T1) forced-discard cleanup + `active_role` reset on every fallback via a shared "reset and go gated" block; `--full` wired into Step 1 parsing; mechanical denylist regex + numeric file/line caps; explicit `pr_num` capture; conservative CI-gate interpretation incl. no-checks→gated. (T2) note widened to cover abort-before-merge, not only red checks. (T3) hook exit status captured in a variable with a real `test`; targeted `git add` of only the two manifests.
