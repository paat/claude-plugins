# Handoff Naming Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce the canonical `NNN-<direction>.md` handoff filename convention in `saas-startup-team` via a PreToolUse Write hook, and clean up existing non-conforming files in the reference project (aruannik) via a one-time migration script.

**Architecture:** Two independent bash scripts added to the plugin — no changes to existing scripts or command flows. `enforce-handoff-naming.sh` runs as a PreToolUse hook on Write events and blocks non-conforming filenames with a helpful error message. `migrate-handoff-names.sh` is a standalone manual tool that dry-runs by default and moves misrouted content (signoffs, reviews, binaries) to their proper `.startup/` subdirectories while renaming residual topic-slug handoffs to the canonical `NNN-<direction>.md` form.

**Tech Stack:** bash 4+, `jq`, `awk`, `sed`, `grep`, POSIX tools. No new dependencies.

**Spec:** `plugins/saas-startup-team/docs/superpowers/specs/2026-04-24-handoff-naming-enforcement-design.md`

---

## Task 1: Version bump

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

Prerequisite per repo CLAUDE.md: both files must stay in sync before push.

- [ ] **Step 1: Bump `plugin.json`**

Edit `plugins/saas-startup-team/.claude-plugin/plugin.json`, change `"version": "0.32.0"` to `"version": "0.33.0"`.

- [ ] **Step 2: Bump `marketplace.json`**

Edit the `saas-startup-team` entry's `"version": "0.32.0"` to `"version": "0.33.0"` in root `.claude-plugin/marketplace.json`.

- [ ] **Step 3: Verify sync**

Run: `grep -A1 '"saas-startup-team"' .claude-plugin/marketplace.json | grep version && jq -r .version plugins/saas-startup-team/.claude-plugin/plugin.json`
Expected: both output `0.33.0`.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(saas-startup-team): bump to 0.33.0 for handoff naming enforcement (#21)"
```

---

## Task 2: Enforcement hook script

**Files:**
- Create: `plugins/saas-startup-team/scripts/enforce-handoff-naming.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new `test_enforce_handoff_naming_hook` function)

- [ ] **Step 1: Write the test function**

Append this to `plugins/saas-startup-team/tests/run-tests.sh` just before the closing `}` of `test_index_handoff_hook` (end of Suite Q), or add as a new "Suite R" block after it. Insert **before** the `main()` function (which is around line 1879):

```bash
# ---------------------------------------------------------------------------
# Suite R: Enforce Handoff Naming Hook (enforce-handoff-naming.sh)
# ---------------------------------------------------------------------------

test_enforce_handoff_naming_hook() {
  echo -e "\n${CYAN}Suite R: enforce-handoff-naming.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/enforce-handoff-naming.sh"
  local workdir ec output

  # R1: script exists and is executable
  assert_file_exists "R1: enforce-handoff-naming.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} R1b: script is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} R1b: script is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("R1b: script is not executable")
  fi

  # R2: path outside .startup/handoffs/ passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R2: outside handoffs exits 0" "$ec" 0

  # R3: INDEX.md passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/INDEX.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R3: INDEX.md exits 0" "$ec" 0

  # R4: canonical business-to-tech passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/001-business-to-tech.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R4: canonical business-to-tech exits 0" "$ec" 0

  # R5: canonical tech-to-business passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/042-tech-to-business.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R5: canonical tech-to-business exits 0" "$ec" 0

  # R6: canonical business-to-growth passes
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/007-business-to-growth.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R6: canonical business-to-growth exits 0" "$ec" 0

  # R7: slug-only filename is blocked
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/business-to-tech-foo.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R7: slug-only filename exits 2" "$ec" 2
  assert_output_contains "R7b: block message mentions NNN" "$output" "NNN"
  assert_output_contains "R7c: block message mentions next NNN 001" "$output" "001"
  rm -rf "$workdir"

  # R8: timestamp-prefixed filename is blocked
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/2026-04-16T074318Z-business-to-tech-improve-189.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R8: timestamp-prefix exits 2" "$ec" 2

  # R9: non-.md (binary) is blocked
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/sample.pdf"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R9: .pdf exits 2" "$ec" 2
  assert_output_contains "R9b: block message mentions attachments/" "$output" "attachments"

  # R10: non-canonical direction NNN-business-to-team is blocked
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/handoffs/476-business-to-team.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R10: non-canonical direction exits 2" "$ec" 2

  # R11: next-NNN computation reflects actual max
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/012-business-to-tech.md"
  touch "$workdir/.startup/handoffs/007-tech-to-business.md"
  ec=0
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/.startup/handoffs/bogus.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R11: block with existing files exits 2" "$ec" 2
  assert_output_contains "R11b: next NNN is 013" "$output" "013"
  rm -rf "$workdir"

  # R12: empty file_path in stdin passes (defensive)
  ec=0
  output=$(echo '{}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R12: empty input exits 0" "$ec" 0

  # R13: signoffs/ path is not blocked (not a handoff path)
  ec=0
  output=$(echo '{"tool_input":{"file_path":"/workspace/.startup/signoffs/roundtrip-001.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "R13: signoffs/ path exits 0" "$ec" 0
}
```

Also add the dispatch line to `main()` (after `test_index_handoff_hook`):

```bash
  test_enforce_handoff_naming_hook
```

- [ ] **Step 2: Run tests, expect the suite to fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: `Suite R` fails on R1 (script missing).

- [ ] **Step 3: Create the hook script**

Create `plugins/saas-startup-team/scripts/enforce-handoff-naming.sh`:

```bash
#!/bin/bash
# enforce-handoff-naming.sh — PreToolUse hook for Write.
# Blocks Writes under .startup/handoffs/ unless the filename is INDEX.md or
# matches the canonical NNN-<direction>.md pattern. Exit 2 with systemMessage
# on block; exit 0 otherwise (pass through).
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a handoff path, or canonical name
# Exit 2: blocked, systemMessage on stderr

set -uo pipefail

input=$(cat || true)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -z "$file_path" ] && exit 0

# Only act on writes under .startup/handoffs/
case "$file_path" in
  */.startup/handoffs/*) ;;
  *) exit 0 ;;
esac

filename=$(basename "$file_path")
[ "$filename" = "INDEX.md" ] && exit 0

# Canonical format
if [[ "$filename" =~ ^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$ ]]; then
  exit 0
fi

# Compute next available NNN for the error message
handoff_dir=$(dirname "$file_path")
next_nnn="001"
if [ -d "$handoff_dir" ]; then
  max=$(ls "$handoff_dir" 2>/dev/null | grep -oE '^[0-9]{3}' | sort -n | tail -1 || true)
  if [ -n "$max" ]; then
    next_nnn=$(printf '%03d' $((10#$max + 1)))
  fi
fi

msg="Handoff filename '${filename}' is not valid. Handoffs must be named NNN-<direction>.md where NNN is a zero-padded 3-digit number and <direction> is one of: business-to-tech, tech-to-business, business-to-growth, growth-to-business. Next available NNN: ${next_nnn}. Binaries (.pdf, .png) belong in .startup/attachments/; signoffs in .startup/signoffs/; reviews in .startup/reviews/."

jq -n --arg msg "$msg" '{systemMessage: $msg}' >&2
exit 2
```

- [ ] **Step 4: Make executable**

```bash
chmod +x plugins/saas-startup-team/scripts/enforce-handoff-naming.sh
```

- [ ] **Step 5: Run tests, expect Suite R to pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: all R1–R13 PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/scripts/enforce-handoff-naming.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): enforce-handoff-naming PreToolUse hook (#21)"
```

---

## Task 3: Register hook in `hooks.json`

**Files:**
- Modify: `plugins/saas-startup-team/hooks/hooks.json`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_plugin_config`)

- [ ] **Step 1: Add assertion in plugin config test**

Locate `test_plugin_config()` (around line 433). After the existing assertions for hook entries, add:

```bash
  # C-enforce: PreToolUse enforce-handoff-naming.sh is registered
  local enforce_cmd
  enforce_cmd=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$PLUGIN_ROOT/hooks/hooks.json" | grep -F "enforce-handoff-naming.sh" || true)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$enforce_cmd" ]; then
    echo -e "  ${GREEN}PASS${NC} C-enforce: PreToolUse hook registers enforce-handoff-naming.sh"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} C-enforce: PreToolUse hook does not register enforce-handoff-naming.sh"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("C-enforce: missing enforce-handoff-naming.sh in PreToolUse")
  fi

  # C-enforce-matcher: the entry uses matcher "Write"
  local enforce_matcher
  enforce_matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | test("enforce-handoff-naming.sh")) | .matcher // empty' "$PLUGIN_ROOT/hooks/hooks.json")
  assert_equals "C-enforce-matcher: matcher is Write" "$enforce_matcher" "Write"
```

- [ ] **Step 2: Run tests, expect C-enforce to fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: `C-enforce` FAIL.

- [ ] **Step 3: Add the PreToolUse block**

Edit `plugins/saas-startup-team/hooks/hooks.json`. Inside `"hooks": { ... }`, add a sibling key `"PreToolUse"` alongside the existing `"TeammateIdle"`, `"TaskCompleted"`, `"PostToolUse"`, `"Stop"` keys:

```json
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/enforce-handoff-naming.sh",
            "description": "Block non-conforming handoff filenames (NNN-<direction>.md only)"
          }
        ]
      }
    ],
```

Exact insertion: add this block directly after the opening `"hooks": {` brace on line 2 and before `"TeammateIdle": [`. Keep comma placement valid.

- [ ] **Step 4: Validate JSON**

Run: `jq empty plugins/saas-startup-team/hooks/hooks.json`
Expected: no output, exit 0.

- [ ] **Step 5: Run tests, expect C-enforce to pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: all C-enforce assertions PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/hooks/hooks.json plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): register PreToolUse enforce-handoff-naming hook (#21)"
```

---

## Task 4: Migration script skeleton

**Files:**
- Create: `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (new `test_migrate_handoff_names` function)

Skeleton: argument parsing (`--apply` flag), handoff dir resolution (arg or git root), dry-run default, canonical-skip logic, empty summary output.

- [ ] **Step 1: Write the initial test function**

Append to `plugins/saas-startup-team/tests/run-tests.sh` before `main()`:

```bash
# ---------------------------------------------------------------------------
# Suite S: Migrate Handoff Names (migrate-handoff-names.sh)
# ---------------------------------------------------------------------------

test_migrate_handoff_names() {
  echo -e "\n${CYAN}Suite S: migrate-handoff-names.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/migrate-handoff-names.sh"
  local workdir ec output

  # S1: script exists and is executable
  assert_file_exists "S1: migrate-handoff-names.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} S1b: script is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S1b: script is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S1b: script is not executable")
  fi

  # S2: dry-run on empty dir returns 0 with summary
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S2: empty dir dry-run exits 0" "$ec" 0
  assert_output_contains "S2b: output says dry-run" "$output" "Dry-run"
  assert_output_contains "S2c: summary line present" "$output" "Summary:"
  rm -rf "$workdir"

  # S3: canonical-only dir — nothing to change
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/001-business-to-tech.md"
  touch "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S3: canonical-only exits 0" "$ec" 0
  assert_output_contains "S3b: skip count is 2" "$output" "Skipping (already canonical): 2"
  rm -rf "$workdir"
}
```

Add dispatch in `main()` after `test_enforce_handoff_naming_hook`:

```bash
  test_migrate_handoff_names
```

- [ ] **Step 2: Run tests, expect Suite S to fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S1 FAIL (script missing).

- [ ] **Step 3: Create the migration script skeleton**

Create `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`:

```bash
#!/bin/bash
# migrate-handoff-names.sh — one-time cleanup of .startup/handoffs/ to enforce
# the canonical NNN-<direction>.md filename convention.
#
# Moves misplaced signoffs to .startup/signoffs/, reviews to .startup/reviews/,
# binaries and directories to .startup/attachments/, and renames residual
# topic-slug handoffs to NNN-<direction>.md with next-available numbers.
#
# Usage:
#   bash migrate-handoff-names.sh                  # dry-run against git root
#   bash migrate-handoff-names.sh --apply          # execute
#   bash migrate-handoff-names.sh <handoff-dir>    # dry-run on explicit dir
#   bash migrate-handoff-names.sh --apply <dir>    # execute on explicit dir

set -uo pipefail

APPLY=0
HANDOFF_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0 ;;
    *) HANDOFF_DIR="$1" ;;
  esac
  shift
done

if [ -z "$HANDOFF_DIR" ]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Not in a git repo and no dir argument supplied." >&2
    exit 1
  }
  HANDOFF_DIR="$GIT_ROOT/.startup/handoffs"
fi

if [ ! -d "$HANDOFF_DIR" ]; then
  echo "Handoff dir not found: $HANDOFF_DIR" >&2
  exit 1
fi

STARTUP_DIR=$(dirname "$HANDOFF_DIR")
SIGNOFFS_DIR="$STARTUP_DIR/signoffs"
REVIEWS_DIR="$STARTUP_DIR/reviews"
ATTACH_DIR="$STARTUP_DIR/attachments"

CANONICAL_RE='^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$'

# Buckets: arrays of "<source>|<dest>" strings
SKIP_COUNT=0
MOVE_SIGNOFFS=()
MOVE_REVIEWS=()
MOVE_ATTACH=()
RENAMES=()
MANUAL=()

# --- Scan pass ---
shopt -s nullglob dotglob
for entry in "$HANDOFF_DIR"/*; do
  [ "$(basename "$entry")" = "INDEX.md" ] && { SKIP_COUNT=$((SKIP_COUNT + 1)); continue; }
  filename=$(basename "$entry")

  if [[ "$filename" =~ $CANONICAL_RE ]] && [ -f "$entry" ]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Rules 2-5 will be added in later tasks. For now, anything non-canonical
  # goes to MANUAL so the skeleton produces correct counts on mixed dirs.
  MANUAL+=("${entry}|(rules not yet implemented)")
done
shopt -u nullglob dotglob

# --- Output ---
echo "=== Handoff migration plan for ${HANDOFF_DIR} ==="
echo ""
echo "Skipping (already canonical): ${SKIP_COUNT}"
echo ""

if [ "${#MANUAL[@]}" -gt 0 ]; then
  echo "Manual review needed (${#MANUAL[@]} files, left in place):"
  for item in "${MANUAL[@]}"; do
    src="${item%%|*}"
    reason="${item##*|}"
    echo "  $(basename "$src")    (reason: ${reason})"
  done
  echo ""
fi

echo "Summary: skip ${SKIP_COUNT}, move $((${#MOVE_SIGNOFFS[@]} + ${#MOVE_REVIEWS[@]} + ${#MOVE_ATTACH[@]})), rename ${#RENAMES[@]}, manual ${#MANUAL[@]}"

if [ "$APPLY" -eq 0 ]; then
  echo "Dry-run — re-run with --apply to perform changes."
fi
```

- [ ] **Step 4: Make executable**

```bash
chmod +x plugins/saas-startup-team/scripts/migrate-handoff-names.sh
```

- [ ] **Step 5: Run tests, expect Suite S to pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S1–S3c PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/scripts/migrate-handoff-names.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): migrate-handoff-names.sh skeleton (#21)"
```

---

## Task 5: Migration — MOVE rules (signoffs, reviews, attachments)

**Files:**
- Modify: `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (extend Suite S)

Implements rules 2, 3, 4 from the spec.

- [ ] **Step 1: Add tests for move rules**

Append to `test_migrate_handoff_names()` function, after the S3 block:

```bash
  # S4: roundtrip-signoff moves to signoffs/
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/133-roundtrip-signoff.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S4: dry-run with signoff exits 0" "$ec" 0
  assert_output_contains "S4b: plan moves to signoffs/" "$output" "Move to .startup/signoffs/"
  assert_output_contains "S4c: plan lists 133-roundtrip-signoff" "$output" "133-roundtrip-signoff.md"
  rm -rf "$workdir"

  # S5: qa-review moves to reviews/
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/369-qa-review.md"
  touch "$workdir/.startup/handoffs/business-to-tech-satisfaction-guarantee.lawyer.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S5: plan moves to reviews/" "$output" "Move to .startup/reviews/"
  assert_output_contains "S5b: plan lists qa-review file" "$output" "369-qa-review.md"
  assert_output_contains "S5c: .lawyer.md renamed to lawyer-*" "$output" "lawyer-business-to-tech-satisfaction-guarantee.md"
  rm -rf "$workdir"

  # S6: binary moves to attachments/
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/arve_fixed_logo_preview.pdf"
  touch "$workdir/.startup/handoffs/arve_fixed_logo_preview.png"
  mkdir -p "$workdir/.startup/handoffs/421-artifacts"
  touch "$workdir/.startup/handoffs/421-artifacts/sample.pdf"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S6: plan moves to attachments/" "$output" "Move to .startup/attachments/"
  assert_output_contains "S6b: plan lists pdf" "$output" "arve_fixed_logo_preview.pdf"
  assert_output_contains "S6c: plan lists directory" "$output" "421-artifacts"
  rm -rf "$workdir"
```

- [ ] **Step 2: Run tests, expect S4–S6 to fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S4, S5, S6 FAIL (rules not implemented).

- [ ] **Step 3: Replace the scan-pass loop with the full move logic**

In `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`, replace the existing scan-pass `for entry in "$HANDOFF_DIR"/*; do … done` block with:

```bash
shopt -s nullglob dotglob
for entry in "$HANDOFF_DIR"/*; do
  filename=$(basename "$entry")
  [ "$filename" = "INDEX.md" ] && { SKIP_COUNT=$((SKIP_COUNT + 1)); continue; }

  # Canonical file — skip
  if [ -f "$entry" ] && [[ "$filename" =~ $CANONICAL_RE ]]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Rule 2: signoffs → .startup/signoffs/
  case "$filename" in
    *roundtrip-signoff*.md|*-signoff.md|signoff-*.md)
      MOVE_SIGNOFFS+=("${entry}|${SIGNOFFS_DIR}/${filename}")
      continue ;;
  esac

  # Rule 3: review artifacts → .startup/reviews/
  # Match a range of review-like patterns. Rename .lawyer.md / .QA-PASS.md
  # variants into cleaner names on the way out.
  dest_name="$filename"
  matched_review=0
  case "$filename" in
    *.lawyer.md)
      base="${filename%.lawyer.md}"
      dest_name="lawyer-${base}.md"
      matched_review=1 ;;
    *.QA-PASS.md)
      base="${filename%.QA-PASS.md}"
      dest_name="qa-pass-${base}.md"
      matched_review=1 ;;
    *-qa-review.md|*-qa-pass.md) matched_review=1 ;;
    *-business-review*.md|business-review-*.md) matched_review=1 ;;
    *-business-qa*.md|business-qa-*.md) matched_review=1 ;;
    *-regression-tests-*.md|*-regression-results-*.md) matched_review=1 ;;
    *ux-audit*.md|*ux-fixes*.md) matched_review=1 ;;
    tribunal-*-to-tech*.md|*-tribunal-to-tech*.md|*-tribunal-review-to-tech*.md) matched_review=1 ;;
    *-tech-review-fixes*.md|*-tech-fixes*.md) matched_review=1 ;;
    *-business-verification*.md) matched_review=1 ;;
  esac
  if [ "$matched_review" = "1" ]; then
    MOVE_REVIEWS+=("${entry}|${REVIEWS_DIR}/${dest_name}")
    continue
  fi

  # Rule 4: non-.md or directory → .startup/attachments/
  if [ -d "$entry" ]; then
    MOVE_ATTACH+=("${entry}|${ATTACH_DIR}/${filename}")
    continue
  fi
  case "$filename" in
    *.md) ;;
    *)
      MOVE_ATTACH+=("${entry}|${ATTACH_DIR}/${filename}")
      continue ;;
  esac

  # Fallthrough — leave unresolved for now; rules 5–6 added in later task
  MANUAL+=("${entry}|(rules 5-6 not yet implemented)")
done
shopt -u nullglob dotglob
```

- [ ] **Step 4: Extend the output section to print the move plans**

Replace the existing output section (from `echo "=== Handoff migration plan…"` through the Summary line) with:

```bash
echo "=== Handoff migration plan for ${HANDOFF_DIR} ==="
echo ""
echo "Skipping (already canonical): ${SKIP_COUNT}"
echo ""

print_move_section() {
  local title="$1"
  shift
  local items=("$@")
  [ "${#items[@]}" -eq 0 ] && return
  echo "${title} (${#items[@]} files):"
  for item in "${items[@]}"; do
    src="${item%%|*}"
    dest="${item##*|}"
    echo "  $(basename "$src") → ${dest}"
  done
  echo ""
}

print_move_section "Move to .startup/signoffs/" "${MOVE_SIGNOFFS[@]}"
print_move_section "Move to .startup/reviews/" "${MOVE_REVIEWS[@]}"
print_move_section "Move to .startup/attachments/" "${MOVE_ATTACH[@]}"

if [ "${#RENAMES[@]}" -gt 0 ]; then
  echo "Rename (${#RENAMES[@]} files):"
  for item in "${RENAMES[@]}"; do
    src="${item%%|*}"
    dest="${item##*|}"
    echo "  $(basename "$src") → $(basename "$dest")"
  done
  echo ""
fi

if [ "${#MANUAL[@]}" -gt 0 ]; then
  echo "Manual review needed (${#MANUAL[@]} files, left in place):"
  for item in "${MANUAL[@]}"; do
    src="${item%%|*}"
    reason="${item##*|}"
    echo "  $(basename "$src")    (reason: ${reason})"
  done
  echo ""
fi

echo "Summary: skip ${SKIP_COUNT}, move $((${#MOVE_SIGNOFFS[@]} + ${#MOVE_REVIEWS[@]} + ${#MOVE_ATTACH[@]})), rename ${#RENAMES[@]}, manual ${#MANUAL[@]}"

if [ "$APPLY" -eq 0 ]; then
  echo "Dry-run — re-run with --apply to perform changes."
fi
```

- [ ] **Step 5: Run tests, expect S4–S6 to pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S4, S5, S6 PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/scripts/migrate-handoff-names.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): migration move rules for signoffs/reviews/attachments (#21)"
```

---

## Task 6: Migration — RENAME rule (canonical direction inference)

**Files:**
- Modify: `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (extend Suite S)

Implements rule 5 from the spec: frontmatter-first, filename-substring fallback; sequential NNN assignment from `max+1` sorted by mtime.

- [ ] **Step 1: Add tests for rename**

Append to `test_migrate_handoff_names()`:

```bash
  # S7: topic-slug renames to next-available NNN
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/012-business-to-tech.md"
  # older slug file — should get NNN 013
  touch -t 202603010000 "$workdir/.startup/handoffs/business-to-tech-foo.md"
  # newer slug file — should get NNN 014
  touch -t 202603020000 "$workdir/.startup/handoffs/tech-to-business-bar.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S7: rename section present" "$output" "Rename"
  assert_output_contains "S7b: foo → 013-business-to-tech" "$output" "business-to-tech-foo.md → 013-business-to-tech.md"
  assert_output_contains "S7c: bar → 014-tech-to-business" "$output" "tech-to-business-bar.md → 014-tech-to-business.md"
  rm -rf "$workdir"

  # S8: timestamp-prefix renames with canonical direction extracted
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/2026-04-16T074318Z-business-to-tech-improve-189.md"
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S8: timestamp file renamed to business-to-tech" "$output" "2026-04-16T074318Z-business-to-tech-improve-189.md → 001-business-to-tech.md"
  rm -rf "$workdir"

  # S9: frontmatter wins over filename
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  cat > "$workdir/.startup/handoffs/business-to-tech-misnamed.md" <<'EOF'
---
from: tech-founder
to: business-founder
iteration: 3
date: 2026-04-10
type: implementation
---

## Summary
Actually a tech-to-business handoff misnamed.
EOF
  ec=0
  output=$(bash "$script" "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_output_contains "S9: frontmatter-derived direction wins" "$output" "business-to-tech-misnamed.md → 001-tech-to-business.md"
  rm -rf "$workdir"
```

- [ ] **Step 2: Run tests, expect S7–S9 to fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S7, S8, S9 FAIL.

- [ ] **Step 3: Implement rename logic**

In `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`, add these helper functions near the top of the file (just after the `CANONICAL_RE=` line):

```bash
# Map frontmatter from:/to: pair to canonical direction, or empty if no match.
infer_from_frontmatter() {
  local file="$1"
  local from to
  from=$(awk '/^from:/ {gsub(/"/,"",$0); sub(/^from:[[:space:]]*/,""); print; exit}' "$file" 2>/dev/null | tr -d '[:space:]')
  to=$(awk '/^to:/ {gsub(/"/,"",$0); sub(/^to:[[:space:]]*/,""); print; exit}' "$file" 2>/dev/null | tr -d '[:space:]')
  case "${from}→${to}" in
    business-founder→tech-founder) echo "business-to-tech" ;;
    tech-founder→business-founder) echo "tech-to-business" ;;
    business-founder→growth-hacker) echo "business-to-growth" ;;
    growth-hacker→business-founder) echo "growth-to-business" ;;
    *) echo "" ;;
  esac
}

# Map filename substring to canonical direction, or empty if none found.
# Longest match first so "business-to-growth" isn't shadowed by "business".
infer_from_filename() {
  local filename="$1"
  for d in business-to-growth growth-to-business business-to-tech tech-to-business; do
    case "$filename" in
      *"$d"*) echo "$d"; return ;;
    esac
  done
  echo ""
}

# Compute the maximum NNN prefix in the handoff dir (0 if none).
max_canonical_nnn() {
  local dir="$1"
  ls "$dir" 2>/dev/null | grep -oE '^[0-9]{3}' | sort -n | tail -1 || echo "0"
}
```

Then, in the scan-pass loop, replace the fallthrough `MANUAL+=(...)` line with the rename logic. The full replacement for the inner loop body is:

```bash
  filename=$(basename "$entry")
  [ "$filename" = "INDEX.md" ] && { SKIP_COUNT=$((SKIP_COUNT + 1)); continue; }

  if [ -f "$entry" ] && [[ "$filename" =~ $CANONICAL_RE ]]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Rule 2: signoffs
  case "$filename" in
    *roundtrip-signoff*.md|*-signoff.md|signoff-*.md)
      MOVE_SIGNOFFS+=("${entry}|${SIGNOFFS_DIR}/${filename}")
      continue ;;
  esac

  # Rule 3: reviews (with .lawyer.md / .QA-PASS.md rename)
  dest_name="$filename"
  matched_review=0
  case "$filename" in
    *.lawyer.md)
      base="${filename%.lawyer.md}"; dest_name="lawyer-${base}.md"; matched_review=1 ;;
    *.QA-PASS.md)
      base="${filename%.QA-PASS.md}"; dest_name="qa-pass-${base}.md"; matched_review=1 ;;
    *-qa-review.md|*-qa-pass.md) matched_review=1 ;;
    *-business-review*.md|business-review-*.md) matched_review=1 ;;
    *-business-qa*.md|business-qa-*.md) matched_review=1 ;;
    *-regression-tests-*.md|*-regression-results-*.md) matched_review=1 ;;
    *ux-audit*.md|*ux-fixes*.md) matched_review=1 ;;
    tribunal-*-to-tech*.md|*-tribunal-to-tech*.md|*-tribunal-review-to-tech*.md) matched_review=1 ;;
    *-tech-review-fixes*.md|*-tech-fixes*.md) matched_review=1 ;;
    *-business-verification*.md) matched_review=1 ;;
  esac
  if [ "$matched_review" = "1" ]; then
    MOVE_REVIEWS+=("${entry}|${REVIEWS_DIR}/${dest_name}")
    continue
  fi

  # Rule 4: binaries / directories → attachments
  if [ -d "$entry" ]; then
    MOVE_ATTACH+=("${entry}|${ATTACH_DIR}/${filename}")
    continue
  fi
  case "$filename" in
    *.md) ;;
    *)
      MOVE_ATTACH+=("${entry}|${ATTACH_DIR}/${filename}")
      continue ;;
  esac

  # Rule 5: infer canonical direction
  direction=$(infer_from_frontmatter "$entry")
  if [ -z "$direction" ]; then
    direction=$(infer_from_filename "$filename")
  fi
  if [ -n "$direction" ]; then
    # Defer NNN assignment — collect into a rename candidate list with mtime
    mtime=$(stat -c '%Y' "$entry" 2>/dev/null || stat -f '%m' "$entry" 2>/dev/null || echo 0)
    RENAME_CANDIDATES+=("${mtime}|${entry}|${direction}")
    continue
  fi

  # Rule 6: manual review
  MANUAL+=("${entry}|no canonical direction in filename or frontmatter")
```

Add near the other array initializations:

```bash
RENAME_CANDIDATES=()
```

After the loop ends (before the Output section), add the NNN assignment pass:

```bash
# Assign NNNs to rename candidates in mtime order, starting at max+1.
max_nnn=$(max_canonical_nnn "$HANDOFF_DIR")
max_nnn=$((10#${max_nnn:-0}))
if [ "${#RENAME_CANDIDATES[@]}" -gt 0 ]; then
  # Sort by mtime (ascending)
  IFS=$'\n' sorted=($(printf '%s\n' "${RENAME_CANDIDATES[@]}" | sort -t'|' -k1,1n))
  unset IFS
  for item in "${sorted[@]}"; do
    src="${item#*|}"; src="${src%%|*}"          # middle field
    direction="${item##*|}"
    max_nnn=$((max_nnn + 1))
    nnn=$(printf '%03d' "$max_nnn")
    RENAMES+=("${src}|${HANDOFF_DIR}/${nnn}-${direction}.md")
  done
fi
```

- [ ] **Step 4: Run tests, expect S7–S9 to pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S7, S8, S9 PASS. Earlier S1–S6 still PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/migrate-handoff-names.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): migration rename rule with NNN assignment (#21)"
```

---

## Task 7: Migration — `--apply` execution and INDEX refresh

**Files:**
- Modify: `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (extend Suite S)

Implements the --apply path: create destination dirs, perform mv operations with collision handling, re-run `backfill-handoff-index.sh`.

- [ ] **Step 1: Add tests for --apply**

Append to `test_migrate_handoff_names()`:

```bash
  # S10: --apply performs moves and renames
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs"
  touch "$workdir/.startup/handoffs/001-business-to-tech.md"
  touch "$workdir/.startup/handoffs/133-roundtrip-signoff.md"
  touch "$workdir/.startup/handoffs/369-qa-review.md"
  touch "$workdir/.startup/handoffs/arve.pdf"
  touch "$workdir/.startup/handoffs/business-to-tech-foo.md"
  ec=0
  output=$(bash "$script" --apply "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S10: --apply exits 0" "$ec" 0
  assert_file_exists "S10b: canonical preserved" "$workdir/.startup/handoffs/001-business-to-tech.md"
  assert_file_exists "S10c: signoff moved" "$workdir/.startup/signoffs/133-roundtrip-signoff.md"
  assert_file_exists "S10d: review moved" "$workdir/.startup/reviews/369-qa-review.md"
  assert_file_exists "S10e: binary moved" "$workdir/.startup/attachments/arve.pdf"
  assert_file_exists "S10f: slug renamed to 002-business-to-tech.md" "$workdir/.startup/handoffs/002-business-to-tech.md"
  # Source filenames must no longer exist in handoffs/
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -e "$workdir/.startup/handoffs/business-to-tech-foo.md" ]; then
    echo -e "  ${GREEN}PASS${NC} S10g: source slug removed from handoffs/"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S10g: source slug still in handoffs/"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S10g: source slug not removed")
  fi
  assert_file_exists "S10h: INDEX.md regenerated" "$workdir/.startup/handoffs/INDEX.md"
  rm -rf "$workdir"

  # S11: --apply collision appends -dup suffix
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/handoffs" "$workdir/.startup/signoffs"
  touch "$workdir/.startup/handoffs/133-roundtrip-signoff.md"
  touch "$workdir/.startup/signoffs/133-roundtrip-signoff.md"  # pre-existing
  ec=0
  output=$(bash "$script" --apply "$workdir/.startup/handoffs" 2>&1) || ec=$?
  assert_exit_code "S11: collision exits 0" "$ec" 0
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if ls "$workdir/.startup/signoffs/"*-dup* >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} S11b: collision produces -dup file"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} S11b: no -dup file in signoffs/"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("S11b: no -dup file")
  fi
  rm -rf "$workdir"
```

- [ ] **Step 2: Run tests, expect S10–S11 to fail**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: S10, S11 FAIL (apply not implemented).

- [ ] **Step 3: Implement --apply**

In `plugins/saas-startup-team/scripts/migrate-handoff-names.sh`, insert this block AFTER the Output section (after the `Dry-run` message but before end of file):

```bash
# --- Apply pass ---
if [ "$APPLY" -ne 1 ]; then
  exit 0
fi

mkdir -p "$SIGNOFFS_DIR" "$REVIEWS_DIR" "$ATTACH_DIR"

apply_move() {
  local src="$1" dest="$2"
  if [ -e "$dest" ]; then
    local ts
    ts=$(date +%Y%m%d%H%M%S)
    local base="${dest%.*}"
    local ext="${dest##*.}"
    if [ "$base" = "$dest" ]; then
      dest="${dest}-dup${ts}"
    else
      dest="${base}-dup${ts}.${ext}"
    fi
  fi
  mv "$src" "$dest"
}

for item in "${MOVE_SIGNOFFS[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done
for item in "${MOVE_REVIEWS[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done
for item in "${MOVE_ATTACH[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done
for item in "${RENAMES[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done

echo ""
echo "[DONE] Applied: ${#MOVE_SIGNOFFS[@]} signoffs, ${#MOVE_REVIEWS[@]} reviews, ${#MOVE_ATTACH[@]} attachments, ${#RENAMES[@]} renames."

# Regenerate INDEX.md to reflect the new state
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/backfill-handoff-index.sh" ]; then
  echo "Regenerating $HANDOFF_DIR/INDEX.md..."
  bash "$SCRIPT_DIR/backfill-handoff-index.sh" "$HANDOFF_DIR"
fi
```

Also: the existing dry-run footer `if [ "$APPLY" -eq 0 ]; then echo "Dry-run..."; fi` will already skip the `[DONE]` section, so no conflict.

- [ ] **Step 4: Run tests, expect S10–S11 to pass**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: all Suite S tests PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/migrate-handoff-names.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): migrate-handoff-names --apply + INDEX refresh (#21)"
```

---

## Task 8: Documentation update

**Files:**
- Modify: `plugins/saas-startup-team/skills/startup-orchestration/references/handoff-protocol.md`

- [ ] **Step 1: Append the Enforcement section**

Open `plugins/saas-startup-team/skills/startup-orchestration/references/handoff-protocol.md`. After the existing "### Handoff Index (INDEX.md)" block (ends around line 86), before "## Handoff Validation Checklist" (line 87), insert:

```markdown
### Enforcement

The canonical format is enforced by a PreToolUse hook (`enforce-handoff-naming.sh`).
Writes to `.startup/handoffs/` that don't match `NNN-<direction>.md` with one of the four canonical directions are blocked with an error message that names the next available NNN.

Misrouted content has dedicated homes:
- Signoffs → `.startup/signoffs/`
- Review artifacts (QA, lawyer, UX audit, tribunal, regression) → `.startup/reviews/`
- Binaries and directories → `.startup/attachments/`

For legacy projects with pre-existing non-conforming files, run the one-time migration script:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/migrate-handoff-names.sh          # dry-run, review the plan
bash $CLAUDE_PLUGIN_ROOT/scripts/migrate-handoff-names.sh --apply  # execute
```

The migration moves misrouted content to the right subdirectory and renames residual topic-slug handoffs to `NNN-<direction>.md` with next-available numbers. Sort is by mtime so chronology is preserved.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/startup-orchestration/references/handoff-protocol.md
git commit -m "docs(saas-startup-team): document handoff naming enforcement + migration (#21)"
```

---

## Task 9: Final test suite run

- [ ] **Step 1: Run the full plugin test suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: all suites A–S pass, no regressions.

- [ ] **Step 2: If any regression, fix and re-run**

If any previously-passing suite failed (e.g., a `test_plugin_config` assertion), correct and re-run. Do not proceed to aruannik validation until the suite is green.

---

## Task 10: Aruannik validation — dry-run

**Files:** operates on `/mnt/data/ai/est-biz-aruannik/.startup/handoffs/`

- [ ] **Step 1: Dry-run against aruannik**

```bash
bash /mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/migrate-handoff-names.sh /mnt/data/ai/est-biz-aruannik/.startup/handoffs/ > /tmp/aruannik-migration-plan.txt
```

- [ ] **Step 2: Review the plan**

```bash
cat /tmp/aruannik-migration-plan.txt | less
```

Expected structure: a "Summary: …" line at the end with counts for skip/move/rename/manual. Check especially:
- Move-to-signoffs count ≥ 35 (roundtrip-signoff + signoff files)
- Move-to-reviews count ≥ 40 (qa-review + lawyer + ux-audit + regression etc.)
- Move-to-attachments count ≥ 3 (pdf, png, 421-artifacts/)
- Rename count ≥ 30 (topic-slug + timestamp)
- Manual count small (investor-to-*, business-to-team, anything else unclassified)

- [ ] **Step 3: Spot-check a few specific items**

Verify the plan file contains:
- `arve_fixed_logo_preview.pdf → /mnt/data/ai/est-biz-aruannik/.startup/attachments/arve_fixed_logo_preview.pdf`
- `421-artifacts → /mnt/data/ai/est-biz-aruannik/.startup/attachments/421-artifacts`
- `2026-04-16T074318Z-business-to-tech-improve-189.md → ` (some `NNN-business-to-tech.md`)
- `business-to-tech-satisfaction-guarantee.lawyer.md → /mnt/data/ai/est-biz-aruannik/.startup/reviews/lawyer-business-to-tech-satisfaction-guarantee.md`
- `205-investor-to-business.md    (reason: no canonical direction ...)` under Manual review

If anything looks wrong (wrong section, missed rule), return to the relevant task and adjust before running --apply.

- [ ] **Step 4: Pause and request user confirmation**

If running under superpowers:subagent-driven-development / executing-plans, explicitly pause here and show the plan summary to the user. Do NOT run --apply without confirmation.

---

## Task 11: Aruannik validation — apply + verify

- [ ] **Step 1: Apply the migration**

```bash
bash /mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/migrate-handoff-names.sh --apply /mnt/data/ai/est-biz-aruannik/.startup/handoffs/ > /tmp/aruannik-migration-apply.txt
```

- [ ] **Step 2: Verify handoffs dir now contains only canonical + manual residue**

```bash
ls /mnt/data/ai/est-biz-aruannik/.startup/handoffs/ | grep -vE '^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$|^INDEX\.md$' > /tmp/aruannik-residue.txt
wc -l /tmp/aruannik-residue.txt
cat /tmp/aruannik-residue.txt
```

Expected: residue is only the "Manual review" files from Task 10 (investor-to-*, business-to-team-*, and anything else the script flagged). No signoffs, reviews, binaries, timestamp or topic-slug files.

- [ ] **Step 3: Verify destination dirs populated**

```bash
ls /mnt/data/ai/est-biz-aruannik/.startup/signoffs/ | head -20
ls /mnt/data/ai/est-biz-aruannik/.startup/reviews/ | head -20
ls /mnt/data/ai/est-biz-aruannik/.startup/attachments/
```

Expected: signoffs/ contains `*-roundtrip-signoff.md` and `NNN-signoff.md`; reviews/ contains `*-qa-review.md`, `lawyer-*.md`, `ux-*`, etc.; attachments/ contains `arve_fixed_logo_preview.pdf`, `arve_fixed_logo_preview.png`, `421-artifacts/`.

- [ ] **Step 4: Verify INDEX.md refreshed**

```bash
head -30 /mnt/data/ai/est-biz-aruannik/.startup/handoffs/INDEX.md
grep -c '^---' /mnt/data/ai/est-biz-aruannik/.startup/handoffs/INDEX.md
```

Expected: header line, format line, then one entry per handoff now in the dir. Count of `---` rows (unnumbered entries) should be zero or match the manual-review residue count exactly.

- [ ] **Step 5: Touch-test the hook**

```bash
echo '{"tool_input":{"file_path":"/mnt/data/ai/est-biz-aruannik/.startup/handoffs/garbage-name.md"}}' | bash /mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/enforce-handoff-naming.sh
echo "Exit: $?"
```

Expected: exit 2, stderr JSON with a `systemMessage` that says "Handoff filename 'garbage-name.md' is not valid." and names a concrete next NNN (the aruannik max + 1).

---

## Task 12: Final integration

- [ ] **Step 1: Confirm clean working tree for plugin changes**

Run: `git status`
Expected: clean (all commits from prior tasks are in).

- [ ] **Step 2: Verify commit list**

Run: `git log --oneline main..HEAD`
Expected sequence (approximate):
- version bump
- enforce-handoff-naming hook
- PreToolUse registration
- migration skeleton
- migration move rules
- migration rename rule
- migration apply + INDEX refresh
- docs update

If the work was done directly on main (no feature branch), skip this check.

- [ ] **Step 3: Push / open PR (user-triggered only)**

Do NOT push unless explicitly asked. If asked:
```bash
git push origin HEAD
```

Then follow normal PR creation for this repo (see CLAUDE.md: `git config core.hooksPath .githooks` pre-push version-sync check will run).

---

## Self-Review (completed before writing this plan)

**Spec coverage:**
- [x] Enforcement hook → Task 2 + Task 3
- [x] Migration script with all rules → Tasks 4, 5, 6, 7
- [x] Documentation update → Task 8
- [x] Version bump → Task 1
- [x] Aruannik validation → Tasks 10, 11
- [x] Tests for hook and migration → Tasks 2, 4, 5, 6, 7

**Placeholder scan:** no TBDs/TODOs; every code step contains full code.

**Type consistency:** canonical regex used identically in hook, migration, tests. Array variable names (`MOVE_SIGNOFFS`, `MOVE_REVIEWS`, `MOVE_ATTACH`, `RENAMES`, `RENAME_CANDIDATES`, `MANUAL`) used consistently. Destination path variables (`SIGNOFFS_DIR`, `REVIEWS_DIR`, `ATTACH_DIR`) consistent.
