# `/goal-deliver` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/goal-deliver` command to the saas-startup-team plugin that autonomously plans a set of tasks into dependency-ordered chunks, ships each chunk via the `/improve` flow + closing tribunal loop + merge-to-main, then monitors and auto-fixes the GitHub Actions deploy.

**Architecture:** The command itself is a markdown orchestrator prompt (`commands/goal-deliver.md`). The deterministic, bug-prone logic — input classification and the chunk-plan state machine (eligibility, topological ordering, transitive dependent-blocking, cycle detection) — lives in two bash helper scripts (`scripts/goal-input.sh`, `scripts/goal-chunks.sh`) that operate on a `.startup/goals/<slug>/plan.json` state file. Scripts are unit-tested in the existing `tests/run-tests.sh` harness; the command is covered by cross-file consistency assertions.

**Tech Stack:** bash 4+, jq, `gh` CLI, the existing `tests/run-tests.sh` suite harness, and the `tribunal-review` plugin (hard dependency for the gate).

---

## Spec

Design spec: `plugins/saas-startup-team/docs/superpowers/specs/2026-05-29-goal-deliver-command-design.md`. Read it before starting — this plan implements that spec.

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `plugins/saas-startup-team/scripts/goal-input.sh` | Classify command args into `{type, refs}` JSON (issues / milestone / file / freetext) | Create |
| `plugins/saas-startup-team/scripts/goal-chunks.sh` | Chunk-plan state machine over `plan.json`: `validate`, `next`, `set-status`, `set-field`, `inc-rounds`, `add-issue`, `block-dependents`, `summary` | Create |
| `plugins/saas-startup-team/commands/goal-deliver.md` | The orchestrator prompt: pre-flight, two-pass plan review, per-chunk loop, deploy monitor, final report | Create |
| `plugins/saas-startup-team/tests/run-tests.sh` | Add Suite L (`test_goal_input`), Suite M (`test_goal_chunks`), Suite N (`test_goal_deliver_command`); register all three in `main()` | Modify |
| `plugins/saas-startup-team/.claude-plugin/plugin.json` | Bump `version` 0.36.0 → 0.37.0 | Modify |
| `.claude-plugin/marketplace.json` (repo root) | Bump saas-startup-team `version` 0.36.0 → 0.37.0 (must match) | Modify |
| `plugins/saas-startup-team/README.md` | Document `/goal-deliver` in the command list | Modify |

All paths below are relative to the repo root `/mnt/data/ai/claude-plugins`.

### plan.json shape (produced by the command, consumed by goal-chunks.sh)

```jsonc
{
  "goal_slug": "issues-12-15-20",
  "created": "2026-05-29T10:00:00Z",
  "source": { "type": "issues", "refs": ["12", "15", "20"] },
  "chunks": [
    {
      "id": "C1", "title": "...", "description": "...",
      "issue_refs": ["12"], "depends_on": [],
      "status": "pending",
      "pr_url": null, "branch": null,
      "tribunal_rounds": 0, "filed_issues": [], "skip_reason": null
    }
  ],
  "deploy": { "status": "pending", "run_id": null }
}
```

`status` ∈ `pending | in-progress | merged | blocked | skipped`.

---

## Task 1: `goal-input.sh` — input classification

**Files:**
- Create: `plugins/saas-startup-team/scripts/goal-input.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (add Suite L `test_goal_input`, register in `main()`)

- [ ] **Step 1: Write the failing test suite**

Add this function to `tests/run-tests.sh` immediately before the final `main "$@"` line (after the last existing suite function):

```bash
# ---------------------------------------------------------------------------
# Suite L: goal-input.sh
# ---------------------------------------------------------------------------

test_goal_input() {
  echo -e "\n${CYAN}Suite L: goal-input.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/goal-input.sh"
  local ec output workdir

  # L0: script exists and is executable
  assert_file_exists "L0: goal-input.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} L0b: goal-input.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} L0b: goal-input.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("L0b: goal-input.sh not executable")
  fi

  # L1: all-#N args → issues, refs stripped of #
  ec=0; output=$(bash "$script" detect '#12' '#15' '#20' 2>&1) || ec=$?
  assert_exit_code "L1: issues exits 0" "$ec" 0
  assert_equals "L1b: type=issues" "$(echo "$output" | jq -r '.type')" "issues"
  assert_equals "L1c: refs joined" "$(echo "$output" | jq -r '.refs | join(",")')" "12,15,20"

  # L2: --milestone NAME → milestone
  ec=0; output=$(bash "$script" detect --milestone v2 2>&1) || ec=$?
  assert_equals "L2: type=milestone" "$(echo "$output" | jq -r '.type')" "milestone"
  assert_equals "L2b: milestone name" "$(echo "$output" | jq -r '.refs[0]')" "v2"

  # L3: single existing file path → file
  workdir=$(mktemp -d)
  echo "roadmap" > "$workdir/roadmap.md"
  ec=0; output=$(bash "$script" detect "$workdir/roadmap.md" 2>&1) || ec=$?
  assert_equals "L3: type=file" "$(echo "$output" | jq -r '.type')" "file"
  assert_equals "L3b: file path" "$(echo "$output" | jq -r '.refs[0]')" "$workdir/roadmap.md"
  rm -rf "$workdir"

  # L4: free text → freetext, full text preserved
  ec=0; output=$(bash "$script" detect add dark mode, fix nav 2>&1) || ec=$?
  assert_equals "L4: type=freetext" "$(echo "$output" | jq -r '.type')" "freetext"
  assert_equals "L4b: text preserved" "$(echo "$output" | jq -r '.refs[0]')" "add dark mode, fix nav"

  # L5: mixed #N and words → freetext (not issues)
  ec=0; output=$(bash "$script" detect fix '#12' styling 2>&1) || ec=$?
  assert_equals "L5: mixed → freetext" "$(echo "$output" | jq -r '.type')" "freetext"

  # L6: missing subcommand → usage error exit 1
  ec=0; output=$(bash "$script" 2>&1) || ec=$?
  assert_exit_code "L6: no subcommand exits 1" "$ec" 1
}
```

Then register it in `main()` — add the line after `test_migrate_handoff_names` (the last current suite call):

```bash
  test_migrate_handoff_names
  test_goal_input
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -A2 "Suite L"`
Expected: FAIL — `L0: goal-input.sh exists (file not found ...)` and downstream failures.

- [ ] **Step 3: Write the script**

Create `plugins/saas-startup-team/scripts/goal-input.sh`:

```bash
#!/bin/bash
# Classify /goal-deliver input arguments into {type, refs} JSON.
#   issues    — every arg matches #<digits>           → refs = issue numbers (no #)
#   milestone — args contain --milestone <name>        → refs = [name]
#   file      — single arg that is an existing file     → refs = [path]
#   freetext  — anything else                           → refs = [joined text]
# Usage: goal-input.sh detect <arg>...
set -euo pipefail

CMD="${1:-}"
if [ "$CMD" != "detect" ]; then
  echo "Usage: goal-input.sh detect <args...>" >&2
  exit 1
fi
shift
ARGS=("$@")

# 1. milestone: --milestone <name>
for i in "${!ARGS[@]}"; do
  if [ "${ARGS[$i]}" = "--milestone" ]; then
    name="${ARGS[$((i + 1))]:-}"
    jq -cn --arg n "$name" '{type:"milestone", refs:[$n]}'
    exit 0
  fi
done

# 2. file: exactly one arg, and it is an existing file
if [ "${#ARGS[@]}" -eq 1 ] && [ -f "${ARGS[0]}" ]; then
  jq -cn --arg f "${ARGS[0]}" '{type:"file", refs:[$f]}'
  exit 0
fi

# 3. issues: ALL args are #<digits> (and there is at least one)
all_issues=1
issue_refs=()
if [ "${#ARGS[@]}" -eq 0 ]; then
  all_issues=0
fi
for a in "${ARGS[@]}"; do
  if [[ "$a" =~ ^#([0-9]+)$ ]]; then
    issue_refs+=("${BASH_REMATCH[1]}")
  else
    all_issues=0
    break
  fi
done
if [ "$all_issues" -eq 1 ]; then
  printf '%s\n' "${issue_refs[@]}" | jq -R . | jq -cs '{type:"issues", refs:.}'
  exit 0
fi

# 4. freetext fallback
text="${ARGS[*]}"
jq -cn --arg t "$text" '{type:"freetext", refs:[$t]}'
exit 0
```

- [ ] **Step 4: Make executable and run the suite to verify it passes**

Run:
```bash
chmod +x plugins/saas-startup-team/scripts/goal-input.sh
bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "Suite L|FAIL"
```
Expected: all `L*` lines PASS; no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/goal-input.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): goal-input.sh input classification for /goal-deliver"
```

---

## Task 2: `goal-chunks.sh validate` — schema + cycle detection

**Files:**
- Create: `plugins/saas-startup-team/scripts/goal-chunks.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (add Suite M `test_goal_chunks` + a `mk_plan` helper, register in `main()`)

- [ ] **Step 1: Write the failing test (validate cases) plus the shared helper**

Add this helper and suite function to `tests/run-tests.sh` before `main "$@"` (after `test_goal_input`):

```bash
# Write a plan.json into a fresh temp dir; echo its path.
# $1 = chunks JSON array literal.
mk_plan() {
  local chunks="$1" dir
  dir=$(mktemp -d)
  jq -cn --argjson c "$chunks" \
    '{goal_slug:"t", created:"2026-05-29T00:00:00Z",
      source:{type:"freetext",refs:["t"]}, chunks:$c,
      deploy:{status:"pending",run_id:null}}' > "$dir/plan.json"
  echo "$dir/plan.json"
}

# ---------------------------------------------------------------------------
# Suite M: goal-chunks.sh
# ---------------------------------------------------------------------------

test_goal_chunks() {
  echo -e "\n${CYAN}Suite M: goal-chunks.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/goal-chunks.sh"
  local ec output plan

  # M0: script exists and is executable
  assert_file_exists "M0: goal-chunks.sh exists" "$script"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} M0b: goal-chunks.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} M0b: goal-chunks.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("M0b: goal-chunks.sh not executable")
  fi

  # M1: valid acyclic plan → "valid", exit 0
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending"},{"id":"C2","depends_on":["C1"],"status":"pending"}]')
  ec=0; output=$(bash "$script" validate "$plan" 2>&1) || ec=$?
  assert_exit_code "M1: valid plan exits 0" "$ec" 0
  assert_output_contains "M1b: prints valid" "$output" "valid"
  rm -rf "$(dirname "$plan")"

  # M2: duplicate ids → exit 2
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending"},{"id":"C1","depends_on":[],"status":"pending"}]')
  ec=0; output=$(bash "$script" validate "$plan" 2>&1) || ec=$?
  assert_exit_code "M2: duplicate ids exits 2" "$ec" 2
  rm -rf "$(dirname "$plan")"

  # M3: depends_on references unknown id → exit 2
  plan=$(mk_plan '[{"id":"C1","depends_on":["CX"],"status":"pending"}]')
  ec=0; output=$(bash "$script" validate "$plan" 2>&1) || ec=$?
  assert_exit_code "M3: unknown dep exits 2" "$ec" 2
  rm -rf "$(dirname "$plan")"

  # M4: dependency cycle → exit 2
  plan=$(mk_plan '[{"id":"C1","depends_on":["C2"],"status":"pending"},{"id":"C2","depends_on":["C1"],"status":"pending"}]')
  ec=0; output=$(bash "$script" validate "$plan" 2>&1) || ec=$?
  assert_exit_code "M4: cycle exits 2" "$ec" 2
  assert_output_contains "M4b: reports cycle" "$output" "cycle"
  rm -rf "$(dirname "$plan")"

  # M5: missing plan file → exit 1
  ec=0; output=$(bash "$script" validate /nonexistent/plan.json 2>&1) || ec=$?
  assert_exit_code "M5: missing file exits 1" "$ec" 1
}
```

Register in `main()` after `test_goal_input`:

```bash
  test_goal_input
  test_goal_chunks
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -A2 "Suite M"`
Expected: FAIL — `M0: goal-chunks.sh exists (file not found ...)`.

- [ ] **Step 3: Write the script with `validate` (and the dispatch skeleton)**

Create `plugins/saas-startup-team/scripts/goal-chunks.sh`:

```bash
#!/bin/bash
# State machine for /goal-deliver chunk plans (.startup/goals/<slug>/plan.json).
# Subcommands (all take the plan path as $2):
#   validate          — JSON valid, unique ids, deps resolvable, no cycles
#   next              — print id of next eligible chunk ("" if none)
#   set-status <id> <status>
#   set-field  <id> <field> <value>
#   inc-rounds <id>
#   add-issue  <id> <url>
#   block-dependents <id> <reason>
#   summary           — "merged=N blocked=N skipped=N pending=N in_progress=N deploy=S"
set -euo pipefail

CMD="${1:-}"
PLAN="${2:-}"

if [ -z "$CMD" ] || [ -z "$PLAN" ]; then
  echo "Usage: goal-chunks.sh <command> <plan.json> [args...]" >&2
  exit 1
fi
if [ ! -f "$PLAN" ]; then
  echo "Plan file not found: $PLAN" >&2
  exit 1
fi

write_back() { # write_back <jq args...>
  local tmp
  tmp=$(mktemp)
  jq "$@" "$PLAN" > "$tmp" && mv "$tmp" "$PLAN"
}

case "$CMD" in
  validate)
    jq empty "$PLAN" 2>/dev/null || { echo "invalid JSON" >&2; exit 2; }
    dupes=$(jq -r '[.chunks[].id] | group_by(.) | map(select(length>1)) | length' "$PLAN")
    [ "$dupes" -eq 0 ] || { echo "duplicate chunk ids" >&2; exit 2; }
    bad=$(jq -r '
      ([.chunks[].id]) as $ids
      | [ .chunks[] | .depends_on[] | select(($ids | index(.)) | not) ] | length' "$PLAN")
    [ "$bad" -eq 0 ] || { echo "depends_on references unknown chunk" >&2; exit 2; }
    # Cycle detection via iterative removal of dependency-free nodes (Kahn).
    remaining=$(jq -c '[.chunks[] | {id, deps: .depends_on}]' "$PLAN")
    while : ; do
      ready=$(echo "$remaining" | jq -c '[ .[] | select((.deps|length)==0) | .id ]')
      [ "$(echo "$ready" | jq 'length')" -eq 0 ] && break
      remaining=$(echo "$remaining" | jq -c --argjson r "$ready" \
        '[ .[] | select((.id as $i | ($r|index($i))) | not) | {id, deps: (.deps - $r)} ]')
    done
    [ "$(echo "$remaining" | jq 'length')" -eq 0 ] || { echo "dependency cycle detected" >&2; exit 2; }
    echo "valid"
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 4: Make executable and run to verify it passes**

Run:
```bash
chmod +x plugins/saas-startup-team/scripts/goal-chunks.sh
bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M[0-9]|FAIL"
```
Expected: all `M0`–`M5` PASS; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/goal-chunks.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): goal-chunks.sh validate (schema + cycle detection)"
```

---

## Task 3: `goal-chunks.sh next` — eligibility / topological pick

**Files:**
- Modify: `plugins/saas-startup-team/scripts/goal-chunks.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_goal_chunks`)

- [ ] **Step 1: Write the failing test (append to `test_goal_chunks`)**

Append these cases at the end of the `test_goal_chunks` function, before its closing `}`:

```bash
  # M6: next picks first pending chunk whose deps are all merged
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"merged"},{"id":"C2","depends_on":["C1"],"status":"pending"},{"id":"C3","depends_on":["C2"],"status":"pending"}]')
  ec=0; output=$(bash "$script" next "$plan" 2>&1) || ec=$?
  assert_exit_code "M6: next exits 0" "$ec" 0
  assert_equals "M6b: picks C2 (deps merged)" "$output" "C2"
  rm -rf "$(dirname "$plan")"

  # M7: chunk with unmet dep is not eligible
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending"},{"id":"C2","depends_on":["C1"],"status":"pending"}]')
  ec=0; output=$(bash "$script" next "$plan" 2>&1) || ec=$?
  assert_equals "M7: picks C1 (no deps)" "$output" "C1"
  rm -rf "$(dirname "$plan")"

  # M8: no eligible chunk → empty output
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"merged"},{"id":"C2","depends_on":[],"status":"skipped"}]')
  ec=0; output=$(bash "$script" next "$plan" 2>&1) || ec=$?
  assert_equals "M8: no eligible → empty" "$output" ""
  rm -rf "$(dirname "$plan")"

  # M9: in-progress chunks are not re-picked
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"in-progress"},{"id":"C2","depends_on":[],"status":"pending"}]')
  ec=0; output=$(bash "$script" next "$plan" 2>&1) || ec=$?
  assert_equals "M9: skips in-progress, picks C2" "$output" "C2"
  rm -rf "$(dirname "$plan")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M[6-9]"`
Expected: FAIL — `next` is an unknown command (exit 1 / empty), so `M6b` etc. mismatch.

- [ ] **Step 3: Implement `next`**

In `goal-chunks.sh`, add this case to the `case "$CMD" in` block (before the `*)` catch-all):

```bash
  next)
    jq -r '
      ([ .chunks[] | select(.status=="merged") | .id ]) as $merged
      | (first(
          .chunks[]
          | select(.status=="pending")
          | select([ .depends_on[] | ($merged | index(.)) ] | all)
          | .id
        )) // ""' "$PLAN"
    ;;
```

Note: jq `all` over an empty array is `true`, so a chunk with no `depends_on` is always eligible. `index` returns a number (truthy, incl. 0) when found and `null` when not, so `all` is true only when every dep is merged.

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M[6-9]|FAIL"`
Expected: `M6`–`M9` PASS; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/goal-chunks.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): goal-chunks.sh next (eligibility + topological pick)"
```

---

## Task 4: `goal-chunks.sh` mutations — set-status, set-field, inc-rounds, add-issue

**Files:**
- Modify: `plugins/saas-startup-team/scripts/goal-chunks.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_goal_chunks`)

- [ ] **Step 1: Write the failing test (append to `test_goal_chunks`)**

Append before the closing `}` of `test_goal_chunks`:

```bash
  # M10: set-status updates the named chunk and persists valid JSON
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending"}]')
  bash "$script" set-status "$plan" C1 merged
  assert_json_valid "M10: still valid JSON after set-status" "$plan"
  assert_json_field "M10b: C1 status=merged" "$plan" '.chunks[0].status' "merged"
  rm -rf "$(dirname "$plan")"

  # M11: set-field sets a string field (pr_url)
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending","pr_url":null}]')
  bash "$script" set-field "$plan" C1 pr_url "https://github.com/o/r/pull/9"
  assert_json_field "M11: pr_url set" "$plan" '.chunks[0].pr_url' "https://github.com/o/r/pull/9"
  rm -rf "$(dirname "$plan")"

  # M12: inc-rounds increments tribunal_rounds
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending","tribunal_rounds":0}]')
  bash "$script" inc-rounds "$plan" C1
  bash "$script" inc-rounds "$plan" C1
  assert_json_field "M12: tribunal_rounds=2" "$plan" '.chunks[0].tribunal_rounds' "2"
  rm -rf "$(dirname "$plan")"

  # M13: add-issue appends to filed_issues
  plan=$(mk_plan '[{"id":"C1","depends_on":[],"status":"pending","filed_issues":[]}]')
  bash "$script" add-issue "$plan" C1 "https://github.com/o/r/issues/42"
  assert_json_field "M13: filed_issues count" "$plan" '.chunks[0].filed_issues | length' "1"
  assert_json_field "M13b: filed_issues url" "$plan" '.chunks[0].filed_issues[0]' "https://github.com/o/r/issues/42"
  rm -rf "$(dirname "$plan")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M1[0-3]"`
Expected: FAIL — these subcommands hit the `*)` catch-all (exit 1), so fields are unchanged.

- [ ] **Step 3: Implement the four mutation cases**

Add these cases to the `case "$CMD" in` block in `goal-chunks.sh` (before `*)`):

```bash
  set-status)
    ID="${3:?id required}"; STATUS="${4:?status required}"
    write_back --arg id "$ID" --arg st "$STATUS" \
      '(.chunks[] | select(.id==$id) | .status) = $st'
    ;;
  set-field)
    ID="${3:?id required}"; FIELD="${4:?field required}"; VALUE="${5:?value required}"
    write_back --arg id "$ID" --arg f "$FIELD" --arg v "$VALUE" \
      '(.chunks[] | select(.id==$id) | .[$f]) = $v'
    ;;
  inc-rounds)
    ID="${3:?id required}"
    write_back --arg id "$ID" \
      '(.chunks[] | select(.id==$id) | .tribunal_rounds) += 1'
    ;;
  add-issue)
    ID="${3:?id required}"; URL="${4:?url required}"
    write_back --arg id "$ID" --arg u "$URL" \
      '(.chunks[] | select(.id==$id) | .filed_issues) += [$u]'
    ;;
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M1[0-3]|FAIL"`
Expected: `M10`–`M13` PASS; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/goal-chunks.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): goal-chunks.sh set-status/set-field/inc-rounds/add-issue"
```

---

## Task 5: `goal-chunks.sh block-dependents` — transitive blocking

**Files:**
- Modify: `plugins/saas-startup-team/scripts/goal-chunks.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_goal_chunks`)

- [ ] **Step 1: Write the failing test (append to `test_goal_chunks`)**

Append before the closing `}` of `test_goal_chunks`:

```bash
  # M14: block-dependents marks root blocked and transitive dependents skipped
  #   C1 <- C2 <- C3  (C3 depends on C2 depends on C1); C4 independent
  plan=$(mk_plan '[
    {"id":"C1","depends_on":[],"status":"in-progress","skip_reason":null},
    {"id":"C2","depends_on":["C1"],"status":"pending","skip_reason":null},
    {"id":"C3","depends_on":["C2"],"status":"pending","skip_reason":null},
    {"id":"C4","depends_on":[],"status":"pending","skip_reason":null}]')
  bash "$script" block-dependents "$plan" C1 "tribunal cap hit"
  assert_json_valid "M14: still valid JSON" "$plan"
  assert_json_field "M14a: C1 blocked" "$plan" '.chunks[] | select(.id=="C1") | .status' "blocked"
  assert_json_field "M14b: C1 reason" "$plan" '.chunks[] | select(.id=="C1") | .skip_reason' "tribunal cap hit"
  assert_json_field "M14c: C2 skipped (direct dep)" "$plan" '.chunks[] | select(.id=="C2") | .status' "skipped"
  assert_json_field "M14d: C3 skipped (transitive dep)" "$plan" '.chunks[] | select(.id=="C3") | .status' "skipped"
  assert_json_field "M14e: C4 untouched" "$plan" '.chunks[] | select(.id=="C4") | .status' "pending"
  rm -rf "$(dirname "$plan")"

  # M15: block-dependents on a leaf only blocks the leaf
  plan=$(mk_plan '[
    {"id":"C1","depends_on":[],"status":"merged","skip_reason":null},
    {"id":"C2","depends_on":["C1"],"status":"in-progress","skip_reason":null}]')
  bash "$script" block-dependents "$plan" C2 "stuck"
  assert_json_field "M15a: C2 blocked" "$plan" '.chunks[] | select(.id=="C2") | .status' "blocked"
  assert_json_field "M15b: C1 untouched (merged)" "$plan" '.chunks[] | select(.id=="C1") | .status' "merged"
  rm -rf "$(dirname "$plan")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M1[45]"`
Expected: FAIL — `block-dependents` hits the catch-all, statuses unchanged.

- [ ] **Step 3: Implement `block-dependents`**

Add this case to the `case "$CMD" in` block in `goal-chunks.sh` (before `*)`):

```bash
  block-dependents)
    ID="${3:?id required}"; REASON="${4:-blocked}"
    # Build the transitive set of chunks that (directly or indirectly) depend on ID.
    closure="$ID"
    while : ; do
      setjson=$(printf '%s\n' "$closure" | jq -R . | jq -cs .)
      adds=$(jq -r --argjson set "$setjson" '
        .chunks[]
        | select([ .depends_on[] | ($set | index(.)) ] | any)
        | .id' "$PLAN")
      added=0
      while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        if ! printf '%s\n' "$closure" | grep -qxF "$cid"; then
          closure="$closure"$'\n'"$cid"
          added=1
        fi
      done <<< "$adds"
      [ "$added" -eq 0 ] && break
    done
    setjson=$(printf '%s\n' "$closure" | jq -R . | jq -cs .)
    write_back --arg id "$ID" --argjson set "$setjson" --arg reason "$REASON" '
      .chunks |= map(
        if .id == $id then (.status = "blocked" | .skip_reason = $reason)
        elif ($set | index(.id)) then (.status = "skipped" | .skip_reason = ("blocked by " + $id))
        else . end )'
    ;;
```

Note: `any` over an empty `depends_on` is `false`, so independent chunks are never added to the closure. `grep -qxF` does a whole-line fixed-string match to test membership.

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M1[45]|FAIL"`
Expected: `M14*`, `M15*` PASS; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/goal-chunks.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): goal-chunks.sh block-dependents (transitive skip)"
```

---

## Task 6: `goal-chunks.sh summary` — counts for the final report

**Files:**
- Modify: `plugins/saas-startup-team/scripts/goal-chunks.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_goal_chunks`)

- [ ] **Step 1: Write the failing test (append to `test_goal_chunks`)**

Append before the closing `}` of `test_goal_chunks`:

```bash
  # M16: summary reports status counts and deploy status
  plan=$(mk_plan '[
    {"id":"C1","depends_on":[],"status":"merged"},
    {"id":"C2","depends_on":[],"status":"merged"},
    {"id":"C3","depends_on":[],"status":"blocked"},
    {"id":"C4","depends_on":[],"status":"skipped"},
    {"id":"C5","depends_on":[],"status":"pending"},
    {"id":"C6","depends_on":[],"status":"in-progress"}]')
  ec=0; output=$(bash "$script" summary "$plan" 2>&1) || ec=$?
  assert_exit_code "M16: summary exits 0" "$ec" 0
  assert_output_contains "M16a: merged=2" "$output" "merged=2"
  assert_output_contains "M16b: blocked=1" "$output" "blocked=1"
  assert_output_contains "M16c: skipped=1" "$output" "skipped=1"
  assert_output_contains "M16d: pending=1" "$output" "pending=1"
  assert_output_contains "M16e: in_progress=1" "$output" "in_progress=1"
  assert_output_contains "M16f: deploy=pending" "$output" "deploy=pending"
  rm -rf "$(dirname "$plan")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M16"`
Expected: FAIL — `summary` hits the catch-all (exit 1), no count output.

- [ ] **Step 3: Implement `summary`**

Add this case to the `case "$CMD" in` block in `goal-chunks.sh` (before `*)`):

```bash
  summary)
    jq -r '
      (.chunks // []) as $c
      | "merged=\([ $c[] | select(.status=="merged") ] | length) "
      + "blocked=\([ $c[] | select(.status=="blocked") ] | length) "
      + "skipped=\([ $c[] | select(.status=="skipped") ] | length) "
      + "pending=\([ $c[] | select(.status=="pending") ] | length) "
      + "in_progress=\([ $c[] | select(.status=="in-progress") ] | length) "
      + "deploy=\(.deploy.status // "n/a")"' "$PLAN"
    ;;
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "M16|FAIL"`
Expected: `M16*` PASS; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/goal-chunks.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): goal-chunks.sh summary (final-report counts)"
```

---

## Task 7: `commands/goal-deliver.md` — the orchestrator prompt

**Files:**
- Create: `plugins/saas-startup-team/commands/goal-deliver.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (add Suite N `test_goal_deliver_command`, register in `main()`)

- [ ] **Step 1: Write the failing cross-file consistency test**

Add this suite to `tests/run-tests.sh` before `main "$@"` (after `test_goal_chunks`):

```bash
# ---------------------------------------------------------------------------
# Suite N: /goal-deliver command file
# ---------------------------------------------------------------------------

test_goal_deliver_command() {
  echo -e "\n${CYAN}Suite N: /goal-deliver command${NC}"
  local cmd="$PLUGIN_ROOT/commands/goal-deliver.md"

  assert_file_exists "N1: goal-deliver.md exists" "$cmd"
  assert_file_contains "N2: has name frontmatter" "$cmd" "^name: goal-deliver"
  assert_file_contains "N3: user_invocable" "$cmd" "user_invocable: true"
  # Reuses /improve per chunk
  assert_file_contains "N4: references /improve flow" "$cmd" "/improve"
  # Hard dependency on tribunal-review
  assert_file_contains "N5: references tribunal-loop" "$cmd" "tribunal-loop"
  assert_file_contains "N6: references closing-tribunal-loop" "$cmd" "closing-tribunal-loop"
  # Resets active_role like other non-/startup commands (H12-style guard)
  assert_file_contains "N7: resets active_role" "$cmd" '.active_role ='
  # Uses the helper scripts
  assert_file_contains "N8: invokes goal-input.sh" "$cmd" "goal-input.sh"
  assert_file_contains "N9: invokes goal-chunks.sh" "$cmd" "goal-chunks.sh"
  # State + deploy
  assert_file_contains "N10: writes plan.json under .startup/goals" "$cmd" ".startup/goals/"
  assert_file_contains "N11: monitors GitHub Actions deploy" "$cmd" "gh run"
  # Never writes team-lead (H16-style guard)
  assert_file_contains "N12: warns against team-lead active_role" "$cmd" 'team-lead'
}
```

Register in `main()` after `test_goal_chunks`:

```bash
  test_goal_chunks
  test_goal_deliver_command
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -A2 "Suite N"`
Expected: FAIL — `N1: goal-deliver.md exists (file not found ...)`.

- [ ] **Step 3: Write the command file**

Create `plugins/saas-startup-team/commands/goal-deliver.md` with this exact content:

````markdown
---
name: goal-deliver
description: Autonomously deliver a set of tasks (GitHub issues, a milestone, a markdown spec, or free text) end-to-end — plan and chunk the work, ship each chunk via the /improve flow + closing tribunal loop + merge to main, then monitor and auto-fix the GitHub Actions deploy. No human in the loop. Usage: /goal-deliver #12 #15 #20 | --milestone v2 | docs/roadmap.md | <free text>
user_invocable: true
---

# /goal-deliver — Autonomous Multi-Chunk Goal Orchestrator

You are the **Team Lead** (orchestrator). The human is a **silent investor**.
`/goal-deliver` takes a set of tasks, autonomously plans and chunks them,
reviews its own plan (no human gate), then ships each chunk through the
`/improve` flow → closing tribunal loop → merge to main, respecting a chunk
dependency graph. After the final merge it monitors the GitHub Actions deploy
and auto-fixes failures. **There is no human in the loop** — the only
human-facing output is the final report.

The build cycle is reused from `/improve`: for each chunk you follow the
documented `/improve` flow (`${CLAUDE_PLUGIN_ROOT}/commands/improve.md`). The
tribunal gate is provided by the `tribunal-review` plugin (hard dependency).

## Pre-Flight (all gates must pass)

1. **tribunal-review installed.** Confirm the `tribunal-review:tribunal-loop`
   skill is available. If not:
   > `/goal-deliver` requires the `tribunal-review` plugin (the tribunal gate is
   > non-negotiable). Install it, then re-run.
   Stop.

2. **`.startup/` and solution signoff exist:**
   ```bash
   ls .startup/go-live/solution-signoff.md 2>/dev/null
   ```
   If not found:
   > The build loop hasn't completed yet. Use `/startup` first. `/goal-deliver`
   > delivers new work onto a finished product, like `/improve`.
   Stop.

3. **Architecture doc exists:**
   ```bash
   ls docs/architecture/architecture.md 2>/dev/null
   ```
   If not found, stop and tell the investor the tech founder needs it.

4. **Working tree clean:**
   ```bash
   git status --porcelain
   ```
   If not clean, stop and ask the investor to commit or stash.

5. **On the default branch:**
   ```bash
   current=$(git rev-parse --abbrev-ref HEAD)
   default=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
   ```
   If `current != default`, stop and ask the investor to switch to `${default}`.

6. **`gh` authenticated with a remote:**
   ```bash
   gh auth status >/dev/null 2>&1 && git remote get-url origin >/dev/null 2>&1
   ```
   If either fails, stop and report.

## Step 1: Classify Input

If the user gave no arguments, ask:
> What should I deliver? Give me GitHub issues (`#12 #15`), `--milestone <name>`,
> a markdown spec path, or describe the features.

Classify the arguments:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-input.sh" detect <the command arguments>
```
This prints `{"type":..., "refs":[...]}`. Based on `type`:
- **issues** — fetch each: `gh issue view <n> --json title,body`. Build the task spec from titles + bodies. Keep issue numbers for closing on merge.
- **milestone** — `gh issue list --milestone "<name>" --state open --json number,title,body`. Use all as the task set, keeping numbers.
- **file** — read the file at `refs[0]`; it is the task spec.
- **freetext** — `refs[0]` is the natural-language task spec.

Derive a `goal_slug` (lowercase, hyphens): for issues `issues-12-15-20`, for a
milestone the slug of its name, for a file its basename without extension, for
free text a short slug of the text.

## Step 2: Resume Check

```bash
ls ".startup/goals/${goal_slug}/plan.json" 2>/dev/null
```
If it exists, this is a resumed run: read it, report current `summary`
(`goal-chunks.sh summary`), and skip to **Step 5** to continue from the first
non-`merged` chunk. Otherwise continue to Step 3.

## Step 3: Reset active_role

`/goal-deliver` is never a team-lead context. Clear any stale value so the
`enforce-delegation` hook does not block this flow's subagents. **Never write
`active_role: "team-lead"`.**

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "business-founder-maintain"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

## Step 4: Plan + Autonomous Review (two passes)

### Pass 1 — Business founder drafts the chunk plan

Spawn the business founder via Agent tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder-maintain.md` for your
> identity and tools.
>
> **Planning task: decompose this goal into PR-sized chunks with a dependency
> graph.**
>
> The goal (task spec): [paste the normalized task spec]
>
> Read `docs/architecture/architecture.md`, `docs/business/brief.md`, relevant
> `docs/research/`, and `docs/legal/`.
>
> First, evaluate the goal against your research and legal findings. Push back
> (cite specific docs) on anything that conflicts with legal compliance,
> undermines strategy, or risks sales/conversion. Drop any rejected work item
> and record why.
>
> Then break the remaining work into chunks. Each chunk is one coherent,
> PR-sized unit (~15–30 min of implementation). For each chunk, list the chunk
> IDs it depends on (work that must merge first). Output the chunk list as JSON
> matching this shape (status always starts "pending"):
> `{"id":"C1","title":"...","description":"<self-contained brief for /improve>","issue_refs":[...],"depends_on":[],"status":"pending","pr_url":null,"branch":null,"tribunal_rounds":0,"filed_issues":[],"skip_reason":null}`

Relay any push-back to the investor as information (do not wait — autonomous),
then proceed with the surviving chunks.

### Pass 2 — Tech founder reviews and finalizes

Spawn the tech founder via Agent tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder-maintain.md` for your identity
> and tools.
>
> **Plan review task: validate feasibility and dependency correctness.**
>
> Here is the draft chunk plan: [paste Pass 1 chunk JSON]
> Read `docs/architecture/architecture.md`.
>
> Check: is each chunk implementable as scoped? Are the `depends_on` edges
> correct — any missing edge that would cause merge conflicts or a broken build,
> any unnecessary edge that serializes independent work? Return the corrected
> chunk JSON array.

### Write and validate the plan

Create the goal directory and write `plan.json`:

```bash
mkdir -p ".startup/goals/${goal_slug}"
```

Write `.startup/goals/${goal_slug}/plan.json` using the finalized chunk array
and the `source`/`goal_slug`/`created`/`deploy` envelope (see the design spec
shape). Also write a human-readable `plan.md` alongside it. Then validate:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" validate ".startup/goals/${goal_slug}/plan.json"
```

If validation fails (duplicate ids, unknown dep, or **dependency cycle**),
re-dispatch the tech founder with the specific error to fix the plan, rewrite
`plan.json`, and re-validate. Do not start execution on an invalid plan.

## Step 5: Per-Chunk Loop

Let `PLAN=".startup/goals/${goal_slug}/plan.json"`. Loop:

```bash
chunk=$("${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" next "$PLAN")
```

While `chunk` is non-empty, process it:

1. **Mark in-progress:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" set-status "$PLAN" "$chunk" in-progress
   ```

2. **Build the chunk via the `/improve` flow.** Follow the documented steps in
   `${CLAUDE_PLUGIN_ROOT}/commands/improve.md` in `new-branch` mode off the
   default branch, using the chunk's `description` as the improvement
   instruction. This runs business founder → tech founder → business-founder QA
   and opens a PR on `improve/<chunk-slug>`. Record the branch and PR URL:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" set-field "$PLAN" "$chunk" branch "improve/<chunk-slug>"
   "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" set-field "$PLAN" "$chunk" pr_url "<pr url>"
   ```

3. **Closing tribunal loop** on the PR branch. Load and follow the
   `tribunal-review:closing-tribunal-loop` skill. Each round:
   - Run `tribunal-review:tribunal-loop`. If the arbiter returns `APPROVE` with
     0 findings → the gate is closed; go to step 4.
   - Otherwise triage each finding:
     - **Critical / service-breaking** → fix in this PR (dispatch the tech
       founder per `/improve`'s fix step), push, then:
       ```bash
       "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" inc-rounds "$PLAN" "$chunk"
       ```
       and re-run tribunal.
     - **Non-critical AND out-of-scope / pre-existing** → file a GitHub issue
       using the closing-tribunal-loop follow-up template, cross-link it to the
       PR, and record it (do not block):
       ```bash
       "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" add-issue "$PLAN" "$chunk" "<issue url>"
       ```
     - **False positive** → reject (verified against the cited code).
   - Stop the round loop when the gate closes, OR when `tribunal_rounds` reaches
     **5**. Read the current count with:
     ```bash
     jq -r --arg id "$chunk" '.chunks[]|select(.id==$id)|.tribunal_rounds' "$PLAN"
     ```

4. **Gate closed (APPROVE + 0 findings):** merge and advance:
   ```bash
   gh pr merge "<pr url>" --squash --delete-branch
   ```
   Close referenced issues (`gh issue close <n> --comment "Delivered in <pr url>"`
   for each `issue_refs`), then:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" set-status "$PLAN" "$chunk" merged
   git checkout "${default}" && git pull --ff-only
   ```

5. **Retry cap hit with unresolved critical findings:** leave the PR open as a
   draft (`gh pr ready --undo "<pr url>"`), then block and skip dependents:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" block-dependents "$PLAN" "$chunk" "tribunal cap (5 rounds) without APPROVE"
   git checkout "${default}"
   ```

6. Re-evaluate `next` and continue until it returns empty.

### Long-running waits

Tribunal rounds and `/improve` dispatches are synchronous. If you ever run a
subagent or watch in the background, use the `ScheduleWakeup` poll pattern
documented in `/startup` (≤270 s delay) so you yield control correctly instead
of thrashing the Stop hook.

## Step 6: Deploy Monitoring

Run only if at least one chunk reached `merged`. Find the GitHub Actions run
triggered by the final merge to the default branch and watch it:

```bash
run_id=$(gh run list --branch "${default}" --limit 1 --json databaseId -q '.[0].databaseId')
jq --arg r "$run_id" '.deploy.run_id = $r | .deploy.status = "monitoring"' \
  "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
gh run watch "$run_id" --exit-status
```

(`gh run watch --exit-status` returns non-zero if the run fails.) The chunk
helpers target `.chunks[]`, so write the `.deploy.*` envelope with `jq` directly
as shown — write-temp-then-rename to match the repo's atomic-write pattern.

- **Success** → set `.deploy.status = "green"`.
- **Failure** → read the failing job logs (`gh run view "$run_id" --log-failed`),
  dispatch the tech founder to fix on a `deploy-fix/<slug>` branch, open a PR,
  run the closing tribunal loop on it, merge, then re-watch the new run. Repeat
  until green or **3** deploy-fix attempts. If the cap is hit, set
  `.deploy.status = "failed"` and record it.

## Step 7: Final Report

Read the counts:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-chunks.sh" summary "$PLAN"
```

Report to the investor (English):
- Chunks **merged** (with PR links).
- Chunks **blocked** / **skipped** (with reasons and draft-PR links).
- GitHub issues **filed** for out-of-scope tribunal findings (with links).
- **Deploy status** (green / failed, with the run link).

## Communication

- Business founder speaks **Estonian** to the investor.
- Tech founder speaks **English** to the investor.
- You (team lead) speak **English** for status updates and the final report.
````

- [ ] **Step 4: Run to verify the suite passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "N[0-9]+|FAIL"`
Expected: all `N*` PASS; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/goal-deliver.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): /goal-deliver orchestrator command"
```

---

## Task 8: Version bump, README, full suite

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `plugins/saas-startup-team/README.md`

- [ ] **Step 1: Bump the version in both manifests (must stay in sync)**

Edit `plugins/saas-startup-team/.claude-plugin/plugin.json`: change `"version": "0.36.0"` → `"version": "0.37.0"`.

Edit `.claude-plugin/marketplace.json`: in the `saas-startup-team` entry, change `"version": "0.36.0"` → `"version": "0.37.0"`.

Verify they match:
```bash
a=$(jq -r '.version' plugins/saas-startup-team/.claude-plugin/plugin.json)
b=$(jq -r '.plugins[]|select(.name=="saas-startup-team")|.version' .claude-plugin/marketplace.json)
echo "plugin=$a marketplace=$b"; [ "$a" = "$b" ] && echo OK || echo MISMATCH
```
Expected: `plugin=0.37.0 marketplace=0.37.0` then `OK`.

- [ ] **Step 2: Document the command in the plugin README**

Read `plugins/saas-startup-team/README.md`, find the command list, and add an entry for `/goal-deliver` matching the existing format, e.g.:

```markdown
- `/goal-deliver` — autonomously deliver a set of tasks (GitHub issues, a milestone, a markdown spec, or free text): plan into dependency-ordered chunks, ship each via `/improve` + closing tribunal loop + merge to main, then monitor and auto-fix the GitHub Actions deploy. No human in the loop. Requires the `tribunal-review` plugin.
```

- [ ] **Step 3: Run the full test suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: final line `All tests passed!`, exit 0. In particular the existing `E3` semver check passes for `0.37.0`, and Suites L, M, N all pass.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/saas-startup-team/README.md
git commit -m "chore(saas-startup-team): v0.37.0 — /goal-deliver command + helpers"
```

---

## Self-Review Notes

- **Spec coverage:** input resolution → Task 1 + command Step 1; pre-flight hard
  gates (tribunal, signoff, arch, clean tree, default branch, gh) → command
  Pre-Flight + Suite N5/N6; two-pass plan review → command Step 4; state file +
  resumability → Tasks 2–6 + command Step 2; per-chunk loop with finding-severity
  triage → command Step 5 + closing-tribunal-loop skill; block-dependents →
  Task 5 + command Step 5.5; deploy monitor + auto-fix → command Step 6; final
  report → Task 6 + command Step 7; versioning → Task 8.
- **Naming consistency:** subcommand names (`validate`, `next`, `set-status`,
  `set-field`, `inc-rounds`, `add-issue`, `block-dependents`, `summary`) are
  identical across the script, the tests, and the command file.
- **Deploy envelope vs chunk helpers:** `goal-chunks.sh` mutators target
  `.chunks[]`; the command writes `.deploy.*` with direct `jq` (called out in
  Step 6) — no helper subcommand pretends to own the deploy envelope.
- **No placeholders:** every code/test step contains runnable content.
````
