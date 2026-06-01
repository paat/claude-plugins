# Configurable Gemini Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tribunal-loop Gemini leg configurable via two environment variables — disable it entirely or swap its model — without editing the skill, defaulting to current behavior.

**Architecture:** Thin env-var layer read inline in the skill's bash blocks with default fallbacks. `TRIBUNAL_GEMINI=off` short-circuits the Gemini leg to a `disabled` marker that the existing degrade-to-quorum machinery treats as an intentional skip (not a failure). `TRIBUNAL_GEMINI_MODEL` substitutes into `gemini --model`. No settings file, no parsing layer.

**Tech Stack:** Markdown skill/agent files, inline bash, `jq`, `gemini` CLI. No test framework — verification is `bash -n` syntax checks on edited blocks plus grep assertions.

---

## File Structure

All files under `plugins/tribunal-review/`:

- `skills/tribunal-loop/SKILL.md` — Step 1 preflight, Step 2 Gemini call, Step 3 arbiter. The live path. (3 edit sites)
- `agents/gemini-reviewer.md` — standalone/doc Gemini script. Model override only (no disable guard).
- `README.md` — new Configuration section.
- `.claude-plugin/plugin.json` — version bump.
- `../../.claude-plugin/marketplace.json` (repo root) — matching version bump.

There is no test directory; this plugin ships markdown + inline bash. "Tests" below are real, runnable shell checks (`bash -n`, `grep`, JSON validation).

---

## Task 1: Step 1 preflight — skip Gemini probe when disabled

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (preflight bash block, ~lines 38–79)

- [ ] **Step 1: Edit the CLI-probe setup**

Replace this exact block:

```bash
WARN=""
USABLE=0

# Each reviewer CLI on PATH?
for cli in codex gemini opencode; do
  if command -v "$cli" >/dev/null 2>&1; then
    USABLE=$((USABLE + 1))
  else
    WARN="${WARN}\n  - ${cli}: NOT on PATH — that provider will be skipped"
  fi
done
```

with:

```bash
WARN=""
USABLE=0

# Gemini leg can be disabled via env (TRIBUNAL_GEMINI=off). When disabled it is an
# INTENTIONAL skip — not probed on PATH and not counted toward the zero-usable check.
# Only the literal "off" disables; anything else (or unset) = on.
CLIS="codex gemini opencode"
if [ "${TRIBUNAL_GEMINI:-on}" = "off" ]; then
  CLIS="codex opencode"
  WARN="${WARN}\n  - gemini: disabled via TRIBUNAL_GEMINI=off — leg will be skipped"
fi
TOTAL=$(set -- $CLIS; echo $#)

# Each reviewer CLI on PATH?
for cli in $CLIS; do
  if command -v "$cli" >/dev/null 2>&1; then
    USABLE=$((USABLE + 1))
  else
    WARN="${WARN}\n  - ${cli}: NOT on PATH — that provider will be skipped"
  fi
done
```

- [ ] **Step 2: Make the final OK line use the dynamic total**

Replace this exact line:

```bash
echo "PREFLIGHT OK: ${USABLE}/3 reviewer CLIs available."
```

with:

```bash
echo "PREFLIGHT OK: ${USABLE}/${TOTAL} reviewer CLIs available."
```

- [ ] **Step 3: Update the Step 1 output-guidance prose**

Replace this exact line:

```
Output: "[TRIBUNAL 1/3] On branch: {branch_name}, {N} files changed — {USABLE}/3 providers ready{, warnings if any}"
```

with:

```
Output: "[TRIBUNAL 1/3] On branch: {branch_name}, {N} files changed — {USABLE}/{TOTAL} providers ready{, warnings if any}" (TOTAL is 2 when Gemini is disabled via TRIBUNAL_GEMINI=off, else 3)
```

- [ ] **Step 4: Verify the edited preflight block parses**

Extract the fenced bash block and syntax-check it. Run:

```bash
cd /mnt/data/ai/claude-plugins
awk '/^WARN=""$/{f=1} f{print} /^echo "PREFLIGHT OK/{exit}' \
  plugins/tribunal-review/skills/tribunal-loop/SKILL.md > /tmp/pf.sh
bash -n /tmp/pf.sh && echo "SYNTAX OK"
```

Expected: `SYNTAX OK` (no parse errors).

- [ ] **Step 5: Verify the disable branch logic in isolation**

Run:

```bash
TRIBUNAL_GEMINI=off bash -c 'CLIS="codex gemini opencode"; [ "${TRIBUNAL_GEMINI:-on}" = "off" ] && CLIS="codex opencode"; TOTAL=$(set -- $CLIS; echo $#); echo "CLIS=[$CLIS] TOTAL=$TOTAL"'
bash -c 'CLIS="codex gemini opencode"; [ "${TRIBUNAL_GEMINI:-on}" = "off" ] && CLIS="codex opencode"; TOTAL=$(set -- $CLIS; echo $#); echo "CLIS=[$CLIS] TOTAL=$TOTAL"'
```

Expected, in order:
```
CLIS=[codex opencode] TOTAL=2
CLIS=[codex gemini opencode] TOTAL=3
```

- [ ] **Step 6: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): preflight honors TRIBUNAL_GEMINI=off"
```

---

## Task 2: Step 2 Gemini call — disable guard + model override

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (Bash call 2 block, ~lines 222–301)

- [ ] **Step 1: Insert the config guard at the top of Bash call 2**

Replace this exact block:

```bash
cd "$(git rev-parse --show-toplevel)"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)
```

with:

```bash
cd "$(git rev-parse --show-toplevel)"

# Config: the Gemini leg can be disabled (TRIBUNAL_GEMINI=off) or pointed at a
# different model (TRIBUNAL_GEMINI_MODEL). Only the literal "off" disables; anything
# else (or unset) runs as normal. Defaults reproduce the original behavior exactly.
if [ "${TRIBUNAL_GEMINI:-on}" = "off" ]; then
  printf '%s\n' '{"provider": "gemini", "status": "disabled", "note": "Gemini leg disabled via TRIBUNAL_GEMINI=off"}'
  exit 0
fi
GEMINI_MODEL="${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)
```

- [ ] **Step 2: Substitute the model variable into the gemini invocation**

Replace this exact line:

```bash
printf '%s\n' "$DIFF" | timeout -k 10 600 gemini --model gemini-3-pro-preview -p "You are a senior code reviewer performing a thorough security-focused review.
```

with:

```bash
printf '%s\n' "$DIFF" | timeout -k 10 600 gemini --model "$GEMINI_MODEL" -p "You are a senior code reviewer performing a thorough security-focused review.
```

> Note: leave the prompt's inner JSON template field `\"model\": \"default\"` unchanged — Gemini reports its own model name there; the schema does not change.

- [ ] **Step 3: Verify the disabled marker is valid JSON with the right shape**

Run:

```bash
printf '%s\n' '{"provider": "gemini", "status": "disabled", "note": "Gemini leg disabled via TRIBUNAL_GEMINI=off"}' \
  | jq -e '.provider == "gemini" and .status == "disabled"' >/dev/null && echo "MARKER OK"
```

Expected: `MARKER OK`.

- [ ] **Step 4: Verify the model var defaults correctly**

Run:

```bash
bash -c 'echo "${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"'
TRIBUNAL_GEMINI_MODEL=gemini-3-flash bash -c 'echo "${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"'
```

Expected, in order:
```
gemini-3-pro-preview
gemini-3-flash
```

- [ ] **Step 5: Verify the disable guard short-circuits before any git call**

Run:

```bash
TRIBUNAL_GEMINI=off bash -c 'if [ "${TRIBUNAL_GEMINI:-on}" = "off" ]; then printf "%s\n" "{\"provider\": \"gemini\", \"status\": \"disabled\"}"; exit 0; fi; echo SHOULD_NOT_PRINT' \
  | jq -e '.status == "disabled"' >/dev/null && echo "GUARD OK"
```

Expected: `GUARD OK` (the `SHOULD_NOT_PRINT` branch is never reached).

- [ ] **Step 6: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): Gemini leg disable guard + TRIBUNAL_GEMINI_MODEL"
```

---

## Task 3: Step 3 arbiter — treat `disabled` as intentional skip

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (Step 3e and the provider_assessment JSON, ~lines 543–572)

- [ ] **Step 1: Add the `disabled` rule to 3e (Degraded Input)**

Replace this exact block:

```
### 3e: Degraded Input

- If a subset of providers returned invalid JSON or failed: proceed with the remaining providers' findings. Note each failure in `provider_assessment`.
- If **all four providers failed**: verdict = NEEDS_WORK, confidence = 0.0, rationale = "All review providers failed. Manual review required."
- If **all providers returned zero findings**: verdict = APPROVE, confidence = 0.95.
```

with:

```
### 3e: Degraded Input

- If a subset of providers returned invalid JSON or failed: proceed with the remaining providers' findings. Note each failure in `provider_assessment`.
- If Gemini returned `{"status": "disabled"}` (operator set `TRIBUNAL_GEMINI=off`): this is an INTENTIONAL skip, NOT a failure. Exclude Gemini from quorum entirely, set `provider_assessment.gemini.status` to `"disabled"`, and do not count it toward the "all providers failed" branch — the verdict is computed from the remaining (non-disabled) providers.
- If **all non-disabled providers failed**: verdict = NEEDS_WORK, confidence = 0.0, rationale = "All review providers failed. Manual review required."
- If **all providers returned zero findings**: verdict = APPROVE, confidence = 0.95.
```

- [ ] **Step 2: Add `disabled` to the gemini status enum in the verdict JSON**

Replace this exact line:

```
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" },
```

with:

```
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
```

- [ ] **Step 3: Verify both edits landed**

Run:

```bash
cd /mnt/data/ai/claude-plugins
grep -c 'status": "disabled"' plugins/tribunal-review/skills/tribunal-loop/SKILL.md
grep -c 'ok|failed|partial|disabled' plugins/tribunal-review/skills/tribunal-loop/SKILL.md
```

Expected: first command prints `2` (the Step 2 marker from Task 2 + the new 3e mention); second prints `1`.

- [ ] **Step 4: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): arbiter treats disabled Gemini as intentional skip"
```

---

## Task 4: Standalone agent — model override only

**Files:**
- Modify: `plugins/tribunal-review/agents/gemini-reviewer.md` (bash block + the note at top)

- [ ] **Step 1: Add a model-override line and substitute it into the invocation**

Replace this exact block:

```bash
cd "$(git rev-parse --show-toplevel)"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)
```

with:

```bash
cd "$(git rev-parse --show-toplevel)"

# Model is overridable via TRIBUNAL_GEMINI_MODEL (defaults to gemini-3-pro-preview).
# Note: this standalone path has no enable/disable switch — disabling is a
# tribunal-loop concern; invoking this agent always means a Gemini review is wanted.
GEMINI_MODEL="${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)
```

- [ ] **Step 2: Substitute the model variable into the gemini invocation**

Replace this exact line:

```bash
printf '%s\n' "$DIFF" | timeout -k 10 600 gemini --model gemini-3-pro-preview -p "You are a senior code reviewer performing a thorough security-focused review.
```

with:

```bash
printf '%s\n' "$DIFF" | timeout -k 10 600 gemini --model "$GEMINI_MODEL" -p "You are a senior code reviewer performing a thorough security-focused review.
```

- [ ] **Step 3: Verify no hardcoded model remains in either file**

Run:

```bash
cd /mnt/data/ai/claude-plugins
grep -rn 'gemini --model gemini-3-pro-preview' plugins/tribunal-review/ || echo "NONE REMAIN"
grep -rn 'gemini --model "\$GEMINI_MODEL"' plugins/tribunal-review/ | wc -l
```

Expected: first prints `NONE REMAIN`; second prints `2` (SKILL.md + agent).

- [ ] **Step 4: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/agents/gemini-reviewer.md
git commit -m "feat(tribunal-review): standalone gemini agent honors TRIBUNAL_GEMINI_MODEL"
```

---

## Task 5: README — Configuration section

**Files:**
- Modify: `plugins/tribunal-review/README.md` (insert after the Usage section, before `## How It Works` at line 34)

- [ ] **Step 1: Insert the Configuration section**

Insert this block immediately before the line `## How It Works`:

```markdown
## Configuration

The Gemini reviewer is configurable via two environment variables (export them in your
shell before launching `claude`). Both default to the current behavior, so leaving them
unset changes nothing.

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_GEMINI` | `on` | Set to `off` to skip the Gemini leg entirely. The run degrades to a 3-provider quorum (Codex + GLM + DeepSeek); the arbiter reports Gemini as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_GEMINI_MODEL` | `gemini-3-pro-preview` | Model passed to `gemini --model`. Point it at a faster/cheaper slot to keep a full 4-provider quorum while controlling latency/cost. |

```bash
export TRIBUNAL_GEMINI=off                  # skip Gemini this session
export TRIBUNAL_GEMINI_MODEL=gemini-3-flash # or swap the model instead
```

These knobs apply to the `tribunal-loop` workflow. (The standalone `gemini-reviewer`
agent honors `TRIBUNAL_GEMINI_MODEL` but has no disable switch — invoking it always
means a Gemini review is wanted.)

```

> Note: the inner fenced ```` ```bash ```` block above is part of the README content being inserted. Preserve it verbatim.

- [ ] **Step 2: Verify the section landed and the markdown table is intact**

Run:

```bash
cd /mnt/data/ai/claude-plugins
grep -n '## Configuration' plugins/tribunal-review/README.md
grep -c 'TRIBUNAL_GEMINI' plugins/tribunal-review/README.md
```

Expected: first prints the `## Configuration` line number (a single match, above `## How It Works`); second prints `4` (two table rows + two export examples).

- [ ] **Step 3: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/README.md
git commit -m "docs(tribunal-review): document TRIBUNAL_GEMINI / TRIBUNAL_GEMINI_MODEL"
```

---

## Task 6: Version bump (plugin.json + marketplace.json in sync)

**Files:**
- Modify: `plugins/tribunal-review/.claude-plugin/plugin.json` (`version`)
- Modify: `.claude-plugin/marketplace.json` (tribunal-review entry `version`)

- [ ] **Step 1: Inspect both current versions**

Run:

```bash
cd /mnt/data/ai/claude-plugins
grep -n '"version"' plugins/tribunal-review/.claude-plugin/plugin.json
grep -n -A8 '"name": "tribunal-review"' .claude-plugin/marketplace.json | grep version
```

Expected: both show `0.5.0`. The tribunal-review entry in `marketplace.json` has its own `version` field (confirmed at line 34).

- [ ] **Step 2: Bump plugin.json to 0.6.0**

Replace `"version": "0.5.0",` with `"version": "0.6.0",` in `plugins/tribunal-review/.claude-plugin/plugin.json`.

- [ ] **Step 3: Bump the matching marketplace.json entry to 0.6.0**

In `.claude-plugin/marketplace.json`, within the `tribunal-review` entry, change its `version` from `0.5.0` to `0.6.0`. (Match only the tribunal-review entry — do not touch other plugins' versions.)

- [ ] **Step 4: Verify both are 0.6.0 and in sync**

Run:

```bash
cd /mnt/data/ai/claude-plugins
P=$(jq -r .version plugins/tribunal-review/.claude-plugin/plugin.json)
M=$(jq -r '.plugins[] | select(.name=="tribunal-review") | .version' .claude-plugin/marketplace.json)
echo "plugin=$P marketplace=$M"; [ "$P" = "0.6.0" ] && [ "$M" = "0.6.0" ] && echo "IN SYNC"
```

Expected: `plugin=0.6.0 marketplace=0.6.0` then `IN SYNC`.

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/claude-plugins
git add plugins/tribunal-review/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(tribunal-review): v0.6.0 — configurable Gemini review"
```

---

## Final verification

- [ ] **Step 1: Whole-file bash syntax check of the SKILL's Gemini call**

Extract Bash call 2 and syntax-check the head (config guard + diff setup). Run:

```bash
cd /mnt/data/ai/claude-plugins
awk '/^### Bash call 2: Gemini Review$/{c=1} c&&/^```bash$/{f=1;next} f&&/^```$/{exit} f{print}' \
  plugins/tribunal-review/skills/tribunal-loop/SKILL.md > /tmp/gemini-call.sh
bash -n /tmp/gemini-call.sh && echo "GEMINI CALL SYNTAX OK"
```

Expected: `GEMINI CALL SYNTAX OK`.

- [ ] **Step 2: Confirm default-path behavior is unchanged**

With no env vars set, the guard is skipped and `GEMINI_MODEL` resolves to `gemini-3-pro-preview`. Run:

```bash
bash -c '[ "${TRIBUNAL_GEMINI:-on}" = "off" ] && echo DISABLED || echo "ENABLED model=${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"'
```

Expected: `ENABLED model=gemini-3-pro-preview`.

- [ ] **Step 3: Confirm clean git state**

```bash
cd /mnt/data/ai/claude-plugins
git status --short
```

Expected: empty (all changes committed).
