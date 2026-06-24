# Tribunal Convergence Governor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap the tribunal review loop and make blocking severity honest, so the 11-round over-engineering spiral (aruannik #951) cannot recur.

**Architecture:** Pure documentation/config engineering across two Claude Code plugins. `tribunal-review` carries the core engine change (blocking-finding standard, same-class merge, reachability injection, new stop condition + step-back in the closing loop). `saas-startup-team` carries the integration (reachability.md convention, tech-founder DoD, goal-deliver alignment). Tests are bash content-presence assertions in each plugin's `tests/run-tests.sh`, matching the existing harness.

**Tech Stack:** Markdown (SKILL.md / agent .md / command .md), JSON (plugin.json, marketplace.json), bash 4+ test harness with `jq`.

## Global Constraints

- Plugins must stay generic and project-agnostic — no hardcoded company/product names or paths (repo CLAUDE.md). `reachability.md` is a per-*consumer-repo* file, never shipped with a plugin.
- Bump the plugin version in BOTH `.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`, kept in sync (repo CLAUDE.md). Targets: `tribunal-review` 0.15.0 → **0.16.0**; `saas-startup-team` 0.49.0 → **0.50.0**.
- Must work with bash 4+ and standard POSIX tools; external deps (jq) already documented.
- Every plugin README keeps its end-user **Installation** section (three scopes) intact.
- Severity is the **arbiter's final call**; reviewers are advisory peers.
- Blocking-finding standard (verbatim, used in multiple tasks): a finding may be **critical/high only if it demonstrates all three** — (1) a production-reachable path (concrete actor + trigger + state transition), (2) material impact (money / data-loss / legal / correctness), (3) caused or exposed by *this* change. Missing any → capped at **medium**.

---

### Task 1: Blocking-finding standard in the arbiter (piece 0)

**Files:**
- Modify: `plugins/tribunal-review/agents/opus-arbiter.md`
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md:1066-1089` (sections 3b–3c) and `:1077` (the HARD RULE)

**Interfaces:**
- Produces: the severity-eligibility rule that Task 4's schema field and Task 5's stop condition rely on. Canonical name for the new arbiter sub-step: **"3b-0 Blocking-finding standard"**.

- [ ] **Step 1: Add the standard as a new sub-step before conflict resolution in the SKILL.** In `skills/tribunal-loop/SKILL.md`, immediately after the `### 3a: Deduplicate Findings` block and before `### 3b: Resolve Conflicts`, insert:

```markdown
### 3b-0: Blocking-finding standard (severity eligibility — apply FIRST)

Before resolving severities, gate each finding's *eligibility* to be rated
critical or high. A finding may be rated **critical or high only if it
demonstrates ALL THREE**:

1. **Production-reachable path** — a concrete actor + trigger + state
   transition. "An interleaving exists", "a malformed file could…", or a
   race that needs two concurrent operations on the same single-user
   resource is NOT sufficient unless the path shows how a real caller
   reaches that state.
2. **Material impact** — money, data-loss, legal/compliance, or
   user-visible correctness.
3. **Caused or exposed by THIS change** — a pre-existing, untouched code
   path that a repo-walking reviewer merely *found* is at most low/follow-up.

The **burden of proof is on the finding**. If any leg is absent or unproven,
cap the finding at **medium** (informational / triage). Use `reachability.md`
(if injected) as supporting context, but a missing/stale reachability.md does
NOT lower the bar — a blocking finding must independently prove reachability.
```

- [ ] **Step 2: Reorder the HARD RULE so the standard wins.** In `skills/tribunal-loop/SKILL.md:1077`, replace the line:

```markdown
**HARD RULE**: When providers report different severities for the same finding, you MUST use the highest severity. No exceptions.
```

with:

```markdown
**HARD RULE (severity)**: First apply **3b-0** to decide whether the finding is *eligible* for critical/high. THEN, among the eligible severities providers reported, use the highest. The highest-severity rule never overrides 3b-0: a finding that fails 3b-0 is medium even if a provider rated it critical.
```

- [ ] **Step 3: Add the standard to the arbiter agent identity.** In `agents/opus-arbiter.md`, under the section that describes how the arbiter evaluates findings (search for the evaluation/authority paragraph), append a new paragraph:

```markdown
## Blocking-finding standard

You may rate a finding **critical or high only if it proves all three**:
(1) a production-reachable path (concrete actor + trigger + state transition),
(2) material impact (money / data-loss / legal / correctness), and
(3) that it is caused or exposed by the change under review. The burden of
proof is on the finding; if any leg is missing, cap it at **medium**. This is
what prevents theoretical-concurrency findings (e.g. races needing two
concurrent operations on a single-user resource) from blocking the gate. You
have final authority on severity and apply this standard before the
highest-severity merge rule.
```

- [ ] **Step 4: Verify the edits are present.** Run:

```bash
grep -q "3b-0: Blocking-finding standard" plugins/tribunal-review/skills/tribunal-loop/SKILL.md && \
grep -q "never overrides 3b-0" plugins/tribunal-review/skills/tribunal-loop/SKILL.md && \
grep -q "Blocking-finding standard" plugins/tribunal-review/agents/opus-arbiter.md && echo OK
```
Expected: `OK`

- [ ] **Step 5: Commit.**

```bash
git add plugins/tribunal-review/agents/opus-arbiter.md plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): blocking-finding standard gates critical/high severity (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 2: Same-class merge every round (piece 5)

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md:1059-1064` (section 3a)

**Interfaces:**
- Consumes: nothing. Produces: the round-level dedup behavior Task 5's loop relies on to prevent restatement spam.

- [ ] **Step 1: Strengthen 3a to merge by class, not just by exact duplicate.** In `skills/tribunal-loop/SKILL.md`, at the end of `### 3a: Deduplicate Findings` (after the existing bullet list), insert:

```markdown
**Same-class merge (every round):** Beyond exact duplicates, collapse
findings that are *variants of the same underlying concern* — e.g. several
different "ordering window" or "unawaited write" findings on the same
mechanism — into ONE finding for the round, keeping the strongest statement
and listing the rest under `arbiter_notes`. N rephrasings of one concern
count as one finding, so a reviewer cannot keep the loop open by restating.
```

- [ ] **Step 2: Verify.** Run:

```bash
grep -q "Same-class merge (every round)" plugins/tribunal-review/skills/tribunal-loop/SKILL.md && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit.**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): same-class merge collapses restated findings each round (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 3: Inject reachability.md into reviewers + arbiter (piece 1)

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` — every reviewer leg's `CONVENTIONS` block (Codex Bash call 1 ~`:288-291`, Gemini ~`:416-419`, OpenCode ~`:563-567`, plus Qwen and Claude legs) and the Step 3 arbiter input.

**Interfaces:**
- Consumes: nothing. Produces: a `REACHABILITY` context block available to reviewers and arbiter. Convention: file path is `reachability.md` at the consumer repo root, capped at 8 KB, absent → no injection.

- [ ] **Step 1: Add a reachability read next to each AGENTS.md read.** For EACH reviewer leg, immediately after its existing `CONVENTIONS=""` / `[ -f AGENTS.md ] && CONVENTIONS=$(head -c 16384 AGENTS.md)` lines, add:

```bash
# Deployment/reachability facts a diff cannot reveal (worker model, concurrency,
# single-user-per-session, money/data-loss paths). Capped; absent => no injection.
REACHABILITY=""
[ -f reachability.md ] && REACHABILITY=$(head -c 8192 reachability.md)
```

- [ ] **Step 2: Append the reachability block to each leg's prompt.** In each leg, alongside the existing `$([ -n "$CONVENTIONS" ] && printf …)` injection, add a sibling injection:

```bash
$([ -n "$REACHABILITY" ] && printf '\n## Production Reachability (from reachability.md)\nUse to judge whether a finding is reachable in production. A critical/high finding must still independently prove a reachable path; this file is supporting context, not a severity override.\n\n%s\n' "$REACHABILITY")
```

- [ ] **Step 3: Tell the arbiter to read it.** In `skills/tribunal-loop/SKILL.md` STEP 3 intro (after line 1057 "Read both JSON outputs…"), add:

```markdown
Also read `reachability.md` from the repo root if present (capped at 8 KB):
it states deployment facts (worker/process model, whether the same
session/resource can be acted on concurrently, single-user assumptions,
money/data-loss paths) used when applying the **3b-0** standard. Treat it as
**rebuttable** — cross-check any claim a finding hinges on against the actual
code/config before relying on it, and lower your confidence in it when its
`last-verified:` marker is old relative to the area under review.
```

- [ ] **Step 4: Verify all legs and the arbiter reference it.** Run:

```bash
test "$(grep -c 'head -c 8192 reachability.md' plugins/tribunal-review/skills/tribunal-loop/SKILL.md)" -ge 5 && \
grep -q "Production Reachability (from reachability.md)" plugins/tribunal-review/skills/tribunal-loop/SKILL.md && \
grep -q "Also read .reachability.md. from the repo root" plugins/tribunal-review/skills/tribunal-loop/SKILL.md && echo OK
```
Expected: `OK` (≥5 legs: codex, gemini, opencode, qwen, claude)

- [ ] **Step 5: Commit.**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): inject reachability.md into reviewers and arbiter (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 4: Require the three-part proof on blocking findings (schema)

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md:1110-1134` (3f verdict JSON shape)

**Interfaces:**
- Consumes: Task 1's standard. Produces: a `blocking_proof` object on critical/high findings, so the standard is structured, not just prose.

- [ ] **Step 1: Add the field to the findings schema in 3f.** In the `findings` array object (around `:1115-1120`), add a field after `arbiter_notes`:

```json
    "suggestion": "...", "confidence": 0.0, "arbiter_notes": "...",
    "blocking_proof": { "reachable_path": "actor+trigger+state transition, or null", "material_impact": "money|data-loss|legal|correctness, or null", "caused_by_change": true }
```

- [ ] **Step 2: Add the enforcement sentence under 3f.** Immediately after the JSON block (after `:1134`), insert:

```markdown
**Required for critical/high:** every finding rated `critical` or `high` MUST
carry a `blocking_proof` whose three legs are all non-null/true (per 3b-0). If
you cannot fill all three, downgrade the finding to `medium` and set
`blocking_proof` legs to null where unproven. `medium`/`low` findings may omit
`blocking_proof`.
```

- [ ] **Step 3: Verify.** Run:

```bash
grep -q '"blocking_proof"' plugins/tribunal-review/skills/tribunal-loop/SKILL.md && \
grep -q "Required for critical/high" plugins/tribunal-review/skills/tribunal-loop/SKILL.md && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit.**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): require blocking_proof on critical/high findings (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 5: Rewrite the closing loop — stop condition, YAGNI, step-back, ceiling (pieces 2/3/4/6)

**Files:**
- Modify: `plugins/tribunal-review/skills/closing-tribunal-loop/SKILL.md` (Stop Condition section ~`:63-81`, the loop diagram intro ~`:10-12`, and add two new sections)

**Interfaces:**
- Consumes: Task 1 (severity standard), Task 2 (same-class merge). Produces: the loop control the tech-founder follows. Canonical round numbers: step-back at **3**, investor checkpoint at **10**, hard ceiling at **20**.

- [ ] **Step 1: Replace the Stop Condition section.** In `skills/closing-tribunal-loop/SKILL.md`, replace the entire `## Stop Condition` section (from the `## Stop Condition` heading through the rationalization table, ~`:63-81`) with:

```markdown
## Stop Condition

The loop **closes** when the Opus arbiter's verdict has **zero `critical` and
zero `high` findings** remaining on the latest diff. Medium/low findings do
NOT hold the gate open — they go to YAGNI triage below.

A `high` finding is **cleared** when it is one of:
- **fixed**, or
- **re-rated below high by the arbiter** (e.g. it failed the 3b-0 blocking
  standard), or
- **descoped** — the contested mechanism is *removed from the diff* AND the
  risk is captured in a filed follow-up issue. A descoped high is no longer
  "remaining" because the risky surface is gone from the change.

### YAGNI triage (leftover medium/low at close)

For each remaining medium/low finding:
- **File a follow-up issue ONLY IF** it is both reachable/real (per the
  arbiter) AND plausibly something the team will act on.
- **Otherwise drop it**, recording one line in the PR body:
  `Tribunal: N low findings dropped (YAGNI) — <one-line reason>`.
  Never silently truncate — every drop is traceable.

### Grind, checkpoint, ceiling

- **Grind:** keep looping while ANY critical/high remains. Critical/high are
  never YAGNI-dropped.
- **Round 10 — investor checkpoint:** notify the investor
  ("still grinding on #<issue>; standing finding: <title>") WITHOUT stopping.
- **Round 20 — hard ceiling:** if critical/high are still unresolved, STOP and
  escalate to the investor with the standing finding.
```

- [ ] **Step 2: Add the step-back workflow section.** Immediately after the section inserted in Step 1, add:

```markdown
## Step-back workflow (anti-spiral)

- **Rounds 1–2:** address findings directly.
- **Round 3 onward, while the gate is open:** enter **step-back mode**. Stop
  adding guards. Diagnose whether the recent findings are the same *class*
  (the signature that the DESIGN, not the bug, is the problem). Then choose
  exactly one:
  - **Simplify / re-architect** so the whole class disappears (e.g. collapse a
    multi-step commit into a single atomic rename).
  - **Descope** — remove the contested mechanism from the diff and file a
    follow-up issue capturing the risk.
  - **Confirm-unreachable** — take the class to the arbiter to down-rate under
    3b-0 / reachability.md.
- Stay in step-back mode each subsequent stalled round; do NOT revert to
  guard-piling.

**Falsifiable output (anti-relabel guard).** A step-back round MUST produce one
of: (a) a collapsed class where the net count of defensive mechanisms
(locks/tokens/digests/markers/sidecars) does NOT increase — added ≤ removed; or
(b) a descope with the mechanism removed from the diff AND a linked follow-up
issue; or (c) an arbiter ruling that the class fails 3b-0. "Added another guard,
relabeled as re-architecture" is INVALID and is caught by the no-net-increase
check.
```

- [ ] **Step 3: Update the loop-intro line to name the new exit.** In the loop overview near `:10-12`, replace the sentence stating the loop closes only on "APPROVE … with zero findings" with:

```markdown
The loop closes when the Opus arbiter returns a verdict with **zero critical
and zero high findings** on the latest diff (medium/low go to YAGNI triage).
Every code change re-opens the diff, so re-run after any fix.
```

- [ ] **Step 4: Verify.** Run:

```bash
F=plugins/tribunal-review/skills/closing-tribunal-loop/SKILL.md
grep -q "zero .critical. and" "$F" && grep -q "YAGNI triage" "$F" && \
grep -q "Step-back workflow (anti-spiral)" "$F" && grep -q "no-net-increase" "$F" && \
grep -q "Round 20 — hard ceiling" "$F" && grep -q "Round 10 — investor checkpoint" "$F" && echo OK
```
Expected: `OK`

- [ ] **Step 5: Commit.**

```bash
git add plugins/tribunal-review/skills/closing-tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): convergence governor — stop on no crit/high, step-back, grind-to-20 (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 6: tribunal-review tests

**Files:**
- Create: `plugins/tribunal-review/tests/run-tests.sh`

**Interfaces:**
- Consumes: the files edited in Tasks 1–5. Produces: a runnable content-presence suite mirroring the saas-startup-team harness style (`assert_*` + PASS/FAIL counts).

- [ ] **Step 1: Write the test runner with presence assertions for each piece.** Create `plugins/tribunal-review/tests/run-tests.sh`:

```bash
#!/bin/bash
# Test runner for tribunal-review plugin (content-presence over the SKILL/agent docs)
# Usage: bash plugins/tribunal-review/tests/run-tests.sh
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; FAILURES=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

assert_grep() {  # label, file, pattern
  local label="$1" file="$2" pat="$3"
  if grep -q "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}
assert_count_ge() {  # label, file, pattern, min
  local label="$1" file="$2" pat="$3" min="$4"
  local n; n=$(grep -c "$pat" "$PLUGIN_ROOT/$file" || true)
  if [ "$n" -ge "$min" ]; then
    echo -e "  ${GREEN}PASS${NC} $label ($n>=$min)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($n<$min)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
AR=agents/opus-arbiter.md

echo "Blocking-finding standard (piece 0):"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-finding standard"
assert_grep "standard overrides highest-severity" "$SK" "never overrides 3b-0"
assert_grep "standard in arbiter agent" "$AR" "Blocking-finding standard"

echo "Same-class merge (piece 5):"
assert_grep "same-class merge" "$SK" "Same-class merge (every round)"

echo "reachability.md injection (piece 1):"
assert_count_ge "injected into >=5 legs" "$SK" "head -c 8192 reachability.md" 5
assert_grep "arbiter reads reachability" "$SK" "Also read .reachability.md. from the repo root"

echo "blocking_proof schema (piece 0 structured):"
assert_grep "schema field" "$SK" '"blocking_proof"'
assert_grep "required for crit/high" "$SK" "Required for critical/high"

echo "Closing loop governor (pieces 2/3/4/6):"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 10 checkpoint" "$CL" "Round 10 — investor checkpoint"
assert_grep "round 20 ceiling" "$CL" "Round 20 — hard ceiling"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
```

- [ ] **Step 2: Run it; expect all green.** Run:

```bash
bash plugins/tribunal-review/tests/run-tests.sh
```
Expected: ends with `PASS=14 FAIL=0`, exit 0.

- [ ] **Step 3: Commit.**

```bash
git add plugins/tribunal-review/tests/run-tests.sh
git commit -m "test(tribunal-review): content-presence suite for convergence governor (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 7: tribunal-review README + version bump

**Files:**
- Modify: `plugins/tribunal-review/README.md`
- Modify: `plugins/tribunal-review/.claude-plugin/plugin.json` (0.15.0 → 0.16.0)
- Modify: `.claude-plugin/marketplace.json` (tribunal-review entry 0.15.0 → 0.16.0)

**Interfaces:** none downstream.

- [ ] **Step 1: Document the governor in the README.** In `plugins/tribunal-review/README.md`, add a section after the existing loop/closing description:

```markdown
## Convergence governor

The closing loop is **capped and severity-honest** so it cannot spiral:

- **Blocking-finding standard** — a finding is critical/high only if it proves
  a production-reachable path, material impact, and that it is caused/exposed
  by the change under review. Otherwise it is capped at medium.
- **Stop condition** — the loop closes on **zero critical/high** (not zero
  findings). Leftover medium/low go to YAGNI triage (filed only if real and
  worth acting on; else dropped with a PR-body note).
- **Step-back at round 3** — stop adding guards; simplify, descope, or
  down-rate the finding *class*. A step-back round may not increase the net
  count of defensive mechanisms.
- **Grind to a ceiling** — keep looping while any critical/high remains;
  investor checkpoint at round 10; hard escalation at round 20.
- **`reachability.md`** — an optional per-repo file (worker model, concurrency,
  single-user assumptions, money paths) injected into reviewers + arbiter as
  rebuttable context.
```

- [ ] **Step 2: Bump both versions.** In `plugins/tribunal-review/.claude-plugin/plugin.json` change `"version": "0.15.0"` to `"version": "0.16.0"`. In `.claude-plugin/marketplace.json` change the tribunal-review entry's `"version": "0.15.0"` to `"version": "0.16.0"`.

- [ ] **Step 3: Verify versions are in sync.** Run:

```bash
a=$(grep '"version"' plugins/tribunal-review/.claude-plugin/plugin.json | grep -o '0\.16\.0')
b=$(sed -n '/tribunal-review/,/}/p' .claude-plugin/marketplace.json | grep -o '0\.16\.0' | head -1)
test "$a" = "0.16.0" && test "$b" = "0.16.0" && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit.**

```bash
git add plugins/tribunal-review/README.md plugins/tribunal-review/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs(tribunal-review): document convergence governor; bump 0.15.0->0.16.0 (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 8: saas-startup-team — reachability.md convention + tech-founder DoD + step-back

**Files:**
- Create: `plugins/saas-startup-team/skills/tech-founder/references/reachability-convention.md` (the convention/template doc — NOT named `reachability.md`, which is the per-consumer-repo file the plugin must never ship)
- Modify: `plugins/saas-startup-team/agents/tech-founder-claude-maintain.md` and `plugins/saas-startup-team/agents/tech-founder-codex-maintain.md` (DoD line + step-back pointer)

**Interfaces:**
- Consumes: tribunal-review's reachability injection (Task 3) and closing loop (Task 5). Produces: the convention consumer repos follow.

- [ ] **Step 1: Write the convention doc (template, not a real repo's facts).** Create `plugins/saas-startup-team/skills/tech-founder/references/reachability-convention.md`:

```markdown
# reachability.md — convention

A per-repo file at the **consumer repo root** (NOT shipped with this plugin)
that states deployment facts a diff cannot reveal, so the tribunal can judge
whether a finding is reachable in production. Injected into reviewers and the
arbiter (capped at 8 KB).

## Required shape

​```
# Reachability
last-verified: 2026-06-24 (commit <sha>)

## Process model
- e.g. "production runs N gunicorn workers" / "single uvicorn worker"

## Concurrency
- e.g. "a session/cid is single-user; the same cid is never finalized
  concurrently" — state what CANNOT happen, so theoretical races are not
  rated high.

## Money / data-loss paths
- list the endpoints/flows that are genuinely money- or data-loss-bearing.
​```

## Upkeep (definition-of-done)

Whenever a change touches the deployment, concurrency, or session model,
update `reachability.md` and refresh `last-verified:` in the same PR — same
discipline as the invariant-map rule. A stale file does not silently suppress
findings (the arbiter cross-checks and the blocking-finding standard still
requires an independently proven reachable path), but keeping it current keeps
reviewer noise down.
```

Note: the triple-backtick fences inside the template above are shown with a
zero-width marker so they nest in this plan; when creating the real file use
ordinary ```` ``` ```` fences.

- [ ] **Step 2: Add the DoD line + step-back pointer to BOTH maintain tech-founder agents.** In each of `tech-founder-claude-maintain.md` and `tech-founder-codex-maintain.md`, add to the definition-of-done / handoff checklist:

```markdown
- **reachability.md** — if this change touches the deployment, concurrency, or
  session model, update `reachability.md` (and its `last-verified:` marker) in
  this PR. See `skills/tech-founder/references/reachability-convention.md`.
- **Tribunal step-back** — from review round 3, stop adding guards: simplify,
  descope (remove the mechanism + file a follow-up), or take the finding class
  to the arbiter. A step-back round must not increase the net count of
  defensive mechanisms. See `tribunal-review:closing-tribunal-loop`.
```

- [ ] **Step 3: Verify.** Run:

```bash
test -f plugins/saas-startup-team/skills/tech-founder/references/reachability-convention.md && \
grep -q "last-verified" plugins/saas-startup-team/skills/tech-founder/references/reachability-convention.md && \
grep -q "Tribunal step-back" plugins/saas-startup-team/agents/tech-founder-claude-maintain.md && \
grep -q "Tribunal step-back" plugins/saas-startup-team/agents/tech-founder-codex-maintain.md && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit.**

```bash
git add plugins/saas-startup-team/skills/tech-founder/references/reachability-convention.md plugins/saas-startup-team/agents/tech-founder-claude-maintain.md plugins/saas-startup-team/agents/tech-founder-codex-maintain.md
git commit -m "feat(saas-startup-team): reachability.md convention + tech-founder step-back DoD (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 9: saas-startup-team — align goal-deliver triage + cap

**Files:**
- Modify: `plugins/saas-startup-team/commands/goal-deliver.md:107-117` (the close-the-tribunal-loop step)

**Interfaces:**
- Consumes: Task 5's loop control. Produces: orchestrator text consistent with the governor.

- [ ] **Step 1: Replace the triage bullets + round-judgment sentence.** In `commands/goal-deliver.md`, in the "Close the tribunal loop" step, replace the triage list and the "Use judgment on the number of rounds…" sentence with:

```markdown
   if the arbiter returns **zero critical and zero high**, the gate is closed
   (leftover medium/low → YAGNI triage: file a follow-up only if real and worth
   acting on, else drop with a PR-body note). While any critical/high remains:
   - **Rounds 1–2:** fix directly (tech founder), push, re-run.
   - **Round 3+:** step-back mode — simplify, descope (remove mechanism + file
     follow-up), or have the arbiter down-rate the class; never guard-pile.
   - **Round 10:** notify the investor (still grinding) without stopping.
   - **Round 20:** stop and escalate to the investor with the standing finding.
   Then **skip the chunks that depend on it** and continue with independent ones.
```

- [ ] **Step 2: Verify.** Run:

```bash
grep -q "zero critical and zero high" plugins/saas-startup-team/commands/goal-deliver.md && \
grep -q "Round 20:" plugins/saas-startup-team/commands/goal-deliver.md && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit.**

```bash
git add plugins/saas-startup-team/commands/goal-deliver.md
git commit -m "feat(saas-startup-team): goal-deliver tribunal triage matches convergence governor (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

### Task 10: saas-startup-team — tests + README + version bump

**Files:**
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (add a governor test group)
- Modify: `plugins/saas-startup-team/README.md`
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json` (0.49.0 → 0.50.0)
- Modify: `.claude-plugin/marketplace.json` (saas-startup-team entry 0.49.0 → 0.50.0)

**Interfaces:** none downstream.

- [ ] **Step 1: Add a test group to the existing harness.** In `plugins/saas-startup-team/tests/run-tests.sh`, before the final summary print, add a new test block using the existing `assert_output_contains` helper (pass file contents as the output arg):

```bash
echo -e "${CYAN}Convergence governor integration${NC}"
assert_output_contains "reachability convention exists" "$(cat "$PLUGIN_ROOT/skills/tech-founder/references/reachability-convention.md" 2>/dev/null)" "last-verified"
assert_output_contains "tech-founder DoD has step-back" "$(cat "$PLUGIN_ROOT/agents/tech-founder-claude-maintain.md")" "Tribunal step-back"
assert_output_contains "goal-deliver caps at 20" "$(cat "$PLUGIN_ROOT/commands/goal-deliver.md")" "Round 20:"
assert_output_contains "goal-deliver stops on no crit/high" "$(cat "$PLUGIN_ROOT/commands/goal-deliver.md")" "zero critical and zero high"
```

- [ ] **Step 2: Run the saas suite; expect green.** Run:

```bash
bash plugins/saas-startup-team/tests/run-tests.sh
```
Expected: existing tests still pass and the 4 new assertions PASS; exit 0.

- [ ] **Step 3: Document in README + bump versions.** In `plugins/saas-startup-team/README.md`, add a one-paragraph note under the tribunal/maintenance section pointing to `tribunal-review`'s convergence governor and the `reachability.md` convention. Then bump `plugins/saas-startup-team/.claude-plugin/plugin.json` `0.49.0` → `0.50.0` and the matching `.claude-plugin/marketplace.json` entry.

- [ ] **Step 4: Verify versions sync + run both suites.** Run:

```bash
grep -q '"version": "0.50.0"' plugins/saas-startup-team/.claude-plugin/plugin.json && \
sed -n '/saas-startup-team/,/}/p' .claude-plugin/marketplace.json | grep -q '0.50.0' && \
bash plugins/saas-startup-team/tests/run-tests.sh >/dev/null && \
bash plugins/tribunal-review/tests/run-tests.sh >/dev/null && echo OK
```
Expected: `OK`

- [ ] **Step 5: Commit.**

```bash
git add plugins/saas-startup-team/tests/run-tests.sh plugins/saas-startup-team/README.md plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "test+docs(saas-startup-team): governor integration tests, README, bump 0.49.0->0.50.0 (#951)

Claude-Session: https://claude.ai/code/session_016zBgBwPwYPufKPTAF2x2Kp"
```

---

## Self-Review

**Spec coverage:**
- Piece 0 (blocking-finding standard) → Tasks 1, 4. ✓
- Piece 1 (reachability.md) → Tasks 3 (injection), 8 (convention/upkeep). ✓
- Piece 2 (stop on no crit/high) → Task 5. ✓
- Piece 3 (YAGNI triage) → Task 5, 9. ✓
- Piece 4 (step-back + falsifiable output) → Tasks 5, 8. ✓
- Piece 5 (same-class merge) → Task 2. ✓
- Piece 6 (grind / round-10 checkpoint / round-20 ceiling) → Tasks 5, 9. ✓
- "Where it lands" table rows → Tasks 1–10 cover every row (arbiter, tribunal-loop, closing-loop, reviewer prompts via reachability injection note, reachability convention, tech-founder, goal-deliver, version bumps). ✓
- Testing section → Tasks 6, 10. The "reconstructed #951-style sequence closes by ≤ round 3" is a behavioral claim not unit-testable in a doc plugin; covered by the presence of the 3b-0 standard + step-back assertions rather than a live arbiter run (noted limitation).

**Placeholder scan:** No "TBD/TODO/handle edge cases" — every step has concrete insert text or an exact command. The one meta-note (nested code fences in Task 8) is an authoring instruction, not a placeholder.

**Type/name consistency:** Canonical anchors used consistently across tasks — `3b-0`, `blocking_proof`, `Step-back workflow (anti-spiral)`, `no-net-increase`, `Round 10 — investor checkpoint`, `Round 20 — hard ceiling`, `last-verified`. Test patterns in Tasks 6/10 match the exact strings inserted in Tasks 1–5/8/9.
