# `/improve` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/improve` command for one-shot post-completion improvements that routes through business founder (brief) → tech founder (implementation) → business founder (browser QA).

**Architecture:** A single command file (`commands/improve.md`) orchestrates three sequential agent dispatches. The auto-commit hook is extended to trigger on improvement implementation files. Bootstrap and docs are updated for the new directory and command.

**Tech Stack:** Markdown (command definition), Bash (auto-commit hook, tests)

**Spec:** `docs/superpowers/specs/2026-03-31-improve-command-design.md`

---

### Task 1: Extend auto-commit hook to handle improvement files

**Files:**
- Modify: `scripts/auto-commit.sh:45-57` (add improvement pattern after handoff pattern)
- Test: `tests/run-tests.sh` (add Suite P: Improve auto-commit)

- [ ] **Step 1: Write the failing test**

Add Suite P at the end of the test file, before the `main()` function. This tests that `.startup/improvements/NNN-implementation.md` files trigger auto-commit.

```bash
# ---------------------------------------------------------------------------
# Suite P: Improve Auto-Commit Hook
# ---------------------------------------------------------------------------

test_improve_auto_commit_hook() {
  echo -e "\n${CYAN}Suite P: Improve Auto-Commit Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/auto-commit.sh"

  # P1: auto-commit.sh has .startup/improvements/ path filter
  assert_file_contains "P1: has .startup/improvements/ path filter" "$script" "\.startup/improvements/"

  # P2: Exits 0 for non-implementation improvement file (brief)
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/improvements/001-brief.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "P2: exits 0 for improvement brief (not a commit trigger)" "$ec" 0

  # P3: Functional test — improvement implementation write creates a commit
  local workdir
  workdir=$(mktemp -d)
  git init -q "$workdir"
  (cd "$workdir" && git config user.email "test@test.com" && git config user.name "Test" && git commit --allow-empty -m "init" -q)
  mkdir -p "$workdir/.startup/improvements"
  mkdir -p "$workdir/backend"
  echo "updated code" > "$workdir/backend/app.py"
  echo "implementation summary" > "$workdir/.startup/improvements/001-implementation.md"

  ec=0; output=""
  output=$(cd "$workdir" && echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/improvements/001-implementation.md"}}' | bash "$script" 2>&1) || ec=$?

  local commit_count
  commit_count=$(cd "$workdir" && git log --oneline 2>/dev/null | wc -l)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$commit_count" -ge 2 ]; then
    echo -e "  ${GREEN}PASS${NC} P3: functional test — improvement implementation creates commit ($commit_count commits)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} P3: functional test — expected >=2 commits, got $commit_count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("P3: expected >=2 commits, got $commit_count")
  fi

  # P3b: Commit message contains "improve:"
  local last_msg
  last_msg=$(cd "$workdir" && git log -1 --format=%s 2>/dev/null)
  assert_output_contains "P3b: improvement commit message format" "$last_msg" "improve:"
  rm -rf "$workdir"

  # P4: Exits 0 for QA file (not a commit trigger)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/improvements/001-qa.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "P4: exits 0 for improvement QA file (not a commit trigger)" "$ec" 0
}
```

- [ ] **Step 2: Register Suite P in main()**

Add `test_improve_auto_commit_hook` call to the `main()` function, after `test_duplicate_handoff_hook`.

```bash
  test_duplicate_handoff_hook
  test_improve_auto_commit_hook
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'P[0-9]|Suite P|FAIL'`
Expected: P1 FAIL (no path filter), P3 FAIL (no commit), P3b FAIL (no message)

- [ ] **Step 4: Add improvement pattern to auto-commit.sh**

In `scripts/auto-commit.sh`, add a new `elif` block after the handoff pattern (line 57, after the `esac`/`fi` block) and before the `else` on line 58:

```bash
elif echo "$rel_path" | grep -qE '^\.startup/improvements/[0-9]{3}-implementation\.md$'; then
  imp_num=$(echo "$filename" | grep -oE '^[0-9]{3}')
  commit_msg="improve: implementation ${imp_num}"
```

Note: Only `NNN-implementation.md` triggers commit — briefs and QA files do not, since the code changes happen during implementation.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'P[0-9]|Suite P|Summary|Pass|Fail'`
Expected: All P tests PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/auto-commit.sh tests/run-tests.sh
git commit -m "feat: extend auto-commit hook for /improve implementation files"
```

---

### Task 2: Update bootstrap to include improvements directory

**Files:**
- Modify: `commands/bootstrap.md:26-38` (add improvements to directory structure and mkdir)
- Modify: `commands/bootstrap.md:52-64` (add gitignore entry)

- [ ] **Step 1: Add improvements/ to the ephemeral directory listing**

In `commands/bootstrap.md`, add `improvements/` to the ephemeral loop state structure (after `go-live/`):

```
.startup/
├── handoffs/
├── reviews/
├── signoffs/
├── go-live/
└── improvements/
```

- [ ] **Step 2: Add improvements/ to the mkdir command**

Change the mkdir line from:

```bash
mkdir -p .startup/{handoffs,reviews,signoffs,go-live}
```

to:

```bash
mkdir -p .startup/{handoffs,reviews,signoffs,go-live,improvements}
```

- [ ] **Step 3: Add .startup/improvements/ to gitignore entries**

Add this line to the gitignore block in Step 3 of bootstrap.md, after `.startup/go-live/`:

```gitignore
.startup/improvements/
```

- [ ] **Step 4: Add /improve to Workflow Guidance**

In the `## Workflow Guidance` section of bootstrap.md (Step 5), add after the `/growth` block:

```markdown
### Use `/improve` (one-shot fixes) when:
- Product is complete (solution signoff exists) but needs minor tweaks
- Bug fixes, styling changes, copy updates on a shipped product
- Changes that don't need market research or new feature design
```

- [ ] **Step 5: Commit**

```bash
git add commands/bootstrap.md
git commit -m "feat: add improvements/ to bootstrap directory structure"
```

---

### Task 3: Create the improve command

**Files:**
- Create: `commands/improve.md`

- [ ] **Step 1: Write the command file**

Create `commands/improve.md` with the full command definition:

```markdown
---
name: improve
description: One-shot improvements on a completed product — routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
---

# /improve — One-Shot Product Improvements

You are the **Team Lead** (orchestrator) executing a single improvement cycle. The investor described changes they want. You dispatch business founder → tech founder → business founder QA. No loop, no signoff — just fix and done.

## Pre-Flight

1. Verify `.startup/` exists — if not:
   > Run `/startup` first to build the product.

2. Verify solution signoff exists:
   ```bash
   ls .startup/go-live/solution-signoff.md 2>/dev/null
   ```
   If not found:
   > The build loop hasn't completed yet. Use `/startup` to resume or `/nudge` to redirect. `/improve` is for post-completion tweaks.

3. Verify architecture doc exists:
   ```bash
   ls docs/architecture/architecture.md 2>/dev/null
   ```
   If not found:
   > No architecture doc found. The tech founder needs `docs/architecture/architecture.md` to know the stack and service URLs.

4. Create improvements directory:
   ```bash
   mkdir -p .startup/improvements
   ```

5. Determine next improvement number:
   ```bash
   next_num=$(printf "%03d" $(( $(ls .startup/improvements/*-brief.md 2>/dev/null | wc -l) + 1 )))
   ```

## Capture Instructions

If the user provided arguments with the command, use them as the improvement description.

Otherwise ask:
> What would you like improved? Describe the changes.

## Scope Guard

Before dispatching, assess the request. If it contains 3+ distinct features or requires significant new functionality (new pages, new integrations, new data models):

> This looks like a feature, not an improvement. Consider running `/startup` to resume the build loop for this scope. Want to proceed with `/improve` anyway?

This is advisory — proceed if the investor confirms.

## Step 1: Dispatch Business Founder (Brief)

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

Spawn business founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **Improvement task: Write a brief for the tech founder.**
>
> The investor wants these changes: [investor's instructions]
>
> Read `docs/architecture/architecture.md` for current stack and service URLs.
> Read `docs/business/brief.md` for product context.
> Read relevant `docs/research/` files if the improvement touches areas you researched.
>
> Write a brief to `.startup/improvements/${next_num}-brief.md` that includes:
> - What to change (specific, actionable)
> - Why (context the tech founder needs)
> - Acceptance criteria (what "done" looks like)
> - Any related concerns (responsive behavior, i18n, accessibility)
>
> Do NOT use the full handoff template — keep it concise. This is a targeted improvement, not a feature.
>
> After writing, message the team lead: "Improvement brief ${next_num} ready for tech founder."

## Step 2: Dispatch Tech Founder (Implementation)

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

Spawn tech founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder.md` for your identity and tools.
>
> **Improvement task: Implement changes from brief.**
>
> Read `.startup/improvements/${next_num}-brief.md` for what to change.
> Read `docs/architecture/architecture.md` for stack and service URLs.
>
> Start the dev server using the command in `docs/architecture/architecture.md` — it is not running from a previous session.
>
> Implement the changes. Write a summary of what you changed to `.startup/improvements/${next_num}-implementation.md`:
> - Files modified
> - What was changed and why
> - How to verify (localhost URL, specific page/action)
>
> Set 10s timeouts on all HTTP calls.
>
> After completing, message the team lead: "Implementation ${next_num} complete."

## Step 3: Dispatch Business Founder (QA)

Read `.startup/improvements/${next_num}-implementation.md` to extract the localhost URL and verification instructions.

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

Spawn business founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **QA task: Verify improvement implementation.**
>
> Read `.startup/improvements/${next_num}-brief.md` for what was requested.
> Read `.startup/improvements/${next_num}-implementation.md` for what was changed.
>
> Open browser to `{localhost URL from implementation summary}` and verify:
> - Does the change meet the acceptance criteria from the brief?
> - Any visual regressions on the affected pages?
> - Does it work on mobile viewport (375px)?
>
> Write your QA result to `.startup/improvements/${next_num}-qa.md`:
> - PASS or FAIL
> - What you verified
> - Screenshots or observations
> - If FAIL: specific issues found
>
> After writing, message the team lead: "QA ${next_num} complete."

## Step 4: Handle QA Result

Read `.startup/improvements/${next_num}-qa.md`.

**If PASS:** Report to investor. Done — free to exit or run another `/improve`.

**If FAIL (first attempt):**

Increment: `fix_num=$(printf "%03d" $(( ${next_num#0} + 1 )))`

Kill stale agents, then dispatch tech founder with QA findings:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder.md` for your identity and tools.
>
> **Fix task: Address QA findings.**
>
> Read `.startup/improvements/${next_num}-qa.md` for what failed.
> Read `.startup/improvements/${next_num}-brief.md` for original requirements.
> Read `.startup/improvements/${next_num}-implementation.md` for what was done.
>
> Fix the issues. Write updated summary to `.startup/improvements/${fix_num}-implementation.md`.
>
> After completing, message the team lead: "Fix ${fix_num} complete."

Then dispatch business founder for re-QA with the same pattern as Step 3, using `${fix_num}`.

**If FAIL (second attempt):** Report both QA results to investor. Let them decide: try again, adjust instructions, or accept as-is.

## Communication

Same language rules as the build loop:
- Business founder speaks **Estonian** to investor
- Tech founder speaks **English** to investor
- Team lead speaks **English** for status updates
```

- [ ] **Step 2: Verify command frontmatter is valid**

Check the file was created correctly:

Run: `head -5 commands/improve.md`
Expected: YAML frontmatter with name, description, user_invocable

- [ ] **Step 3: Commit**

```bash
git add commands/improve.md
git commit -m "feat: add /improve command for post-completion one-shot improvements"
```

---

### Task 4: Update README

**Files:**
- Modify: `README.md:31-38` (add `/improve` to command table)

- [ ] **Step 1: Add /improve to the command table**

In `README.md`, add a row to the Commands table after the `/ux-test` row:

```markdown
| `/saas-startup-team:improve` | One-shot improvements on a completed product |
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add /improve to README command table"
```

---

### Task 5: Bump versions

**Files:**
- Modify: `.claude-plugin/plugin.json:2` (version)
- Modify: `../../.claude-plugin/marketplace.json:66` (version)

- [ ] **Step 1: Bump plugin.json version**

In `.claude-plugin/plugin.json`, change:

```json
"version": "0.14.0",
```

to:

```json
"version": "0.15.0",
```

- [ ] **Step 2: Bump marketplace.json version**

In `../../.claude-plugin/marketplace.json`, find the saas-startup-team entry and change:

```json
"version": "0.14.0",
```

to:

```json
"version": "0.15.0",
```

- [ ] **Step 3: Update marketplace description**

In `../../.claude-plugin/marketplace.json`, update the saas-startup-team description to mention the improve command:

```json
"description": "SaaS startup simulation — business founder, tech founder, and growth hacker iterate via file-based handoffs using Agent Teams, with on-demand consultants (lawyer for compliance, UX tester for usability and accessibility), building the product, acquiring customers, and iterating with one-shot improvements",
```

- [ ] **Step 4: Run tests to verify nothing broke**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | tail -5`
Expected: All tests pass (including new Suite P)

- [ ] **Step 5: Verify both versions match**

Run: `jq -r '.version' plugins/saas-startup-team/.claude-plugin/plugin.json && jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' .claude-plugin/marketplace.json`
Expected: Both output `0.15.0`

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump saas-startup-team to 0.15.0 — add /improve command"
```
