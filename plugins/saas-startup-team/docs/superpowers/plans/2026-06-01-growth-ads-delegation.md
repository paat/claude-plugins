# Growth → Ads Delegation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `saas-startup-team`'s growth track delegate all Google Ads work to the `google-ads-strategist` plugin's `ads-strategist` agent — automatically (via the `/growth` loop reacting to a flag) and on-demand (via a new `/ads` command) — both spawning the strategist at the orchestrator level by registered agent type.

**Architecture:** Two entry points, one engine. `growth-hacker` stops doing Google Ads itself and instead writes a `## Google Ads request` block in its growth report; the `/growth` loop reads that and spawns `ads-strategist` at the top level. A new `/saas-startup-team:ads` command lets the investor trigger the same spawn directly. Both use `Task(subagent_type: "ads-strategist")` (the registered type — never the saas `general-purpose`+read-md idiom, which resolves `${CLAUDE_PLUGIN_ROOT}` to the wrong plugin). `ads-strategist` creates campaigns PAUSED; the investor enables. Records: `docs/ads/<campaign>/` is the source of truth; `docs/growth/channels/ads.md` becomes a lightweight index that retains the budget summary lines `check-ad-budget.sh` depends on.

**Tech Stack:** Markdown agents/commands, bash hook scripts, bash test harness (`tests/run-tests.sh`), `jq`. No application code.

**Spec:** `plugins/saas-startup-team/docs/superpowers/specs/2026-06-01-growth-ads-delegation-design.md`

---

## File Structure

**saas-startup-team:**
- Create: `plugins/saas-startup-team/commands/ads.md` — new consultant command (spawns `ads-strategist`).
- Modify: `plugins/saas-startup-team/commands/growth.md` — add the automatic Growth→Ads delegation branch.
- Modify: `plugins/saas-startup-team/agents/growth-hacker.md` — "flag, don't spawn" for Google Ads; `ads.md` becomes an index.
- Modify: `plugins/saas-startup-team/README.md` — commands table, prerequisites, index relationship.
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` — new Suite U (ads command + growth-ads delegation + growth-hacker rules).
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json` — 0.37.0 → 0.38.0.

**google-ads-strategist:**
- Modify: `plugins/google-ads-strategist/agents/ads-strategist.md` — programmatic `brief.md` creation.
- Modify: `plugins/google-ads-strategist/README.md` — "Relationship to other plugins".
- Modify: `plugins/google-ads-strategist/.claude-plugin/plugin.json` — 0.4.1 → 0.5.0.

**repo root:**
- Modify: `.claude-plugin/marketplace.json` — both version bumps.

**Convention note:** the test harness's `assert_file_contains "label" "$path" "pattern"` uses `grep -q` (basic regex); `assert_output_not_contains "label" "$output" "string"` uses `grep -qF` (fixed string). Match these in test steps. Commit after each task (frequent commits). Run the full suite with `bash plugins/saas-startup-team/tests/run-tests.sh`.

---

### Task 1: New `/ads` consultant command

**Files:**
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (add Suite U + register in `main()`)
- Create: `plugins/saas-startup-team/commands/ads.md`

- [ ] **Step 1: Write the failing test (Suite U, ads-command assertions)**

Append this function at the end of `plugins/saas-startup-team/tests/run-tests.sh`, immediately **before** the final `main "$@"` line:

```bash
# ---------------------------------------------------------------------------
# Suite U: /ads command + growth→ads delegation
# ---------------------------------------------------------------------------

test_ads_delegation() {
  echo -e "\n${CYAN}Suite U: /ads command + growth→ads delegation${NC}"
  local cmd="$PLUGIN_ROOT/commands/ads.md"

  # U1–U8: the new /ads command
  assert_file_exists "U1: ads.md exists" "$cmd"
  assert_file_contains "U2: name frontmatter" "$cmd" "^name: ads"
  assert_file_contains "U3: user_invocable" "$cmd" "user_invocable: true"
  assert_file_contains "U4: spawns ads-strategist by registered type" "$cmd" 'subagent_type: "ads-strategist"'
  assert_file_contains "U5: resets active_role" "$cmd" '.active_role ='
  assert_file_contains "U6: creates PAUSED / investor enables" "$cmd" "PAUSED"
  assert_file_contains "U7: hard-dependency install message" "$cmd" "google-ads-strategist"
  # U8: must NOT use the saas read-md idiom (would resolve to the wrong plugin root)
  local ads_content
  ads_content=$(cat "$cmd")
  assert_output_not_contains "U8: no read-md idiom for the strategist" "$ads_content" 'agents/ads-strategist.md'
}
```

Then register it in `main()` by adding the call after `test_goal_deliver` (line ~2279):

```bash
  test_goal_deliver
  test_ads_delegation
```

- [ ] **Step 2: Run the suite to verify U1–U8 fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "U[0-9]"`
Expected: `U1: ads.md exists` FAILs (file missing); the suite exits non-zero.

- [ ] **Step 3: Create `plugins/saas-startup-team/commands/ads.md`**

```markdown
---
name: ads
description: On-demand Google Ads campaign design — spawns the google-ads-strategist's ads-strategist agent to design, browser-verify, and create a campaign in PAUSED state for investor review. Usage: /ads <campaign brief or objective>
user_invocable: true
argument-hint: <campaign brief or objective>
---

# /ads — On-Demand Google Ads Campaign

The investor requests a Google Ads campaign. You (the Team Lead) spawn the **ads-strategist** agent from the `google-ads-strategist` plugin to design it through the iterative loop, verify it in the browser, and create it in **PAUSED** state. The investor reviews in the Ads UI and enables it.

**ads-strategist is a one-shot specialist, NOT a loop participant.** It spawns, designs/verifies/creates the campaign in `docs/ads/<campaign>/`, and exits. This command is the investor-initiated twin of the automatic Growth→Ads delegation in `/growth`.

## Pre-Flight Checks (HARD FAIL — No Fallbacks)

All of the following must pass. If any fails, stop with the error and do NOT proceed. There is no inline fallback — Google Ads work requires the `google-ads-strategist` plugin (hard dependency).

### Check 1: Startup project exists

Verify these files exist:
- `.startup/state.json`
- `docs/business/brief.md`

**If missing:**
> **Error:** No startup project found. Run `/startup` first to initialize the project before running `/ads`.

### Check 2: Chrome MCP is reachable

Attempt to call `mcp__claude-in-chrome__tabs_context_mcp`. The strategist verifies every keyword in the real browser (Ad Preview Tool, SERP, Transparency Center) and creates the campaign via Chrome.

**If unavailable:**
> **Error:** Chrome browser MCP (claude-in-chrome) is not available. ads-strategist needs Chrome for Ad Preview verification and campaign creation. Connect Chrome and retry.

## Step 0: Reset active_role

Overwrite `active_role` in `.startup/state.json` before spawning. The `enforce-delegation` and `check-stop` hooks bypass for Task-spawned agents via the `--agent-id` process-tree check, but resetting clears any stale `"team-lead"` value that could block an edge-case Edit. Same pattern as `/lawyer` Step 0.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "ads-strategist"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

## Step 1: Determine the campaign slug

If `docs/growth/channels/ads.md` exists and names an active campaign slug, reuse it (so this command and the `/growth` loop converge on one campaign, not two). Otherwise derive a stable slug `<product>-<intent>-<market>` (e.g. `aruannik-commercial-ee`) from the brief.

```bash
mkdir -p docs/ads
```

## Step 2: Gather context for the strategist

Read whichever of these exist, to pass as context:
- `docs/business/brief.md` — what the product is
- `docs/growth/product-brief.md` — sales-ready product description, ICP, pricing
- `docs/growth/strategy.md` — ICP, channels, goals
- `docs/growth/brand/approved-voice.md` — tone, approved messaging
- `docs/growth/channels/ads.md` — existing campaign index + approved budget

## Step 3: Spawn the ads-strategist

Use the `Task` tool with `subagent_type: "ads-strategist"` — the registered agent type provided by the `google-ads-strategist` plugin. Do **NOT** spawn `general-purpose` and have it read the strategist's agent-definition markdown by `${CLAUDE_PLUGIN_ROOT}` path: in this command `${CLAUDE_PLUGIN_ROOT}` is the saas plugin, so that path does not exist, and the strategist's own `${CLAUDE_PLUGIN_ROOT}` skill/template references only resolve when it runs natively under its own plugin.

**If Claude Code reports the `ads-strategist` agent type is unknown**, the `google-ads-strategist` plugin is not installed. Stop with:
> **Error:** The `ads-strategist` agent is not available. `/ads` requires the **google-ads-strategist** plugin. Install it from the marketplace (`/plugin marketplace … && /plugin install google-ads-strategist`), then retry.

Pass the strategist this brief:

> **Campaign:** `<slug>`
>
> **Objective (from the investor):** `$ARGUMENTS`
>
> **Context (read these for product, audience, budget, brand, final-URL):**
> - `docs/business/brief.md`
> - `docs/growth/product-brief.md`
> - `docs/growth/strategy.md`
> - `docs/growth/brand/approved-voice.md`
> - `docs/growth/channels/ads.md` (existing campaigns + approved budget cap — do NOT exceed it in forecasts)
>
> If `docs/ads/<slug>/brief.md` does not exist, create it from the context above (product, audience, budget, goals, brand, final-URL template), then run your pre-launch iteration loop, verify in the browser, and create the campaign in **PAUSED** state. Do NOT enable it — the investor enables after review.

## Step 4: Report to the investor (English)

After the strategist completes, summarize:
- Campaign folder written: `docs/ads/<slug>/`
- Iteration / verification status (which keywords trigger the ad, position, competitor differentiation)
- Whether the campaign was created PAUSED in the Ads UI
- **Next action for the investor:** review the campaign in Google Ads and enable it when satisfied — the plugin never enables.
- Update `docs/growth/channels/ads.md` index entry for `<slug>` (status: designed/created-paused) if it changed.
```

- [ ] **Step 4: Run the suite to verify U1–U8 pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "U[0-9]"`
Expected: U1–U8 all PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/ads.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): add /ads consultant command spawning ads-strategist"
```

---

### Task 2: `/growth` loop auto-delegation branch

**Files:**
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (extend Suite U)
- Modify: `plugins/saas-startup-team/commands/growth.md` (add branch after "Growth-to-Build handoff")

- [ ] **Step 1: Write the failing test (extend `test_ads_delegation`)**

In `test_ads_delegation()` (added in Task 1), append after the U8 block:

```bash
  # U9–U11: the /growth loop auto-delegation branch
  local growth="$PLUGIN_ROOT/commands/growth.md"
  assert_file_contains "U9: growth.md has Google Ads request branch" "$growth" "Google Ads request"
  assert_file_contains "U10: growth loop spawns ads-strategist by type" "$growth" 'subagent_type: "ads-strategist"'
  local growth_content
  growth_content=$(cat "$growth")
  assert_output_not_contains "U11: growth loop uses no read-md idiom for strategist" "$growth_content" 'agents/ads-strategist.md'
```

- [ ] **Step 2: Run the suite to verify U9–U11 fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "U(9|10|11)"`
Expected: U9 and U10 FAIL (text not present yet).

- [ ] **Step 3: Add the branch to `commands/growth.md`**

Find this existing block (in "## Step 4: Run Growth Loop"):

```markdown
### Growth-to-Build handoff

When a growth report flags an urgent issue or a product change needed:

1. Read the growth report
2. Dispatch business founder to write a feature handoff to tech founder
3. This enters the normal build track loop
```

Insert this new subsection **immediately after** that block:

```markdown
### Growth-to-Ads delegation (automatic)

When a growth report contains a `## Google Ads request` block, the growth hacker has flagged Google Ads work it must NOT do itself (the `google-ads-strategist` plugin is a hard dependency for Google Ads). Delegate it at the team-lead level — do not have the growth hacker spawn anything (no nested subagents).

1. Read the `## Google Ads request` block (it carries product, ICP, approved budget cap, brand, final-URL template, and a campaign slug).
2. Reset `active_role` (defensive, matches `/lawyer`):
   ```bash
   if [ -f .startup/state.json ]; then
     jq '.active_role = "ads-strategist"' .startup/state.json \
       > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
   fi
   ```
3. Spawn the strategist with the `Task` tool using `subagent_type: "ads-strategist"` (the registered type from `google-ads-strategist` — **not** `general-purpose`+read-md, which would resolve `${CLAUDE_PLUGIN_ROOT}` to the saas plugin). Pass the request block plus `docs/business/brief.md`, `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md`, and `docs/growth/channels/ads.md`, with the instruction: create `docs/ads/<slug>/brief.md` from this context if absent, run the pre-launch loop, verify in the browser, and create the campaign **PAUSED**.
4. **If the `ads-strategist` agent type is unknown**, the `google-ads-strategist` plugin is not installed. Stop and tell the investor to install it (`/plugin install google-ads-strategist`); do NOT fall back to building the campaign inline.
5. After the strategist returns, update the `docs/growth/channels/ads.md` index entry for the slug (status: created-paused), then continue the growth loop.

**Pre-launch caveat:** if the product is not yet live (`/growth --pre-launch`, no commercial landing page / `final_url`), defer the ads request — note it as a human task and continue — rather than building a campaign that cannot route traffic.
```

- [ ] **Step 4: Run the suite to verify U9–U11 pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "U(9|10|11)"`
Expected: U9, U10, U11 all PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/growth.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): /growth loop auto-delegates Google Ads to ads-strategist"
```

---

### Task 3: `growth-hacker` — flag, don't do Google Ads

**Files:**
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (extend Suite U)
- Modify: `plugins/saas-startup-team/agents/growth-hacker.md`

- [ ] **Step 1: Write the failing test (extend `test_ads_delegation`)**

In `test_ads_delegation()`, append after the U11 block:

```bash
  # U12–U15: growth-hacker flags Google Ads instead of doing it
  local gh="$PLUGIN_ROOT/agents/growth-hacker.md"
  assert_file_contains "U12: boundary forbids designing/creating/spawning Google Ads" "$gh" "NEVER design, create, or spawn Google Ads"
  assert_file_contains "U13: growth-hacker writes a Google Ads request flag" "$gh" "Google Ads request"
  assert_file_contains "U14: ads.md index retains budget summary lines" "$gh" "Approved budget:"
  local gh_content
  gh_content=$(cat "$gh")
  assert_output_not_contains "U15: no inline 'create the Google Ads campaign in the dashboard'" "$gh_content" "the Google Ads campaign in the dashboard"
```

- [ ] **Step 2: Run the suite to verify U12–U15 fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "U1[2345]"`
Expected: U12, U13, U14 FAIL (text absent); U15 FAILs (the inline phrase still present at line 21).

- [ ] **Step 3a: Replace the "EXECUTE, DON'T PLAN" Google Ads example**

In `plugins/saas-startup-team/agents/growth-hacker.md`, find (line ~21):

```markdown
- **Create** the Google Ads campaign in the dashboard — don't write a campaign plan document
```

Replace with (keeps the lesson for an ad channel growth-hacker still owns directly):

```markdown
- **Create** the Meta Ads campaign in Ads Manager — don't write a campaign plan document
```

- [ ] **Step 3b: Rewrite "### 3. Ad Campaign Management"**

Find:

```markdown
### 3. Ad Campaign Management
- Manage Google Ads, Meta Ads, LinkedIn Ads dashboards via Chrome browser
- Never exceed approved budget — check budget in growth brief before any ad action
- Track campaign performance in `docs/growth/channels/ads.md`
```

Replace with:

```markdown
### 3. Ad Campaign Management
- **Google Ads → flag, do NOT do.** You never design, create, or spawn Google Ads campaigns. When Google Ads work is needed, write a `## Google Ads request` block into your growth report (`.startup/handoffs/NNN-growth-to-business.md`) with: product description, ICP, approved budget cap, brand name, final-URL template (from `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md`), and a stable campaign slug (`<product>-<intent>-<market>`, e.g. `aruannik-commercial-ee`). The team lead reads this and spawns the `ads-strategist` specialist (from the `google-ads-strategist` plugin). The investor can also trigger it directly with `/ads`.
- **Meta Ads / LinkedIn Ads → inline.** You still manage these dashboards via Chrome. Never exceed the approved budget — check it before any ad action.
- **Tracking.** `docs/growth/channels/ads.md` is a lightweight index for Google Ads (one line per campaign: slug, status, link to `docs/ads/<campaign>/`). Keep the `Approved budget:` and `Total spend:` summary lines at the top — the budget hard-stop hook reads them. Meta/LinkedIn ad performance is logged inline in `ads.md` as before.
```

- [ ] **Step 3c: Add the boundary**

Find the `## Boundaries` list (it begins with `You do NOT:`). Add this as the first bullet under `You do NOT:`:

```markdown
- **NEVER design, create, or spawn Google Ads campaigns yourself** — flag the request in your growth report and let the team lead delegate to ads-strategist. The strategist creates PAUSED; the investor enables.
```

- [ ] **Step 3d: Fix the budget-check guideline reference**

Find in `## Guidelines`:

```markdown
- **ALWAYS** check ad budget before any ad action
```

Replace with:

```markdown
- **ALWAYS** check ad budget before any Meta/LinkedIn ad action; for Google Ads, pass the approved budget cap in the `## Google Ads request` block (the strategist forecasts against it)
```

- [ ] **Step 4: Run the suite to verify U12–U15 pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "U1[2345]"`
Expected: U12, U13, U14, U15 all PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/agents/growth-hacker.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): growth-hacker flags Google Ads instead of doing it"
```

---

### Task 4: `ads-strategist` — programmatic `brief.md` creation

**Files:**
- Modify: `plugins/google-ads-strategist/agents/ads-strategist.md` (line ~85)

No saas test harness covers the google-ads plugin, so this task is verified with `grep` (run command, expect output).

- [ ] **Step 1: Verify current refuse-behavior (the "failing" precondition)**

Run: `grep -n "stop and instruct the user to run \`/ads-brief\` first" plugins/google-ads-strategist/agents/ads-strategist.md`
Expected: matches line 85 (the unconditional refuse — what we are relaxing).

- [ ] **Step 2: Edit the refuse rule to allow programmatic brief creation**

Find (line ~85):

```markdown
If `brief.md` does not exist, stop and instruct the user to run `/ads-brief` first.
```

Replace with:

```markdown
If `brief.md` does not exist:
- **If the spawn prompt that invoked you supplies the brief fields** (product, audience, budget, goals, brand, final-URL template — as when `/ads` or the saas-startup-team `/growth` loop delegates to you), create `docs/ads/<campaign>/brief.md` from that context and proceed. Use the `${CLAUDE_PLUGIN_ROOT}/templates/campaign-brief.md` template structure.
- **Otherwise** (interactive use with no context), stop and instruct the user to run `/ads-brief` first.
```

- [ ] **Step 3: Verify the new behavior is present**

Run: `grep -n "create \`docs/ads/<campaign>/brief.md\` from that context" plugins/google-ads-strategist/agents/ads-strategist.md`
Expected: one match (the new programmatic branch).

Run: `grep -c "run \`/ads-brief\` first" plugins/google-ads-strategist/agents/ads-strategist.md`
Expected: `1` (the interactive fallback is retained, not deleted).

- [ ] **Step 4: Commit**

```bash
git add plugins/google-ads-strategist/agents/ads-strategist.md
git commit -m "feat(google-ads-strategist): ads-strategist self-creates brief.md on programmatic invocation"
```

---

### Task 5: README updates (both plugins)

**Files:**
- Modify: `plugins/saas-startup-team/README.md`
- Modify: `plugins/google-ads-strategist/README.md`

- [ ] **Step 1: saas-startup-team README — add `/ads` to the commands table**

Find the row in the Commands table for `/saas-startup-team:goal-deliver` and add this row immediately after it:

```markdown
| `/saas-startup-team:ads` | Design a Google Ads campaign — spawns the `google-ads-strategist` plugin's `ads-strategist` (hard dependency) to design, browser-verify, and create the campaign in PAUSED state for investor review. The `/growth` loop also delegates here automatically. |
```

- [ ] **Step 2: saas-startup-team README — Prerequisites**

In the `## Prerequisites` list, add:

```markdown
- **google-ads-strategist plugin** — required for any Google Ads work (hard dependency). Google Ads is delegated to its `ads-strategist` agent; `growth-hacker` no longer creates Google Ads campaigns itself. There is no manifest-level dependency field, so this is enforced behaviorally: `/ads` and the `/growth` loop fail with an install instruction if the plugin is absent.
```

- [ ] **Step 3: saas-startup-team README — File Structure note**

In the `## File Structure` section, after the `.startup/` tree, add this paragraph:

```markdown
### Google Ads records

Google Ads campaigns live under `docs/ads/<campaign>/` (owned by the `google-ads-strategist` plugin — briefs, iterations, verification screenshots, learnings). `docs/growth/channels/ads.md` is a lightweight index into them (campaign slug, status, link) and retains the `Approved budget:` / `Total spend:` summary lines the budget hard-stop hook reads. Meta/LinkedIn ads are logged inline in `ads.md`.
```

- [ ] **Step 4: Verify saas README edits**

Run: `grep -c "google-ads-strategist" plugins/saas-startup-team/README.md`
Expected: `≥ 3` (table row, prerequisites, file-structure note).

- [ ] **Step 5: google-ads-strategist README — "Relationship to other plugins"**

Find this existing section body:

```markdown
- **saas-startup-team / growth-hacker** is a generalist post-launch executor that already touches Google Ads via Chrome. `ads-strategist` is a specialist designer: it produces campaign specs, growth-hacker (or a human) handles the manual launch in the Ads UI.
- The two plugins compose: use `/ads-brief` + `/ads-iterate` + `/ads-ready` here, then hand the ready spec to growth-hacker for execution.
```

Replace with:

```markdown
- **saas-startup-team** delegates all Google Ads work to this plugin (hard dependency). Its `growth-hacker` no longer creates Google Ads campaigns: it flags a `## Google Ads request` in its growth report, and the `/growth` loop spawns `ads-strategist` at the team-lead level. The investor can also trigger it directly with `/saas-startup-team:ads`. Both spawn `ads-strategist` by its registered agent type.
- `ads-strategist` designs, browser-verifies, and creates the campaign in **PAUSED** state; the investor enables it. saas-startup-team tracks campaigns via a `docs/growth/channels/ads.md` index that links into the `docs/ads/<campaign>/` folders this plugin owns.
- Standalone use is unchanged: `/ads-brief` + `/ads-iterate` + `/ads-ready` + `/ads-create` work without saas-startup-team.
```

- [ ] **Step 6: Verify google-ads README edit**

Run: `grep -c "Google Ads request" plugins/google-ads-strategist/README.md`
Expected: `1`.

Run: `grep -c "hand the ready spec to growth-hacker for execution" plugins/google-ads-strategist/README.md`
Expected: `0` (the stale manual-handoff line is gone).

- [ ] **Step 7: Commit**

```bash
git add plugins/saas-startup-team/README.md plugins/google-ads-strategist/README.md
git commit -m "docs: document growth→ads delegation in both plugin READMEs"
```

---

### Task 6: Version bumps + marketplace sync

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json` (0.37.0 → 0.38.0)
- Modify: `plugins/google-ads-strategist/.claude-plugin/plugin.json` (0.4.1 → 0.5.0)
- Modify: `.claude-plugin/marketplace.json` (both)

Repo rule: bump in BOTH `plugin.json` AND root `marketplace.json`; the `.githooks` pre-push hook validates they stay in sync.

- [ ] **Step 1: Bump `saas-startup-team` plugin.json**

Find `"version": "0.37.0"` in `plugins/saas-startup-team/.claude-plugin/plugin.json` and change to `"version": "0.38.0"`.

- [ ] **Step 2: Bump `google-ads-strategist` plugin.json**

Find `"version": "0.4.1"` in `plugins/google-ads-strategist/.claude-plugin/plugin.json` and change to `"version": "0.5.0"`.

- [ ] **Step 3: Bump both entries in root `marketplace.json`**

In `.claude-plugin/marketplace.json`:
- In the `saas-startup-team` entry, change `"version": "0.37.0"` → `"version": "0.38.0"`.
- In the `google-ads-strategist` entry, change `"version": "0.4.1"` → `"version": "0.5.0"`.

- [ ] **Step 4: Verify versions are in sync**

Run:
```bash
echo "saas plugin.json:   $(jq -r .version plugins/saas-startup-team/.claude-plugin/plugin.json)"
echo "saas marketplace:   $(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' .claude-plugin/marketplace.json)"
echo "ads  plugin.json:   $(jq -r .version plugins/google-ads-strategist/.claude-plugin/plugin.json)"
echo "ads  marketplace:   $(jq -r '.plugins[] | select(.name=="google-ads-strategist") | .version' .claude-plugin/marketplace.json)"
```
Expected: saas pair both `0.38.0`; ads pair both `0.5.0`.

- [ ] **Step 5: Run the full test suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: `All tests passed!` (Suite U passes; E3 semver still valid for `0.38.0`).

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json \
        plugins/google-ads-strategist/.claude-plugin/plugin.json \
        .claude-plugin/marketplace.json
git commit -m "chore: bump saas-startup-team 0.38.0, google-ads-strategist 0.5.0"
```

---

## Final verification

- [ ] **Run the complete suite once more**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: `All tests passed!` with Suite U (U1–U15) green.

- [ ] **Confirm no stray nested-spawn / read-md idiom slipped in**

Run:
```bash
grep -rn 'subagent_type: "general-purpose"' plugins/saas-startup-team/commands/ads.md plugins/saas-startup-team/commands/growth.md | grep -i ads-strategist || echo "OK: no general-purpose spawn of ads-strategist"
```
Expected: `OK: no general-purpose spawn of ads-strategist`.

- [ ] **Confirm the dry-run pre-push hook (if enabled) passes**

Run: `git config core.hooksPath` (expect `.githooks`), then the version-sync check is covered by Task 6 Step 4. If `.githooks/pre-push` exists, run it manually: `bash .githooks/pre-push </dev/null` and expect exit 0.
