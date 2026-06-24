# Learnings House Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make agent-generated learnings born compressed and high-signal (canonical-term-first, terse why, rationed emphasis, delta-only), route general standards into agent prompts, then compress the existing corpora behind a semantic-preservation gate.

**Architecture:** Lever A edits the *generators* in the `saas-startup-team` plugin — one shared house-style block, the founder prompts as the home for general standards, the `auto-learn.sh` extraction hook, the `/learnings-migrate` command, and maintain-agent prompt references — so future entries follow the house style. Lever B adds a gated `/learnings-compress` command that the agents run against the backlog docs in the dev containers.

**Tech Stack:** Bash 4+, jq, awk. Markdown command/agent/template files. Self-contained bash test runner (`tests/run-tests.sh`).

## Global Constraints

- Plugins must be generic and project-agnostic — no hardcoded company/product names or project paths; use template variables. (CLAUDE.md)
- Bash 4+ and standard POSIX tools only; external deps (jq, awk) already documented. (CLAUDE.md)
- Bump version in BOTH `plugins/saas-startup-team/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json` before pushing — keep in sync. Current version: `0.50.0`. (CLAUDE.md)
- House-style line shape (verbatim): `- <Label>: <imperative rule> — <terse why>. Fix: <reusable pattern>. (ref)` — Label = canonical term / failure-mode handle; why mandatory & terse; Fix conditional; ref optional terse token; `ALWAYS`/`NEVER`/ALL-CAPS rationed to genuine landmines only.
- Size cap default: **30KB** per topic doc triggers a split by `##` section.

## Test-harness facts (verified)

- `tests/run-tests.sh` defines `$PLUGIN_ROOT` (the plugin dir). There is **no** `$REPO_ROOT` and **no** `fail()` helper — derive repo root with `git -C "$PLUGIN_ROOT" rev-parse --show-toplevel`, and express custom comparisons with the existing `assert_equals "<label>" "<actual>" "<expected>"`.
- Available helpers: `assert_file_exists`, `assert_file_contains`, `assert_file_not_contains`, `assert_equals`, `assert_exit_code`, `assert_output_contains`, `assert_json_field`.
- New `test_*` functions MUST be registered in the invocation list inside `main` (around line ~3379, after `test_convergence_governor`).
- `marketplace.json` keys the plugin by `.name == "saas-startup-team"` with a sibling `.version`.

---

### Task 1: Shared house-style block (single source of truth)

**Files:**
- Create: `plugins/saas-startup-team/templates/learnings-style.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new assertions, section "L")

**Interfaces:**
- Produces: a canonical style doc that Tasks 1b, 2b, 3, 4 and 6 reference (path `templates/learnings-style.md`). Other tasks cite it; they do not duplicate its rules.

- [ ] **Step 1: Write the failing test** — append a new test function near the auto-learn tests in `tests/run-tests.sh` and register `test_learnings_style_block` in the `main` invocation list:

```bash
test_learnings_style_block() {
  echo -e "\n${CYAN}== Learnings house-style block ==${NC}"
  local f="$PLUGIN_ROOT/templates/learnings-style.md"
  assert_file_exists "L1: learnings-style.md exists" "$f"
  assert_file_contains "L2: defines the line shape"        "$f" "<Label>: <imperative rule>"
  assert_file_contains "L3: mandates terse why"            "$f" "terse why"
  assert_file_contains "L4: Fix is conditional"            "$f" "only when"
  assert_file_contains "L5: rations emphasis"              "$f" "Ration"
  assert_file_contains "L6: names Critical Landmines"      "$f" "Critical Landmines"
  assert_file_contains "L7: canonical vs overloaded terms" "$f" "overloaded"
  assert_file_contains "L8: novelty/delta gate"            "$f" "delta"
  assert_file_contains "L9: calibration guard"             "$f" "provenance"
  assert_file_contains "L10: three-tier routing"           "$f" "agent prompt"
  assert_file_contains "L11: exact routine line shape"     "$f" "- <Label>: <imperative rule> — <terse why>. Fix: <reusable pattern>. (ref)"
  assert_file_contains "L12: when-unsure-keep rule"        "$f" "When unsure, keep it"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL on L1 and dependents.

- [ ] **Step 3: Create the file** `plugins/saas-startup-team/templates/learnings-style.md`:

```markdown
# Learnings House Style

How every learnings entry is written. One source of truth — referenced by
`scripts/auto-learn.sh`, `commands/learnings-migrate.md`, `commands/learnings-compress.md`,
and the maintain-agent prompts. Do not duplicate these rules elsewhere; link here.

## Why terse-but-reasoned

Terseness alone is not an accuracy lever. Shrink by cutting narrative and using
canonical terms — not by telegraphic grammar. Keep a terse "why": a rule plus its
reason generalizes to unseen cases; a bare rule does not.

## Record the delta, not the corpus (novelty gate)

A line is worth its tokens only if it is **surprising to a competent model** — the
delta between what the model already knows and what is actually true here.
Information = surprise: a rule the model would produce anyway is ~0 bits — do not
record it; it only dilutes the lines that aren't obvious. The more a rule
*contradicts* the model's default, the more it earns its tokens (and the rare emphasis).

**Do NOT record** general/textbook best-practice the model already applies
(e.g. "validate input", "use parameterized queries", "handle errors").

**Where a fact lives (three tiers):** (i) model does it by default → nowhere;
(ii) a general standard or team convention the model won't reliably apply → the
**agent prompt's Standards sections** (once, durable, cross-project), NOT here;
(iii) project/library/version-specific surprising delta → here. If a candidate is
tier-(ii), promote it to the agent prompt instead of recording it as a learning.

**DO record — calibration guard (asymmetric):** models are overconfident about what
they "know," so KEEP anything project-specific, library/version-specific, exact-behavior
(inheritance/typing facts like `httpx.ConnectTimeout does NOT inherit from ConnectError`),
post-cutoff, counterintuitive, or **provenance-tagged** (`#issue`, incident, test) —
even when it pattern-matches something "obvious." That is where confident-but-wrong lives.
When unsure, keep it.

## Routine rule — one line

    - <Label>: <imperative rule> — <terse why>. Fix: <reusable pattern>. (ref)

- **Label** — a canonical term or failure-mode handle before the colon
  (`Idempotency:`, `Token hygiene:`, `Retry semantics:`). It is the model's
  retrieval handle. Prefer canonical terms over prose.
- **Rule** — imperative voice, not hedged ("retry only idempotent methods",
  not "we try to avoid…").
- **Why** — mandatory, terse. Drop only if self-evident.
- **Fix** — include only when there is a concrete reusable action; omit when vague.
- **(ref)** — optional, a single terse token (`#548`, `categorizer.py`). Never a
  provenance sentence.
- ~25 words max excluding ref.

## Emphasis is rationed

`ALWAYS` / `NEVER` / ALL-CAPS now over-trigger and dilute on current models —
they make the genuinely critical rules disappear into noise. Use them ONLY for a
catastrophic landmine, never for routine rules. Most lines need none.

## Canonical vs overloaded terms

Use canonical names for unambiguous concepts (idempotent, TOCTOU, fail-closed,
cache stampede, backoff+jitter, least-privilege, surgical edit). For **overloaded**
terms (atomic, fail-safe, consistent) the model silently picks a sense — spell out
the behavior instead.

## Structure of a topic doc

- A `## Critical Landmines` section near the **top** holds the few catastrophic
  rules; stronger language is allowed only here.
- Remaining rules grouped under failure-mode `##` sections (e.g. Retry Semantics,
  Timeout Handling, Error Wrapping, Token Hygiene, Observability, Tests).
- A topic doc over 30KB is split by `##` section into sibling docs.

## Example

    - Idempotency: retry only idempotent HTTP methods; never POST/PATCH/DELETE
      after 5xx or ReadTimeout — server may have already committed the mutation.
      Fix: gate retries by method + idempotency key. (#548)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS L1–L12.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/templates/learnings-style.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): add learnings house-style block"
```

---

### Task 1b: Founder prompts = home for tier-2 standards (ration + routing)

> Ordered before the auto-learn change (Task 2b) so the Standards home exists before the generator routes standards to it.

**Files:**
- Modify: `plugins/saas-startup-team/agents/tech-founder-claude.md` (the `## Guidelines` block, ~lines 193-216, and a one-line routing note)
- Modify: `plugins/saas-startup-team/agents/business-founder.md` (the `## Guidelines` block, ~lines 204-224, and a one-line routing note)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new assertions, section "S")

**Interfaces:**
- Consumes: house-style block (Task 1) — the same ration rule applies to Standards.
- Produces: founder prompts declared as the canonical home for tier-2 standards; their `## Guidelines` blocks rationed (model-default lines cut, emphasis reserved for real constraints, capability constraints preserved verbatim).

- [ ] **Step 1: Inspect the current Guidelines blocks**

Run: `sed -n '193,216p' plugins/saas-startup-team/agents/tech-founder-claude.md; echo '---'; sed -n '204,224p' plugins/saas-startup-team/agents/business-founder.md`
Expected: see the straight `ALWAYS`/`NEVER` lists. Identify model-default lines (tech-founder e.g. "ALWAYS handle errors with user-friendly messages", "ALWAYS build aesthetic, polished UI", "ALWAYS make architecture decisions based on training knowledge") vs. real constraints to preserve verbatim ("NEVER use WebSearch, WebFetch, or browser tools — you have no web access"; "NEVER implement a handoff with 3+ features — reject it and ask the business founder to split").

- [ ] **Step 2: Write the failing test** — register `test_founder_standards_routing`:

```bash
test_founder_standards_routing() {
  echo -e "\n${CYAN}== founder prompts are tier-2 standards home ==${NC}"
  for a in tech-founder-claude business-founder; do
    assert_file_contains "S1:$a declares standards-vs-learnings routing" \
      "$PLUGIN_ROOT/agents/$a.md" "Standards live here"
    assert_file_contains "S2:$a warns off version-specific promotion" \
      "$PLUGIN_ROOT/agents/$a.md" "docs/learnings/"
  done
  # ration: model-default lines removed
  assert_file_not_contains "S3: drops model-default polished-UI guideline" \
    "$PLUGIN_ROOT/agents/tech-founder-claude.md" "build aesthetic, polished UI"
  # capability constraints MUST survive (regression guard)
  assert_file_contains "S4: tech no-web constraint survives" \
    "$PLUGIN_ROOT/agents/tech-founder-claude.md" "no web access"
  assert_file_contains "S5: handoff-split constraint survives" \
    "$PLUGIN_ROOT/agents/tech-founder-claude.md" "3+ features"
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL S1–S3 (routing line absent; model-default line still present).

- [ ] **Step 4: Edit both founder prompts.**
  1. Add this note at the top of the `## Guidelines` section of each file:
     > _Standards live here — durable, cross-project best-practice and team conventions. Project/library/version-specific or provenance-tagged facts go in `docs/learnings/`, NOT here. Keep this list rationed: only rules the model won't reliably apply by default._
  2. Ration the `## Guidelines` list: **delete** lines that merely restate model defaults (tech-founder: "ALWAYS handle errors with user-friendly messages", "ALWAYS build aesthetic, polished UI — not bare-bones prototypes", "ALWAYS make architecture decisions based on training knowledge"). **Keep** the real constraints, removing ALL-CAPS from any line that is not a catastrophic landmine while preserving the hard capability constraints **verbatim** ("NEVER use WebSearch, WebFetch, or browser tools — you have no web access"; "NEVER implement a handoff with 3+ features — reject it and ask the business founder to split"). Apply the equivalent cut to business-founder's block (delete generic restatements; keep concrete team constraints).

- [ ] **Step 5: Run test to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS S1–S5.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/agents/tech-founder-claude.md plugins/saas-startup-team/agents/business-founder.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): founder prompts hold rationed tier-2 standards"
```

---

### Task 2a: Refactor auto-learn.sh `msg` to a quoted heredoc (no behavior change)

> De-risks the highest-risk edit. A quoted heredoc (`<<'LEARN_MSG'`) takes literal text — no `'"'"'` quote-islands, no interpolation — so Task 2b's text edit cannot break bash quoting. This task changes NO instruction text; existing tests I4–I10 must still pass.

**Files:**
- Modify: `plugins/saas-startup-team/scripts/auto-learn.sh` (the base `msg=` assignment only; leave the cap-enforcement append block unchanged)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (add `bash -n` + JSON-emission checks to the existing auto-learn test function)

**Interfaces:**
- Produces: identical systemMessage output; the base `msg` now assigned via heredoc. No signature change.

- [ ] **Step 1: Add the failing/guard tests** to the existing auto-learn test function:

```bash
  # I11: script parses (catches any quoting breakage)
  ec=0; bash -n "$script" 2>/dev/null || ec=$?
  assert_exit_code "I11: auto-learn.sh parses (bash -n)" "$ec" 0
  # I12: still emits valid JSON with a systemMessage on a matching handoff
  out="$(printf '{"tool_input":{"file_path":"/tmp/x/.startup/handoffs/h.md"}}' | bash "$script" 2>&1 || true)"
  ec=0; printf '%s\n' "$out" | jq -e '.systemMessage | type == "string"' >/dev/null 2>&1 || ec=$?
  assert_exit_code "I12: emits JSON systemMessage" "$ec" 0
```

- [ ] **Step 2: Run tests — they pass now** (the current script already parses and emits JSON). This task is a refactor guarded by these tests; confirm green BEFORE editing:

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS I11, I12 (plus existing I4–I10).

- [ ] **Step 3: Refactor the base `msg` assignment.** Replace the single-quoted `msg='Read the file just written. … do nothing.'` assignment with a quoted heredoc carrying the **exact same text** (note: literal single quotes inside need no escaping under `<<'LEARN_MSG'`):

```bash
msg=$(cat <<'LEARN_MSG'
Read the file just written. Extract up to 3 reusable project learnings (tech stack decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge. Find git root (git rev-parse --show-toplevel). Ensure CLAUDE.md exists with '# Project Learnings' H1 and '## Learnings' H2. List files in docs/learnings/*.md at git root (skip if dir missing); for each, read the first '#'/'##' heading line (fall back to filename stem with dashes→spaces if no heading) to build a topic catalog. For each candidate learning: (a) skip if semantically equivalent to any existing entry in any topic file or in '### Recent (unsorted)'; (b) if it clearly fits one existing topic file, append a dash-bullet to that file; (c) otherwise ensure '### Recent (unsorted)' subsection exists under '## Learnings' with comment '<!-- Uncertain/new-topic learnings staged here. Run /saas-startup-team:learnings-migrate to organise into docs/learnings/*.md. -->' and append the dash-bullet there. One dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries total. If nothing worth recording, do nothing.
LEARN_MSG
)
```

Leave the cap-enforcement `if (( recent_count >= threshold )); then msg="$msg"'…'; fi` block and the final `jq -cn --arg m "$msg" '{systemMessage: $m}' >&2` exactly as they are.

- [ ] **Step 4: Run the suite — behavior unchanged**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS I4–I12 (existing content assertions I5–I10 still match because the text is identical).

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/auto-learn.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "refactor(saas-startup-team): auto-learn msg via heredoc (no behavior change)"
```

---

### Task 2b: Rewrite the auto-learn.sh extraction instruction (house style + delta gate)

**Files:**
- Modify: `plugins/saas-startup-team/scripts/auto-learn.sh` (the heredoc body from Task 2a)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend the auto-learn test function)

**Interfaces:**
- Consumes: the house-style rules (Task 1) inlined into the systemMessage — the hook cannot read a file at fire time, so the shape is inlined; `learnings-style.md` remains the human/agent-facing source of truth.
- Produces: a systemMessage instructing house-style, delta-only entries with the calibration guard and tier-2 promotion. No signature change.

- [ ] **Step 1: Add the failing tests**:

```bash
  # I13: no longer instructs blanket NEVER/ALWAYS for rules
  assert_file_not_contains "I13: drops blanket NEVER/ALWAYS instruction" "$script" "NEVER/ALWAYS for rules"
  # I14: embeds the house-style label shape
  assert_file_contains "I14: house-style label shape" "$script" "<Label>:"
  # I15: keeps the terse why mandate
  assert_file_contains "I15: mandates terse why" "$script" "terse why"
  # I16: rations emphasis
  assert_file_contains "I16: rations emphasis" "$script" "landmine"
  # I17: applies novelty gate + calibration guard
  assert_file_contains "I17: novelty gate" "$script" "surprising to a competent model"
  assert_file_contains "I18: keeps version-specific facts" "$script" "version-specific"
  # I19: routes tier-2 standards out of learnings
  assert_file_contains "I19: promotes general standards" "$script" "general standard"
  # I20: still caps entries at 3
  assert_file_contains "I20: caps at 3 entries" "$script" "Max 3 new entries"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL I13 (string still present) and I14–I19 (new strings absent).

- [ ] **Step 3: Edit the heredoc body.** Replace the trailing sentence `One dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries total. If nothing worth recording, do nothing.` with this text (plain text inside the quoted heredoc — apostrophes and the em dash are fine, no escaping):

```
Record only the DELTA — facts surprising to a competent model. Do NOT record general/textbook best-practice the model already applies; that only dilutes the real rules. If a candidate is a general standard or team convention worth enforcing (not project/library-specific), it does NOT belong here — note it for promotion to the relevant agent prompt Standards section instead of recording it as a learning. Calibration guard: KEEP anything project-specific, library/version-specific, exact-behavior (inheritance/typing facts), post-cutoff, counterintuitive, or tied to a #issue/incident/test — even if it feels obvious; when unsure, keep it. Write each kept entry in house style, one dash per line: - <Label>: <imperative rule> — <terse why>. Fix: <pattern>. Label is a canonical term or failure-mode handle (e.g. Idempotency, Token hygiene, Retry semantics). Keep the terse why; add Fix only when a concrete reusable action exists. Prefer canonical terms; spell out overloaded ones (atomic, fail-safe). Ration emphasis — use ALWAYS/NEVER/caps ONLY for a catastrophic landmine, never routine rules. Append at most a terse (#issue or file) ref, never a provenance sentence. ~25 words max excluding ref. Max 3 new entries total. If nothing worth recording, do nothing.
```

Also change the early `Skip obvious knowledge.` phrase to `Skip obvious knowledge (see the delta rule below).` so the two are consistent.

- [ ] **Step 4: Verify parse + JSON emission carry the new content**

Run:
```bash
bash -n plugins/saas-startup-team/scripts/auto-learn.sh && \
out="$(printf '{"tool_input":{"file_path":"/tmp/x/.startup/handoffs/h.md"}}' | bash plugins/saas-startup-team/scripts/auto-learn.sh 2>&1 || true)"; \
printf '%s\n' "$out" | jq -e '.systemMessage | contains("surprising to a competent model") and contains("version-specific") and contains("Max 3 new entries")' >/dev/null && echo OK
```
Expected: prints `OK`.

- [ ] **Step 5: Run the full suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS I4–I20.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/scripts/auto-learn.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): auto-learn writes delta-only house-style entries"
```

---

### Task 3: Update /learnings-migrate to bootstrap house-style structure

**Files:**
- Modify: `plugins/saas-startup-team/commands/learnings-migrate.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new assertions, section "M")

**Interfaces:**
- Consumes: house-style block (Task 1) — referenced by path, not duplicated.
- Produces: bootstrap behavior that creates topic files with a `## Critical Landmines` section and failure-mode `##` skeleton, appends entries in house-style shape, and carries the calibration guard during clustering.

- [ ] **Step 1: Write the failing test** — register `test_learnings_migrate_house_style`:

```bash
test_learnings_migrate_house_style() {
  echo -e "\n${CYAN}== learnings-migrate house style ==${NC}"
  local f="$PLUGIN_ROOT/commands/learnings-migrate.md"
  assert_file_contains "M1: references the house-style block" "$f" "learnings-style.md"
  assert_file_contains "M2: bootstraps Critical Landmines"    "$f" "Critical Landmines"
  assert_file_contains "M3: routes routine to failure-mode sections" "$f" "failure-mode"
  assert_file_contains "M4: carries calibration guard"        "$f" "when unsure, keep"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL M1–M4.

- [ ] **Step 3: Edit `commands/learnings-migrate.md`.**
  In step 5 ("First-time bootstrap"), after creating each topic file with its `# <display heading>` H1, add:
  > Seed each new topic file with a `## Critical Landmines` section (placeholder comment `<!-- catastrophic rules only; stronger language allowed here -->`) followed by failure-mode `##` sections inferred from the cluster. Append every entry in the house style defined in `templates/learnings-style.md` (`- <Label>: <rule> — <why>. Fix: <pattern>. (ref)`); reserve `ALWAYS`/`NEVER`/caps for `## Critical Landmines` only. During clustering, do not discard a line as obvious if it is project-specific, library/version-specific, exact-behavior, post-cutoff, counterintuitive, or provenance-tagged — when unsure, keep and route it.

  In step 11 ("Apply edits"), change "append the planned entries as dash-bullets" to:
  > append the planned entries as dash-bullets in house style (`templates/learnings-style.md`), routing any catastrophic rule to the target file's `## Critical Landmines` section and routine rules to the best-fit failure-mode `##` section.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS M1–M4.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/learnings-migrate.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): learnings-migrate seeds house-style structure"
```

---

### Task 4: Point maintain-agent prompts at the house-style block

**Files:**
- Modify: `plugins/saas-startup-team/agents/business-founder-maintain.md`
- Modify: `plugins/saas-startup-team/agents/tech-founder-claude-maintain.md`
- Modify: `plugins/saas-startup-team/agents/tech-founder-codex-maintain.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new assertions, section "N")

**Interfaces:**
- Consumes: house-style block (Task 1).
- Produces: each maintain agent references the block where it writes/maintains learnings (no inline duplication of the rules).

- [ ] **Step 1: Inspect the three files**

Run: `grep -niE "learning|docs/learnings|CLAUDE.md" plugins/saas-startup-team/agents/*-maintain.md`
Expected: locate the learnings-writing sentence in each (if a file has none, it gets a one-line addition under its maintenance duties).

- [ ] **Step 2: Write the failing test** — register `test_maintain_agents_reference_style`:

```bash
test_maintain_agents_reference_style() {
  echo -e "\n${CYAN}== maintain agents reference house style ==${NC}"
  for a in business-founder-maintain tech-founder-claude-maintain tech-founder-codex-maintain; do
    assert_file_contains "N:$a references house style" \
      "$PLUGIN_ROOT/agents/$a.md" "learnings-style.md"
  done
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL for all three agents.

- [ ] **Step 4: Edit each of the three files.** Add (or fold into the existing learnings sentence):
  > When recording or revising learnings, follow the house style in `templates/learnings-style.md` — canonical-term label first, terse why, conditional Fix, delta-only (calibration guard: keep version-specific/provenance-tagged facts even if they feel obvious), emphasis reserved for `## Critical Landmines`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS section N.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/agents/*-maintain.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): maintain agents follow learnings house style"
```

---

### Task 5: Golden before/after sample (the semantic-preservation anchor)

**Files:**
- Create: `plugins/saas-startup-team/templates/learnings-compress-golden.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new assertions, section "G")

**Interfaces:**
- Produces: ≥8 worked before→after transformations that `/learnings-compress` (Task 6) must match, plus the reviewer checklist. Task 6 references this file.

- [ ] **Step 1: Write the failing test** — register `test_compress_golden_sample`:

```bash
test_compress_golden_sample() {
  echo -e "\n${CYAN}== compress golden sample ==${NC}"
  local f="$PLUGIN_ROOT/templates/learnings-compress-golden.md"
  assert_file_exists "G1: golden sample exists" "$f"
  assert_file_contains "G2: has before sections"   "$f" "BEFORE"
  assert_file_contains "G3: has after sections"    "$f" "AFTER"
  assert_file_contains "G4: has reviewer checklist" "$f" "Reviewer checklist"
  local count; count="$(grep -c '^## Transformation ' "$f")"
  assert_equals "G5: >=8 transformations" "$([ "$count" -ge 8 ] && echo ok || echo "only-$count")" "ok"
  assert_file_contains "G6: DELETE-obvious transform" "$f" "DELETE: pure ingrained knowledge"
  assert_file_contains "G7: KEEP calibration transform" "$f" "library-version-specific"
  assert_file_contains "G8: overloaded-term transform" "$f" "overloaded"
  assert_file_contains "G9: merge transform" "$f" "MERGED"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL G1.

- [ ] **Step 3: Create `templates/learnings-compress-golden.md`** with ≥8 transformations. The four shown below are mandatory (1, 2 = shape; 3, 4 = the delta-gate calibrators). Add four more in the same shape covering: a TOCTOU/race line, a cache-stampede line, an overloaded-term line that must stay spelled out, and a line that gets MERGED with a duplicate.

```markdown
# /learnings-compress Golden Sample

Approved before→after transformations. A compression pass MUST reproduce these
shapes and MUST NOT drop the marked semantic elements. See `learnings-style.md`.

## Transformation 1 — emphasis stripped, label added
BEFORE:
- ALWAYS catch `httpx.HTTPError` (parent of all RequestError subclasses) as last clause when wrapping httpx calls — narrow handlers leak Bearer tokens via APM serialization
AFTER:
- Token hygiene: catch `httpx.HTTPError` (parent of all RequestError subclasses) as the last clause when wrapping httpx calls — narrow handlers leak Bearer tokens via APM serialization. Fix: broad catch + sanitize before reporting.
PRESERVED: scope (last clause), trigger (wrapping httpx), prohibited outcome (token leak), mechanism (APM serialization).

## Transformation 2 — landmine routed, not deleted
BEFORE:
- NEVER retry non-idempotent HTTP methods (POST/PATCH/DELETE) on 5xx or ReadTimeout — server may have already enacted the request; only ConnectError is safe
AFTER (goes under `## Critical Landmines`):
- Idempotency: never retry POST/PATCH/DELETE on 5xx or ReadTimeout — server may have already committed; only ConnectError (no bytes sent) is retry-safe. Fix: method-aware retry gate.
PRESERVED: exact methods, exact triggers (5xx, ReadTimeout), the ConnectError exception, the reason.

## Transformation 3 — DELETE: pure ingrained knowledge (novelty gate)
BEFORE:
- ALWAYS validate user input before using it in a database query to prevent injection
AFTER:
- (deleted) — general best-practice the model already applies; ~0 bits, no project/library/version specificity, no provenance. Recording it only dilutes the real rules.
RULE: drop textbook best-practice with no delta.

## Transformation 4 — KEEP: looks obvious, is library-version-specific (calibration guard)
BEFORE:
- `httpx.ConnectTimeout` does NOT inherit from `httpx.ConnectError` — both inherit separately from `TransportError`; verify with issubclass() before grouping
AFTER:
- Exception taxonomy: `httpx.ConnectTimeout` does NOT subclass `httpx.ConnectError` — both descend from `TransportError`; group via `issubclass()`, not assumption.
RULE: KEEP — exact library-inheritance fact the model is overconfident about; high surprise, confident-but-wrong risk. Never delete as "obvious."

## Reviewer checklist (per changed line)
- [ ] Scope unchanged (not silently broadened)
- [ ] All exception cases kept
- [ ] Trigger condition kept
- [ ] Prohibited behavior kept
- [ ] Required fix kept (or intentionally dropped as vague)
- [ ] Overloaded terms still spelled out
- [ ] If DROPPED as obvious: line has NO project/library/version specificity, NO provenance tag, NO counterintuitive claim (else keep)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS G1–G9.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/templates/learnings-compress-golden.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): golden sample for learnings compression"
```

---

### Task 6: /learnings-compress command (gated backlog pass)

**Files:**
- Create: `plugins/saas-startup-team/commands/learnings-compress.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new assertions, section "C")

**Interfaces:**
- Consumes: `learnings-style.md` (Task 1), `learnings-compress-golden.md` (Task 5).
- Produces: a user-invocable command that compresses one topic doc per run, emits a changelog, gates the risky classes, and splits docs over 30KB.

- [ ] **Step 1: Write the failing test** — register `test_learnings_compress_command`:

```bash
test_learnings_compress_command() {
  echo -e "\n${CYAN}== learnings-compress command ==${NC}"
  local f="$PLUGIN_ROOT/commands/learnings-compress.md"
  assert_file_exists "C1: command exists" "$f"
  assert_file_contains "C2: user_invocable"        "$f" "user_invocable: true"
  assert_file_contains "C3: references golden"      "$f" "learnings-compress-golden.md"
  assert_file_contains "C4: emits a changelog"      "$f" "changelog"
  assert_file_contains "C5: gates critical rules"   "$f" "Critical Landmines"
  assert_file_contains "C6: 30KB split rule"        "$f" "30"
  assert_file_contains "C7: one doc per run"        "$f" "one topic"
  assert_file_contains "C8: promotes tier-2 standards" "$f" "PROMOTE"
  assert_file_contains "C9: gates obvious drops"    "$f" "DROP-as-obvious"
  assert_file_contains "C10: calibration guard"     "$f" "calibration guard"
  assert_file_contains "C11: requires approval"     "$f" "approve critical"
  assert_file_contains "C12: exact-duplicate drop"  "$f" "exact duplicate"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: FAIL C1.

- [ ] **Step 3: Create `commands/learnings-compress.md`**:

```markdown
---
name: learnings-compress
description: Compress one docs/learnings/<topic>.md into the house style behind a semantic-preservation gate — strips over-emphasis, adds canonical labels, routes landmines, promotes general standards, splits docs over 30KB. Non-destructive preview + changelog before any write.
user_invocable: true
---

# /learnings-compress — gated backlog compression

Compresses ONE topic doc per run. Never trust an autonomous rewrite: every run
produces a changelog and a hard gate on risky changes. Style source:
`templates/learnings-style.md`. Worked transforms + reviewer checklist:
`templates/learnings-compress-golden.md`.

## Actions

1. Resolve git root (`git rev-parse --show-toplevel`). Argument is one topic path
   under `docs/learnings/`; if absent, list candidates by size (largest first) and
   ask which **one** to compress. Process **one topic** per run.
2. Read `templates/learnings-style.md` and `templates/learnings-compress-golden.md`.
   Match the golden transformations exactly in shape, and apply the golden file's
   "If DROPPED as obvious" checklist before any DROP.
3. For each dash-bullet, produce a candidate compressed line: strip rationed emphasis,
   add a canonical-term Label, keep the terse why, keep Fix only if concrete, reduce
   ref to a terse token. Keep overloaded terms spelled out.
4. Classify each change as:
   - **REWRITE** — same rule, tighter.
   - **MERGE** — fold into a named duplicate line (changelog must name the target).
   - **RELABEL** — add/fix the Label only.
   - **DROP** — allowed ONLY when the line is an exact duplicate elsewhere, OR pure
     general best-practice with NO project/library/version specificity, NO exact-behavior
     claim, NO counterintuitive claim, NO post-cutoff fact, and NO provenance tag (issue,
     incident, test, filename, observed failure). Calibration guard: ambiguous
     obviousness defaults to KEEP.
   - **PROMOTE** — a general standard / team convention worth enforcing but not
     project/library-specific → move to the relevant agent prompt's Standards section,
     remove from learnings.
   Route any catastrophic rule to a `## Critical Landmines` section at the top.
5. Emit a **changelog** grouped by class, applying the golden reviewer checklist to each
   REWRITE/MERGE. Show before→after for every changed line.
6. **Gate — require explicit `approve critical`** before any change that (a) touches a
   `## Critical Landmines` rule (DROP/MERGE/severity downgrade), (b) is a **DROP-as-obvious**
   (the calibration guard makes this the highest-risk class — gated even outside Critical
   Landmines), or (c) is a PROMOTE (edits a different file). Routine REWRITE/RELABEL and
   non-critical MERGE proceed on the changelog alone, and only when the changelog names the
   duplicate target and the checklist shows no semantic loss.
7. **Size cap:** if the compressed doc still exceeds **30KB**, propose a split by `##`
   section into sibling `docs/learnings/<topic>-<section>.md` files and update the
   `## Domain Learnings` index. Confirm before writing.
8. Print the preview (changelog + resulting byte size + any split plan). Ask
   `apply / skip: <line numbers> / cancel`. On `apply`, write the doc (and any splits)
   and update the index. Never drop a learning except an exact duplicate or a gated
   pure no-delta best-practice.

## Guarantees

- One topic per run; smallest-impact, reviewable diffs.
- Changelog before any write; nothing changes on `cancel` or session death.
- Critical-rule changes, DROP-as-obvious, and promotions are human-gated.
- Never silently loses a learning; ambiguous obviousness defaults to KEEP. DROP only an
  exact duplicate or a gated pure no-delta best-practice; PROMOTE relocates a standard into
  an agent prompt; everything else is rewritten, merged, relabeled, or split.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: PASS C1–C12.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/learnings-compress.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): add gated /learnings-compress command"
```

---

### Task 7: Version bump + version-sync test + full-suite gate

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json` (root)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new `test_version_sync`)

**Interfaces:**
- Produces: synced version bump (required before push) + an automated guard against future drift.

- [ ] **Step 1: Write the failing test** — register `test_version_sync`:

```bash
test_version_sync() {
  echo -e "\n${CYAN}== plugin/marketplace version sync ==${NC}"
  local repo_root pv mv
  repo_root="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"
  pv="$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  mv="$(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' "$repo_root/.claude-plugin/marketplace.json")"
  assert_equals "version sync: plugin == marketplace" "$pv" "$mv"
}
```

- [ ] **Step 2: Bump version** in both files from `0.50.0` to `0.51.0` (minor — new command + behavior). They MUST match.

- [ ] **Step 3: Run the full test suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: all sections PASS (existing + L1–L12, S1–S5, I4–I20, M1–M4, N, G1–G9, C1–C12, version sync). Note final `PASS/FAIL` counts.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/saas-startup-team/tests/run-tests.sh
git commit -m "chore(saas-startup-team): bump to 0.51.0 + version-sync test — learnings house style"
```

---

### Task 8 (operational, run in dev containers — not plugin code): first real compression pass

**Files:** none in this repo. Runs against `est-biz-aruannik` and `varustame.ee` working copies.

- [ ] **Step 1:** In the aruannik container, with the updated plugin installed, run `/learnings-compress` on the **smallest** topic doc (e.g. `profit-distribution.md`, ~2.5KB) **through preview/changelog only and `cancel`** — verify NO files changed (`git status` clean) and the changelog reads sensibly.
- [ ] **Step 2:** Re-run on the same doc and `apply`. Inspect against the golden checklist; confirm zero semantic loss on spot-checked rules.
- [ ] **Step 3:** Proceed to a mid-size doc (`http-client-hardening.md`) to exercise PROMOTE and the 30KB-split path; review before applying.
- [ ] **Step 4:** Defer the giant docs (`accounting-engine.md`, `frontend-i18n.md`) until the split path is reviewed on a mid-size doc.
- [ ] **Step 5:** Repeat on varustame's largest (`backend-dotnet.md`).

Human review gates each doc; this task is intentionally NOT automated end-to-end.

---

## Self-Review

**Spec coverage:**
- House-style line shape → Task 1 (block) + Task 2b (auto-learn) + Task 3 (migrate) ✓
- Two shapes (routine vs landmark) → Task 1 structure + Task 3 bootstrap + Task 6 routing ✓
- Retrieval-oriented `##` taxonomy → Task 1 + Task 3 ✓
- Emphasis rationed / de-emphasis → Task 1, Task 1b (founder Guidelines), Task 2b (drops "NEVER/ALWAYS for rules"), Task 3, golden Transformation 1 ✓
- Terse "why" kept → Task 1, Task 2b, golden PRESERVED lines ✓
- Canonical vs overloaded terms → Task 1, Task 5 (overloaded transform) ✓
- Record-the-delta / novelty gate + calibration guard → Task 1, Task 2b (I17/I18), Task 3 (M4 clustering guard), Task 5 (Transformations 3 & 4), Task 6 (DROP criteria, gate) ✓
- Three-tier routing + promotion → Task 1 (L10), Task 1b (founder Standards home + S2 warn-off), Task 2b (I19), Task 6 (PROMOTE, C8) ✓
- Founder Standards rationed; capability constraints preserved → Task 1b (S3 cut, S4/S5 survival) ✓
- Lever A generators (block, founders, auto-learn, migrate, maintain agents) → Tasks 1, 1b, 2a, 2b, 3, 4 ✓
- Lever B gated compress + semantic-preservation harness → Tasks 5, 6, 8 ✓
- Size cap 30KB split → Task 6 step 7 ✓
- Version sync (bump + automated test) → Task 7 ✓
- Bash-quoting risk de-risked → Task 2a (heredoc refactor, `bash -n`, JSON test) before Task 2b text edit ✓

**Placeholder scan:** No TBD/TODO. Task 5 asks the implementer to add four more transformations "in the same shape" — acceptable: two complete worked examples, the exact structure, and the four target topics are given, and G5 enforces the ≥8 count, so the remaining four are bounded mechanical repetitions.

**Type/name consistency:** File paths consistent (`templates/learnings-style.md`, `templates/learnings-compress-golden.md`, `commands/learnings-compress.md`). Test sections unique (L, S, I-series, M, N, G, C, version sync). auto-learn I-series renumbered without collision: existing I4–I10, refactor guards I11–I12, content checks I13–I20. Version `0.50.0` → `0.51.0` consistent in Task 7. `assert_equals`/derived-repo-root used (no `fail()`/`$REPO_ROOT`, which do not exist).
```
