# Tribunal Silent-Failure / Payment-Path Lens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "silent failures & payment-path traps" dimension to every `tribunal-review` reviewer prompt so the panel actively hunts swallowed exceptions, unawaited promises, non-idempotent/unsigned webhooks, and float-money bugs.

**Architecture:** Append one list item (the canonical fragment) to the existing hunt-list in each of the 9 reviewer prompt sites — 5 in the operative `skills/tribunal-loop/SKILL.md`, 4 in the standalone `agents/*.md` docs. No schema, category, severity, or arbiter changes. The fragment is conditional ("when the diff touches…") and self-limiting ("do NOT invent…") to avoid attention dilution.

**Tech Stack:** Markdown + embedded bash (heredocs / double-quoted `-p` prompts). Verification via `grep`.

## Global Constraints

- Plugin: `tribunal-review`, version bump `0.13.0 → 0.14.0` in BOTH `.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json` (must stay in sync).
- Fragment is **shell-safe**: contains NO `` ` ``, `$`, `$(…)`, or `\` (it sits inside unquoted heredocs and double-quoted strings where these would be interpreted). The word `await` is written plain.
- Fragment is **appended** as the LAST list item (never reordered ahead of existing dimensions).
- Maps onto the existing category enum (`logic`/`edge-case`) — do NOT add a new category.
- Work on a feature branch (currently on `main`); commit per task.

### Canonical fragment — two style variants

**ANALYZE variant** (plain `N. Title - examples`; used by Gemini, opencode/DeepSeek+GLM, Qwen, Claude, and the gemini/qwen/claude agent docs). Text after the number:

```
Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

**WHAT-TO-REPORT variant** (bold-em-dash; used by the Codex leg and codex-reviewer.md). Text after the number:

```
**Silent failures & payment-path traps** — when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions / broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, and money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

The shared searchable **anchor** in both variants is the literal string: `Silent failures & payment-path traps`.

---

## Task 0: Create feature branch

**Files:** none (git only)

- [ ] **Step 1: Branch off main**

```bash
cd /mnt/data/ai/claude-plugins
git checkout -b feat/tribunal-silent-failure-lens
```

- [ ] **Step 2: Confirm clean tree on new branch**

Run: `git status`
Expected: `On branch feat/tribunal-silent-failure-lens`, working tree clean (the spec/plan docs may show as untracked — that is fine).

---

## Task 1: Add the fragment to the 5 SKILL.md prompt builders

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (Codex ~L336, Gemini ~L415, opencode `review_opencode_leg` ~L634, Qwen ~L789, Claude ~L930)

**Interfaces:**
- Produces: 5 occurrences of the anchor `Silent failures & payment-path traps` in SKILL.md.

- [ ] **Step 1: Write the failing gate**

Run:
```bash
cd /mnt/data/ai/claude-plugins
grep -c "Silent failures & payment-path traps" plugins/tribunal-review/skills/tribunal-loop/SKILL.md || true
```
Expected (before edits): `0` — the gate fails (we want 5). Note `grep -c` exits 1 on zero matches; the `|| true` keeps an automated executor from stopping here.

- [ ] **Step 2: Codex leg — append item 5 after the Performance line**

Edit `SKILL.md`. old_string (unique):
```
4. **Performance** — N+1 queries, unnecessary allocations, blocking async calls
```
new_string:
```
4. **Performance** — N+1 queries, unnecessary allocations, blocking async calls
5. **Silent failures & payment-path traps** — when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions / broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, and money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 3: Gemini leg — append item 6 after the unique "5. Test coverage gaps" line**

Edit `SKILL.md`. old_string (unique — only the Gemini list numbers this line "5."):
```
5. Test coverage gaps - missing edge cases, untested paths
```
new_string:
```
5. Test coverage gaps - missing edge cases, untested paths
6. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 4: opencode + Qwen + Claude legs — append item 7 to all three identical "6. Test coverage gaps" lines at once**

Edit `SKILL.md` with **replace_all: true**. old_string (appears exactly 3×):
```
6. Test coverage gaps - missing edge cases, untested paths
```
new_string:
```
6. Test coverage gaps - missing edge cases, untested paths
7. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 5: Run the gate — verify exactly 5 occurrences**

Run: `grep -c "Silent failures & payment-path traps" plugins/tribunal-review/skills/tribunal-loop/SKILL.md`
Expected: `5`

- [ ] **Step 6: Confirm no shell-metacharacter breakage**

Run: `grep -n "Silent failures & payment-path traps" plugins/tribunal-review/skills/tribunal-loop/SKILL.md`
Expected: 5 lines printed; each line contains the plain word `await` with NO backtick, `$`, or backslash anywhere in the inserted sentence. Visually confirm the inserted line sits as the last numbered item before the blank line / next `## …` heading in its block.

- [ ] **Step 7: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): add silent-failure/payment-path lens to SKILL prompts (#57)"
```

---

## Task 2: Sync the fragment into the 4 agent docs

**Files:**
- Modify: `plugins/tribunal-review/agents/codex-reviewer.md` (~L107)
- Modify: `plugins/tribunal-review/agents/gemini-reviewer.md` (~L49)
- Modify: `plugins/tribunal-review/agents/qwen-reviewer.md` (~L101)
- Modify: `plugins/tribunal-review/agents/claude-reviewer.md` (~L93)

**Interfaces:**
- Consumes: the two style variants from Global Constraints.
- Produces: 1 anchor occurrence per file (4 total). `deepseek-reviewer.md` is intentionally untouched (no embedded prompt).

- [ ] **Step 1: codex-reviewer.md — append item 5 (WHAT-TO-REPORT variant)**

Edit `agents/codex-reviewer.md`. old_string:
```
4. **Performance** — N+1 queries, unnecessary allocations, blocking async calls
```
new_string:
```
4. **Performance** — N+1 queries, unnecessary allocations, blocking async calls
5. **Silent failures & payment-path traps** — when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions / broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, and money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 2: gemini-reviewer.md — append item 6 (ANALYZE variant)**

Edit `agents/gemini-reviewer.md`. old_string:
```
5. Test coverage gaps - missing edge cases, untested paths
```
new_string:
```
5. Test coverage gaps - missing edge cases, untested paths
6. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 3: qwen-reviewer.md — append item 7 (ANALYZE variant)**

Edit `agents/qwen-reviewer.md`. old_string:
```
6. Test coverage gaps - missing edge cases, untested paths
```
new_string:
```
6. Test coverage gaps - missing edge cases, untested paths
7. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 4: claude-reviewer.md — append item 7 (ANALYZE variant)**

Edit `agents/claude-reviewer.md`. old_string:
```
6. Test coverage gaps - missing edge cases, untested paths
```
new_string:
```
6. Test coverage gaps - missing edge cases, untested paths
7. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.
```

- [ ] **Step 5: Gate — exactly 1 anchor per edited file, 0 in deepseek-reviewer.md**

Run:
```bash
cd /mnt/data/ai/claude-plugins/plugins/tribunal-review/agents
grep -c "Silent failures & payment-path traps" codex-reviewer.md gemini-reviewer.md qwen-reviewer.md claude-reviewer.md deepseek-reviewer.md
```
Expected:
```
codex-reviewer.md:1
gemini-reviewer.md:1
qwen-reviewer.md:1
claude-reviewer.md:1
deepseek-reviewer.md:0
```

- [ ] **Step 6: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/agents/codex-reviewer.md plugins/tribunal-review/agents/gemini-reviewer.md plugins/tribunal-review/agents/qwen-reviewer.md plugins/tribunal-review/agents/claude-reviewer.md
git commit -m "feat(tribunal-review): sync silent-failure lens into agent docs (#57)"
```

---

## Task 3: Version bump + changelog

**Files:**
- Modify: `plugins/tribunal-review/.claude-plugin/plugin.json` (`"version"`)
- Modify: `.claude-plugin/marketplace.json` (tribunal-review entry `"version"`)
- Modify: `plugins/tribunal-review/README.md` (changelog section, if present)

**Interfaces:**
- Consumes: nothing.
- Produces: version `0.14.0` in both manifests (in sync).

- [ ] **Step 1: Confirm current versions are 0.13.0**

Run (robust JSON extraction via jq, with a grep fallback):
```bash
cd /mnt/data/ai/claude-plugins
jq -r '.version' plugins/tribunal-review/.claude-plugin/plugin.json
jq -r '.plugins[] | select(.name=="tribunal-review") | .version' .claude-plugin/marketplace.json
```
Expected: both print `0.13.0`. (If jq is unavailable or the marketplace schema differs — e.g. plugins keyed differently — open `.claude-plugin/marketplace.json`, find the tribunal-review object, and read its `version` field directly.)

- [ ] **Step 2: Bump plugin.json to 0.14.0**

Edit `plugins/tribunal-review/.claude-plugin/plugin.json`: change `"version": "0.13.0"` → `"version": "0.14.0"`.

- [ ] **Step 3: Bump marketplace.json to 0.14.0**

Edit `.claude-plugin/marketplace.json`: change the tribunal-review entry's `"version": "0.13.0"` → `"version": "0.14.0"`.

- [ ] **Step 4: Add a changelog line if README has a changelog**

Run: `grep -ni "changelog\|## 0\.\|### 0\." plugins/tribunal-review/README.md | head`
- If a changelog section exists, add: `- **0.14.0** — Added a silent-failure / payment-path review dimension to all reviewer prompts (swallowed exceptions, unawaited promises, webhook idempotency/signature, float-money). (#57)`
- If no changelog section exists, skip this step (do not invent one).

- [ ] **Step 5: Verify both manifests are 0.14.0 and in sync**

Run:
```bash
jq -r '.version' plugins/tribunal-review/.claude-plugin/plugin.json
jq -r '.plugins[] | select(.name=="tribunal-review") | .version' .claude-plugin/marketplace.json
```
Expected: both report `0.14.0` (identical → in sync).

- [ ] **Step 6: Commit**

```bash
git add plugins/tribunal-review/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/tribunal-review/README.md
git commit -m "chore(tribunal-review): bump to 0.14.0 (#57)"
```

---

## Task 4: Final whole-plugin verification gate

**Files:** none (verification only)

- [ ] **Step 1: Assert exactly 9 anchor occurrences across the plugin**

Run:
```bash
cd /mnt/data/ai/claude-plugins
grep -rc "Silent failures & payment-path traps" plugins/tribunal-review | grep -v ':0$'
echo "TOTAL: $(grep -rho "Silent failures & payment-path traps" plugins/tribunal-review | wc -l)"
```
Expected: 5 in `SKILL.md`, 1 each in the 4 agent docs; `TOTAL: 9`.

- [ ] **Step 2: Re-run the pre-push version hook check locally (if configured)**

Run: `git config core.hooksPath` then, if it returns `.githooks`, run `bash .githooks/pre-push 2>&1 | tail -20` (or simply attempt the push later — the hook enforces plugin/marketplace version sync).
Expected: no version-mismatch error for tribunal-review.

- [ ] **Step 3 (optional, on-demand): live-LLM A/B acceptance**

This is a non-deterministic judgement check, not a gate. On a branch with a seeded diff (swallowed exception + non-idempotent webhook), run the tribunal and confirm ≥2 default legs surface both and the arbiter marks them CONSENSUS. Separately confirm a neutral, payment-free diff produces no invented payment findings. Only run if you want behavioral evidence; otherwise note it as deferred.

---

## Self-Review (completed by plan author)

- **Spec coverage:** All 9 sites from the spec map to Tasks 1–2; version/sync to Task 3; deterministic grep gate to Tasks 1, 2, 4; live-LLM A/B to Task 4 Step 3. Anti-dilution wording baked into the canonical fragment (conditional trigger + "do NOT invent"). ✓
- **Placeholder scan:** No TBD/TODO; every edit shows exact old/new strings and the fragment verbatim. ✓
- **Count consistency:** 5 (SKILL) + 4 (agents) = 9, matching the corrected spec and the Task 4 gate. `deepseek-reviewer.md` explicitly excluded. ✓
