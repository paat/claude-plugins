# Generic `/monitor-nightly` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic, project-agnostic `/monitor-nightly` command to the `saas-startup-team` plugin that scans a product for failure signals, files/dedups GitHub issues, and persists state across nightly cron runs.

**Architecture:** Two layers. A markdown command (`commands/monitor-nightly.md`) parses config, sweeps failure markers, runs an optional project custom-checks script, and pipes findings to the engine — **it never calls `gh`**. A deterministic shell engine (`scripts/monitor-dedup.sh`) owns all dedup/state/`gh` I/O (including repo resolution) via two subcommands — `window` (read state → scan window) and `commit` (findings JSONL → file/dedup issues → write state). The seam is a findings JSONL contract.

**Tech Stack:** bash 4+, `jq`, GNU coreutils `date`, GitHub `gh` CLI. Tests are a new `test_monitor_dedup` section in the existing `tests/run-tests.sh` (mocked `gh`).

> **This plan was revised after a Codex adversarial review.** The "Review revisions" section at the end records every accepted/deferred finding.

## Global Constraints

- Plugins must be generic and project-agnostic — no hardcoded company/product/host names; project-specific values come from config or template variables. (Repo CLAUDE.md)
- Must work with bash 4+ and standard POSIX tools; external deps (`jq`, `gh`, GNU `date`, `flock`) documented in README. (Repo CLAUDE.md)
- Bump the version in **both** `plugins/saas-startup-team/.claude-plugin/plugin.json` **and** root `.claude-plugin/marketplace.json`, kept in sync. (Repo CLAUDE.md)
- README must include the three-scope Installation section (already present). (Repo CLAUDE.md)
- **Findings JSONL schema (exact, required keys):** `{"pattern_key","severity","entity","title","body"}` plus optional `"summary"`. `pattern_key` is a string matching `^[a-z0-9][a-z0-9:_-]*$`. `entity` is a string **or** `null`. `severity`/`title`/`body` are strings. Any line that is not parseable, is missing a required key, has a wrong-typed `entity`, or has an invalid `pattern_key` is **malformed** (§ failure semantics).
- **Dedup key:** `(entity, pattern_key)` where a `null` entity is normalized to the empty string `""` (never the literal `"null"`).
- **State schema (exact):** `{"version":1,"last_run_at":<iso|null>,"patterns":{"<pk>":{"gh_issue":<int>,"sessions":[<entity-string|"">...],"first_seen":<iso>,"last_seen":<iso>}}}`.
- Scan window: first run / unreadable state / unparseable `last_run_at` → 1440 min; else minutes since `last_run_at` (floor 1, cap 2880).
- Default config: `marker_dir=.monitor`, `state_file=.startup/monitor-state.json`, `custom_checks=.startup/monitor-checks.sh`, `labels=monitor,customer-issue`. Repo defaults to `gh repo view`'s `nameWithOwner` (resolved inside the engine).
- Every `gh` call passes `--repo "$REPO"`.
- Plugin root is `plugins/saas-startup-team/`. All paths are exact.

---

## File Structure

- **Create** `plugins/saas-startup-team/scripts/monitor-dedup.sh` — the deterministic engine (`window` + `commit`). Owns all state I/O and all `gh` calls (incl. repo resolution).
- **Create** `plugins/saas-startup-team/commands/monitor-nightly.md` — the markdown command (config parse + collection; **no `gh`**).
- **Modify** `plugins/saas-startup-team/tests/run-tests.sh` — add `make_mock_gh`, `assert_file_not_exists`, `test_monitor_dedup`; register in `main()`.
- **Modify** `plugins/saas-startup-team/saas-startup-team.local.md.example` — add the `monitor:` block.
- **Modify** `plugins/saas-startup-team/README.md` — add monitor docs (config table, contracts, cron, deps).
- **Modify** `plugins/saas-startup-team/.claude-plugin/plugin.json` and **Modify** `.claude-plugin/marketplace.json` — version bump.

All work happens on branch `feat/monitor-nightly-51` (already created).

---

## Task 1: Engine scaffold + `window` subcommand

**Files:**
- Create: `plugins/saas-startup-team/scripts/monitor-dedup.sh`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (add `make_mock_gh`, `assert_file_not_exists`, `test_monitor_dedup`, register in `main()`)

**Interfaces:**
- Produces: `monitor-dedup.sh window --state <file>` → prints exactly `MONITOR_SINCE_MINUTES=<int>` then `MONITOR_SINCE=<iso>`, exit 0. Helpers `_die`, `_now_iso`, `_iso_to_epoch`, `_read_state` for later tasks.

- [ ] **Step 1: Add test helpers (mock `gh`, file-absence assert)**

Next to the other `make_mock_*` helpers in `tests/run-tests.sh`:

```bash
# Mock `gh` under $1/bin. Logs argv (one line/call) to $GH_CALLS_LOG. Env knobs:
#   GH_CREATE_NUMBER  number echoed (as URL) by `gh issue create`
#   GH_VIEW_STATE     value for `gh issue view --json state` (OPEN/CLOSED)
#   GH_VIEW_BODY      value for `gh issue view --json body`   (recovery verification)
#   GH_SEARCH_JSON    JSON for `gh issue list ... --json number` (default [])
#   GH_FAIL_ON        if argv contains this substring, exit 1 (simulate gh failure)
make_mock_gh() {
  local bindir="$1/bin"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'MOCK'
#!/usr/bin/env bash
_args="$*"; printf '%s\n' "${_args//$'\n'/ }" >> "${GH_CALLS_LOG:?}"  # one line/call (flatten bodies)
if [ -n "${GH_FAIL_ON:-}" ] && [[ "$*" == *"$GH_FAIL_ON"* ]]; then
  echo "mock gh: forced failure" >&2; exit 1
fi
case "$1 $2" in
  "repo view")   echo "${GH_REPO:-o/r}" ;;
  "issue create") echo "https://github.com/o/r/issues/${GH_CREATE_NUMBER:?GH_CREATE_NUMBER unset}" ;;
  "issue comment") echo "https://github.com/o/r/issues/commented" ;;
  "issue view")
     if [[ "$*" == *"body"* ]]; then echo "${GH_VIEW_BODY:-}"; else echo "${GH_VIEW_STATE:-OPEN}"; fi ;;
  "issue list")  echo "${GH_SEARCH_JSON:-[]}" ;;
  "label create") : ;;
  *) : ;;
esac
MOCK
  chmod +x "$bindir/gh"
}
```

Add `assert_file_not_exists` next to `assert_file_exists`:

```bash
assert_file_not_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly exists: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$label: file exists $path")
  fi
}
```

- [ ] **Step 2: Write the failing `window` tests**

Add `test_monitor_dedup()` (before `main()`), and register it in `main()` right after `test_lawyer_lifecycle`:

```bash
test_monitor_dedup() {
  echo -e "\n${CYAN}Suite W: monitor-dedup.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/monitor-dedup.sh"
  local workdir ec output state mins

  # W1: first run (no state) → 1440-minute window, exit 0
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W1: window first-run exits 0" "$ec" 0
  assert_output_contains "W1: first-run window is 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  # W2: recent last_run_at (30m ago) → window between 1 and 60
  workdir=$(make_workdir); state="$workdir/state.json"
  printf '{"version":1,"last_run_at":"%s","patterns":{}}' "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$state" 2>&1) || ec=$?
  mins=$(printf '%s\n' "$output" | sed -n 's/^MONITOR_SINCE_MINUTES=//p')
  assert_exit_code "W2: window exits 0" "$ec" 0
  assert_equals "W2: ~30m window within (1,60]" "$([ "$mins" -ge 1 ] && [ "$mins" -le 60 ] && echo ok)" "ok"

  # W3: old last_run_at → capped at 2880, exit 0
  workdir=$(make_workdir); state="$workdir/state.json"
  printf '{"version":1,"last_run_at":"%s","patterns":{}}' "$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$state" 2>&1) || ec=$?
  assert_exit_code "W3: window exits 0" "$ec" 0
  assert_output_contains "W3: capped at 2880" "$output" "MONITOR_SINCE_MINUTES=2880"

  # W4: corrupt JSON state → first-run window
  workdir=$(make_workdir); echo 'not json {{{' > "$workdir/state.json"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W4: corrupt state exits 0" "$ec" 0
  assert_output_contains "W4: corrupt → 1440" "$output" "MONITOR_SINCE_MINUTES=1440"

  # W4b: valid JSON but unparseable last_run_at → first-run window (must not crash under set -e)
  workdir=$(make_workdir)
  printf '{"version":1,"last_run_at":"not-a-date","patterns":{}}' > "$workdir/state.json"
  ec=0; output=$(cd "$workdir" && bash "$script" window --state "$workdir/state.json" 2>&1) || ec=$?
  assert_exit_code "W4b: bad timestamp exits 0" "$ec" 0
  assert_output_contains "W4b: bad timestamp → 1440" "$output" "MONITOR_SINCE_MINUTES=1440"
}
```

- [ ] **Step 3: Run to verify failure**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W[1-4]b?:"`
Expected: FAIL — engine does not exist.

- [ ] **Step 4: Write the engine scaffold + `window`**

Create `plugins/saas-startup-team/scripts/monitor-dedup.sh`:

```bash
#!/usr/bin/env bash
# monitor-dedup.sh — deterministic engine for /monitor-nightly. Generic/project-agnostic.
#   window --state <file>
#   commit --state <file> [--repo S] [--labels a,b] [--repro-recipe TPL] [--dry-run]
# Owns ALL state I/O and ALL `gh` calls (including repo resolution).
set -euo pipefail

_die() { echo "monitor-dedup: $*" >&2; exit 1; }
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_iso_to_epoch() { date -u -d "$1" +%s 2>/dev/null; }   # non-fatal: empty on bad input

# Echo a usable state object, or "" if missing/corrupt.
_read_state() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  if jq -e '.version == 1 and (.patterns|type=="object")' "$f" >/dev/null 2>&1; then
    cat "$f"
  else
    echo ""
  fi
}

cmd_window() {
  local state_file="" minutes since now last epoch
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state_file="$2"; shift 2 ;;
      *) _die "window: unknown arg $1" ;;
    esac
  done
  [ -n "$state_file" ] || _die "window: --state required"
  local state; state="$(_read_state "$state_file")"
  last="$(printf '%s' "$state" | jq -r '.last_run_at // empty' 2>/dev/null || true)"
  now="$(date -u +%s)"
  epoch=""
  if [ -n "$last" ] && [ "$last" != "null" ]; then epoch="$(_iso_to_epoch "$last" || true)"; fi
  if [ -z "$epoch" ]; then
    minutes=1440
  else
    minutes=$(( ( now - epoch ) / 60 ))
    [ "$minutes" -lt 1 ] && minutes=1
    [ "$minutes" -gt 2880 ] && minutes=2880
  fi
  since="$(date -u -d "@$(( now - minutes * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
  echo "MONITOR_SINCE_MINUTES=$minutes"
  echo "MONITOR_SINCE=$since"
}

# cmd_commit added in Task 2; stub keeps the dispatcher honest under set -u.
cmd_commit() { _die "commit: not yet implemented"; }

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    window) cmd_window "$@" ;;
    commit) cmd_commit "$@" ;;
    *) _die "usage: monitor-dedup.sh {window|commit} ..." ;;
  esac
}
main "$@"
```

```bash
chmod +x plugins/saas-startup-team/scripts/monitor-dedup.sh
```

- [ ] **Step 5: Run to verify passing**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W[1-4]b?:"`
Expected: W1–W4b PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/scripts/monitor-dedup.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): monitor-dedup engine scaffold + window (#51)"
```

---

## Task 2: `commit` — validation + dedup ladder (create/skip/comment) + state write

**Files:**
- Modify: `plugins/saas-startup-team/scripts/monitor-dedup.sh` (replace `cmd_commit` stub + helpers)
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (W5–W9b)

**Interfaces:**
- Consumes: `_die`,`_now_iso`,`_read_state` (Task 1).
- Produces: `commit --state <file> [--repo S] [--labels a,b] [--repro-recipe TPL] [--dry-run]`. Reads findings JSONL on stdin; prints one action object per finding via `jq -nc` (`{action:create|comment|skip|malformed|error, pattern_key, entity, issue}`); writes state atomically; resolves repo via `gh repo view` when `--repo` omitted; advances `last_run_at` only if zero failures; exit non-zero on any failure. Helpers `_gh`, `_label_color`, `_ensure_labels`, `_new_body`, `_validate`, `_write_state`.

- [ ] **Step 1: Write failing tests (core ladder)**

Append to `test_monitor_dedup()`:

```bash
  local L  # gh calls log path, per-test

  # W5: new pattern → CREATE; --repo present on every gh call; state records issue
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-1","title":"[Monitor] err","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=142 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W5: create exits 0" "$ec" 0
  assert_output_contains "W5: action create" "$output" '"action":"create"'
  assert_file_contains "W5: gh issue create called" "$L" "issue create"
  assert_equals "W5: every gh call carries --repo" "$(grep -c -- '--repo o/r' "$L")" "$(wc -l < "$L" | tr -d ' ')"
  assert_equals "W5: state records 142" "$(jq -c '.patterns["pipeline:err:categorize"].gh_issue' "$state")" "142"

  # W6: same (entity,pattern) in state → SKIP, NO gh calls at all
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W6: action skip" "$output" '"action":"skip"'
  # reconciliation may `gh issue view` to confirm the stored issue is still open, but
  # an already-seen (entity,pattern) must never create or comment.
  assert_file_not_contains "W6: no create" "$L" "issue create"
  assert_file_not_contains "W6: no comment" "$L" "issue comment"

  # W7: known pattern, NEW entity → COMMENT; entity appended (sessions length 2)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:err:categorize","severity":"high","entity":"S-2","title":"T","body":"B","summary":"recurred"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W7: action comment" "$output" '"action":"comment"'
  assert_file_contains "W7: commented on 142" "$L" "issue comment 142"
  assert_equals "W7: 2 sessions" "$(jq -c '.patterns["pipeline:err:categorize"].sessions|length' "$state")" "2"

  # W8: same entity, DIFFERENT pattern → CREATE (not collapsed)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"pipeline:err:categorize":{"gh_issue":142,"sessions":["S-1"],"first_seen":"2026-06-19T00:00:00Z","last_seen":"2026-06-19T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"pipeline:timeout:narrative","severity":"high","entity":"S-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=143 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W8: action create" "$output" '"action":"create"'
  assert_output_not_contains "W8: not a comment" "$output" '"action":"comment"'
  assert_equals "W8: new pattern stored" "$(jq -c '.patterns["pipeline:timeout:narrative"].gh_issue' "$state")" "143"

  # W9: two findings, same pattern, different entity, ONE run → 1 create + 1 comment, both entities stored
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n%s\n' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' \
    '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=150 GH_VIEW_STATE=OPEN \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_equals "W9: one create" "$(grep -c 'issue create' "$L")" "1"
  assert_equals "W9: one comment" "$(grep -c 'issue comment' "$L")" "1"
  assert_equals "W9: both entities stored" "$(jq -c '.patterns["payment:stuck"].sessions|length' "$state")" "2"

  # W9b: empty stdin → exit 0, state initialized, last_run_at advanced (non-null)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r < /dev/null 2>&1) || ec=$?
  assert_exit_code "W9b: empty stdin exits 0" "$ec" 0
  assert_file_exists "W9b: state written" "$state"
  assert_output_not_contains "W9b: last_run_at advanced" "$(jq -r '.last_run_at' "$state")" "null"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W[5-9]b?:"`
Expected: FAIL — `cmd_commit` is the stub.

- [ ] **Step 3: Implement `cmd_commit` + helpers**

Replace the `cmd_commit` stub in `monitor-dedup.sh` with the helpers and full implementation. Module vars go above `cmd_window`:

```bash
REPO=""; DRY_RUN=0; LABELS="monitor,customer-issue"; REPRO_RECIPE=""

_gh() {
  if [ "$DRY_RUN" = 1 ]; then echo "[DRY RUN] gh $*" >&2; return 0; fi
  gh "$@" --repo "$REPO"
}
_label_color() {
  case "$1" in
    monitor) echo "0E8A16" ;; customer-issue) echo "D93F0B" ;;
    high) echo "B60205" ;; medium) echo "FBCA04" ;; low) echo "0075CA" ;;
    *) echo "ededed" ;;
  esac
}
_ensure_labels() {  # never fatal — a label failure must not stop filing
  local l
  for l in "$@"; do
    [ -n "$l" ] || continue
    _gh label create "$l" --color "$(_label_color "$l")" --description "monitor" --force >/dev/null 2>&1 \
      || echo "monitor-dedup: WARNING could not ensure label '$l'" >&2
  done
}
_new_body() {  # args: body pattern_key entity   (entity "" means none)
  local body="$1" pk="$2" ent="$3"
  printf '%s\n\n**Pattern:** `%s`\n' "$body" "$pk"
  if [ -n "$ent" ]; then
    printf '**Entity:** `%s`\n' "$ent"
    [ -n "$REPRO_RECIPE" ] && printf '\n### Reproduction\n```\n%s\n```\n' "${REPRO_RECIPE//\{entity\}/$ent}"
  fi
  printf '\n*Fixing this requires a regression test (or an explicit `Regression-Test: none — <reason>` override), per the regression-test gate.*\n'
}
# Echo the validated finding as ONE compact JSON line, or empty if malformed.
_validate() {  # arg: raw line
  printf '%s' "$1" | jq -c '
    select(
      (.pattern_key|type=="string") and (.pattern_key|test("^[a-z0-9][a-z0-9:_-]*$")) and
      (.severity|type=="string") and (.title|type=="string") and (.body|type=="string") and
      (has("entity")) and (.entity == null or (.entity|type=="string"))
    )' 2>/dev/null | head -1 || true
}
_write_state() {  # atomic, same-dir temp, inline cleanup (no RETURN trap)
  local f="$1" content="$2" dir tmp
  [ "$DRY_RUN" = 1 ] && return 0
  dir="$(dirname "$f")"; mkdir -p "$dir"
  tmp="$(mktemp "$dir/.monitor-state.XXXXXX")"
  if printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$f"; then :; else rm -f "$tmp"; return 1; fi
}
```

Then the command itself (replacing the stub). Tasks 3 and 4 insert blocks marked with the comments shown:

```bash
cmd_commit() {
  local state_file="" failed=0; local malformed=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --state)        state_file="$2"; shift 2 ;;
      --repo)         REPO="$2"; shift 2 ;;
      --labels)       LABELS="$2"; shift 2 ;;
      --repro-recipe) REPRO_RECIPE="$2"; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      *) _die "commit: unknown arg $1" ;;
    esac
  done
  [ -n "$state_file" ] || _die "commit: --state required"
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO" ] || _die "commit: could not resolve repo (set monitor.repo)"
  fi

  local state; state="$(_read_state "$state_file")"
  [ -n "$state" ] || state='{"version":1,"last_run_at":null,"patterns":{}}'

  local raw f pk sev ent title body summary
  while IFS= read -r raw || [ -n "$raw" ]; do
    [ -z "$raw" ] && continue
    f="$(_validate "$raw")"
    if [ -z "$f" ]; then failed=1; malformed+=("$raw"); echo '{"action":"malformed"}'; continue; fi
    pk="$(printf '%s' "$f"      | jq -r '.pattern_key')"
    sev="$(printf '%s' "$f"     | jq -r '.severity')"
    ent="$(printf '%s' "$f"     | jq -r '.entity // ""')"     # null → ""
    title="$(printf '%s' "$f"   | jq -r '.title')"
    body="$(printf '%s' "$f"    | jq -r '.body')"
    summary="$(printf '%s' "$f" | jq -r '.summary // .title')"

    # === Task 3 inserts: closed-issue reconciliation (drop stale CLOSED mapping) ===

    if printf '%s' "$state" | jq -e --arg k "$pk" '.patterns|has($k)' >/dev/null; then
      local issue seen
      issue="$(printf '%s' "$state" | jq -r --arg k "$pk" '.patterns[$k].gh_issue')"
      seen="$(printf '%s' "$state" | jq -r --arg k "$pk" --arg e "$ent" '(.patterns[$k].sessions // [])|index($e)|tostring')"
      if [ "$seen" != "null" ]; then
        printf '%s' "$f" | jq -nc --arg pk "$pk" --arg e "$ent" --argjson i "$issue" '{action:"skip",pattern_key:$pk,entity:$e,issue:$i}'
        continue
      fi
      if _gh issue comment "$issue" --body "Recurrence ($(_now_iso)): $summary"; then
        state="$(printf '%s' "$state" | jq --arg k "$pk" --arg e "$ent" --arg ts "$(_now_iso)" '.patterns[$k].sessions += [$e] | .patterns[$k].last_seen=$ts')"
        jq -nc --arg pk "$pk" --arg e "$ent" --argjson i "$issue" '{action:"comment",pattern_key:$pk,entity:$e,issue:$i}'
      else
        failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'
      fi
      continue
    fi

    # === Task 3 inserts: state-loss recovery search (adopt verified existing issue) ===

    # --- CREATE ---
    local _lbls; IFS=',' read -ra _lbls <<< "$LABELS"
    _ensure_labels "${_lbls[@]}" "$sev"
    if [ "$DRY_RUN" = 1 ]; then
      _gh issue create --title "$title" --label "$LABELS,$sev" --body "x" >/dev/null 2>&1 || true
      jq -nc --arg pk "$pk" --arg e "$ent" '{action:"create",pattern_key:$pk,entity:$e,issue:null}'
      continue
    fi
    local out num
    if out="$(_gh issue create --title "$title" --label "$LABELS,$sev" --body "$(_new_body "$body" "$pk" "$ent")")"; then
      num="$(printf '%s' "$out" | grep -oE '[0-9]+$' | tail -1)"
      if [ -z "$num" ] || [ "$num" = 0 ]; then
        failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'; continue
      fi
      state="$(printf '%s' "$state" | jq --arg k "$pk" --argjson n "$num" --arg e "$ent" --arg ts "$(_now_iso)" '.patterns[$k]={gh_issue:$n,sessions:[$e],first_seen:$ts,last_seen:$ts}')"
      jq -nc --arg pk "$pk" --arg e "$ent" --argjson n "$num" '{action:"create",pattern_key:$pk,entity:$e,issue:$n}'
    else
      failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'
    fi
  done

  # === Task 4 inserts: file one ops:monitor-input:malformed issue if malformed[] non-empty ===

  if [ "$failed" = 0 ]; then
    state="$(printf '%s' "$state" | jq --arg ts "$(_now_iso)" '.last_run_at=$ts')"
  fi
  _write_state "$state_file" "$state"
  [ "$failed" = 0 ]
}
```

- [ ] **Step 4: Run to verify passing**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W[5-9]b?:"`
Expected: W5–W9b PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/monitor-dedup.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): monitor commit dedup ladder + validation + repo resolution (#51)"
```

---

## Task 3: Closed-issue reconciliation + verified state-loss recovery

**Files:**
- Modify: `plugins/saas-startup-team/scripts/monitor-dedup.sh` (fill the two Task-3 insert points)
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (W10–W11b)

**Interfaces:**
- Consumes: `_gh`, `_now_iso`, state object, validated finding fields (Task 2).
- Produces: `_issue_open(num)` (echo yes/no; **`gh` failure → yes**, i.e. conservative keep-mapping; cached per run); `_recover_issue(pk, ent)` (echo a verified existing open issue number or empty — verifies the candidate's body embeds the `**Pattern:**` and, when entity non-null, `**Entity:**` markers).

- [ ] **Step 1: Write failing tests**

Append to `test_monitor_dedup()`:

```bash
  # W10: stored issue CLOSED → CREATE fresh (sessions fixture uses "" for null entity)
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:llm-gap:failure":{"gh_issue":99,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"ops:llm-gap:failure","severity":"high","entity":null,"title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=CLOSED GH_CREATE_NUMBER=200 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W10: closed → create" "$output" '"action":"create"'
  assert_equals "W10: now issue 200" "$(jq -c '.patterns["ops:llm-gap:failure"].gh_issue' "$state")" "200"

  # W10b: stored issue, gh view FAILS → conservative: treat as OPEN → COMMENT, not create
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{"ops:llm-gap:failure":{"gh_issue":99,"sessions":[""],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"ops:llm-gap:failure","severity":"high","entity":"E-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue view" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W10b: view-fail → comment" "$output" '"action":"comment"'
  assert_file_not_contains "W10b: no duplicate create" "$L" "issue create"

  # W11: lost state, an existing open issue whose body embeds the markers → adopt/COMMENT
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:failed","severity":"high","entity":"P-9","title":"T","body":"B","summary":"again"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    GH_SEARCH_JSON='[{"number":321}]' GH_VIEW_BODY='**Pattern:** `payment:failed`
**Entity:** `P-9`' \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W11: recovered → comment" "$output" '"action":"comment"'
  assert_file_contains "W11: commented on 321" "$L" "issue comment 321"
  assert_file_not_contains "W11: no duplicate create" "$L" "issue create"

  # W11b: search hit but body lacks the entity marker → do NOT adopt → CREATE
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:failed","severity":"high","entity":"P-9","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=500 \
    GH_SEARCH_JSON='[{"number":777}]' GH_VIEW_BODY='**Pattern:** `payment:failed`
**Entity:** `SOMEONE-ELSE`' \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W11b: mismatch → create" "$output" '"action":"create"'
  assert_file_not_contains "W11b: did not comment on 777" "$L" "issue comment 777"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W1[01]b?:"`
Expected: W10 FAIL (no reconciliation → comments on closed), W10b FAIL, W11/W11b FAIL (no recovery).

- [ ] **Step 3: Implement reconciliation + recovery**

Add helpers above `cmd_commit` (declare the cache with the module vars):

```bash
declare -A ISSUE_STATE_CACHE
_issue_open() {  # echo yes/no; gh failure or UNKNOWN → yes (conservative: keep mapping)
  local num="$1" st
  if [ -z "${ISSUE_STATE_CACHE[$num]:-}" ]; then
    st="$(_gh issue view "$num" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    ISSUE_STATE_CACHE[$num]="$st"
  fi
  [ "${ISSUE_STATE_CACHE[$num]}" = "CLOSED" ] && echo no || echo yes
}
# Echo a VERIFIED existing open issue number for (pk,ent), or empty. Checks EVERY
# search hit's body for the embedded markers (not just the first result).
_recover_issue() {  # args: pattern_key entity("" if none)
  local pk="$1" ent="$2" q="$pk" json nums n vbody
  [ -n "$ent" ] && q="$pk $ent"
  json="$(_gh issue list --state open --search "$q" --json number -q '.' 2>/dev/null || echo '[]')"
  nums="$(printf '%s' "$json" | jq -r 'if type=="array" then .[].number else empty end' 2>/dev/null || true)"
  for n in $nums; do
    vbody="$(_gh issue view "$n" --json body -q .body 2>/dev/null || echo "")"
    printf '%s' "$vbody" | grep -qF "**Pattern:** \`$pk\`" || continue
    if [ -n "$ent" ]; then printf '%s' "$vbody" | grep -qF "**Entity:** \`$ent\`" || continue; fi
    echo "$n"; return
  done
  echo ""
}
```

Fill the first Task-3 insert point (closed-issue reconciliation), placed immediately after `summary=...` and before the `if ... has($k)` block:

```bash
    if printf '%s' "$state" | jq -e --arg k "$pk" '.patterns|has($k)' >/dev/null; then
      local cur_issue; cur_issue="$(printf '%s' "$state" | jq -r --arg k "$pk" '.patterns[$k].gh_issue')"
      if [ "$(_issue_open "$cur_issue")" = no ]; then
        state="$(printf '%s' "$state" | jq --arg k "$pk" 'del(.patterns[$k])')"
      fi
    fi
```

Fill the second Task-3 insert point (recovery), placed immediately before `# --- CREATE ---`:

```bash
    local rec; rec="$(_recover_issue "$pk" "$ent")"
    if [ -n "$rec" ]; then
      if _gh issue comment "$rec" --body "Recurrence ($(_now_iso)): $summary"; then
        state="$(printf '%s' "$state" | jq --arg k "$pk" --argjson n "$rec" --arg e "$ent" --arg ts "$(_now_iso)" '.patterns[$k]={gh_issue:$n,sessions:[$e],first_seen:$ts,last_seen:$ts}')"
        jq -nc --arg pk "$pk" --arg e "$ent" --argjson i "$rec" '{action:"comment",pattern_key:$pk,entity:$e,issue:$i}'
      else
        failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'
      fi
      continue
    fi
```

- [ ] **Step 4: Run to verify passing**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W1[01]b?:"`
Expected: W10, W10b, W11, W11b PASS. Re-run W5–W9b to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/monitor-dedup.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): closed-issue reconciliation + verified recovery search (#51)"
```

---

## Task 4: Failure semantics — malformed input, gh failure, dry-run

**Files:**
- Modify: `plugins/saas-startup-team/scripts/monitor-dedup.sh` (fill the Task-4 insert point)
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (W12–W15c)

**Interfaces:**
- Consumes: `_validate`, `_ensure_labels`, `_new_body`, `malformed[]`, `failed` (Task 2).
- Produces: one `ops:monitor-input:malformed` issue per run when any line is malformed; `commit` exits non-zero and leaves `last_run_at` unchanged on any failure; `--dry-run` performs zero `gh` mutations and writes no state.

- [ ] **Step 1: Write failing tests**

Append to `test_monitor_dedup()`:

```bash
  # W12: malformed line → tracking issue + non-zero + window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n' 'this is not json' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=400 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W12: malformed → non-zero" "$ec" 1
  assert_file_contains "W12: monitor-input:malformed filed" "$L" "monitor-input:malformed"
  assert_equals "W12: window unchanged" "$(jq -r '.last_run_at' "$state")" "2026-06-01T00:00:00Z"

  # W12b: multiple malformed lines → exactly ONE tracking issue
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n%s\n' 'garbage one' 'garbage two' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=401 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_equals "W12b: one malformed issue" "$(grep -c 'monitor-input:malformed' "$L")" "1"

  # W13: gh create fails → not in state, non-zero, window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_FAIL_ON="issue create" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W13: gh fail → non-zero" "$ec" 1
  assert_equals "W13: not in state" "$(jq -c '.patterns["payment:stuck"] // "absent"' "$state")" '"absent"'
  assert_equals "W13: window unchanged" "$(jq -r '.last_run_at' "$state")" "2026-06-01T00:00:00Z"

  # W13b: comment fails on known new entity → non-zero, entity NOT appended, window unchanged
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":"2026-06-01T00:00:00Z","patterns":{"payment:stuck":{"gh_issue":50,"sessions":["P-1"],"first_seen":"2026-06-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-2","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_VIEW_STATE=OPEN GH_FAIL_ON="issue comment" \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W13b: comment fail → non-zero" "$ec" 1
  assert_equals "W13b: entity not appended" "$(jq -c '.patterns["payment:stuck"].sessions|length' "$state")" "1"

  # W14: --dry-run → exit 0, no state file, no gh calls
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"P-1","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" \
    bash "$script" commit --state "$state" --repo o/r --dry-run < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W14: dry-run exits 0" "$ec" 0
  assert_file_not_exists "W14: no state written" "$state"
  assert_file_not_exists "W14: no gh calls" "$L"
  assert_output_contains "W14: would create" "$output" '"action":"create"'

  # W15: invalid pattern_key → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"BAD KEY!!","severity":"high","entity":"X","title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=402 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_exit_code "W15: invalid key → non-zero" "$ec" 1
  assert_output_contains "W15: action malformed" "$output" '"action":"malformed"'

  # W15b: missing required field (no body) → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":"X","title":"T"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=403 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15b: missing body → malformed" "$output" '"action":"malformed"'

  # W15c: entity wrong type (object) → malformed
  workdir=$(make_workdir); make_mock_gh "$workdir"; state="$workdir/state.json"; L="$workdir/gh.log"
  printf '{"version":1,"last_run_at":null,"patterns":{}}' > "$state"
  printf '%s\n' '{"pattern_key":"payment:stuck","severity":"high","entity":{"x":1},"title":"T","body":"B"}' > "$workdir/f.jsonl"
  ec=0; output=$(cd "$workdir" && PATH="$workdir/bin:$PATH" GH_CALLS_LOG="$L" GH_CREATE_NUMBER=404 \
    bash "$script" commit --state "$state" --repo o/r < "$workdir/f.jsonl" 2>&1) || ec=$?
  assert_output_contains "W15c: bad entity type → malformed" "$output" '"action":"malformed"'
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W1[2-5][bc]?:"`
Expected: W12/W12b FAIL (no malformed-issue path), others may already pass via Task 2 validation — confirm W12/W12b fail.

- [ ] **Step 3: Implement the malformed-tracking issue**

Fill the Task-4 insert point (after the read loop, before the `last_run_at` advance):

```bash
  if [ "${#malformed[@]}" -gt 0 ]; then
    local _mlbls; IFS=',' read -ra _mlbls <<< "$LABELS"
    _ensure_labels "${_mlbls[@]}" high
    local mbody
    mbody="$(printf 'The monitor received %s unparseable / invalid finding line(s):\n\n```\n%s\n```\n' \
      "${#malformed[@]}" "$(printf '%s\n' "${malformed[@]}")")"
    _gh issue create --title "[Monitor] malformed monitor input" --label "$LABELS,high" \
      --body "$(_new_body "$mbody" "ops:monitor-input:malformed" "")" >/dev/null 2>&1 || true
  fi
```

(The `last_run_at` advance already guards on `failed == 0`; malformed sets `failed=1`, so the window stays put. `_write_state` already no-ops under `--dry-run`.)

- [ ] **Step 4: Run to verify passing**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W1[2-5][bc]?:"`
Expected: W12–W15c PASS. Then the full suite green: `bash plugins/saas-startup-team/tests/run-tests.sh`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/monitor-dedup.sh plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): monitor failure semantics (malformed/gh-fail/dry-run) (#51)"
```

---

## Task 5: The `/monitor-nightly` command (config parse + collection; no `gh`)

**Files:**
- Create: `plugins/saas-startup-team/commands/monitor-nightly.md`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (W16–W18b)

**Interfaces:**
- Consumes: `monitor-dedup.sh window` / `commit`.
- Produces: a runnable command. Its **`## Collect findings`** section is one self-contained ```` ```bash ```` block (extractable via `extract_md_bash`) that sweeps `MARKER_DIR` and runs `CUSTOM_CHECKS`, writing findings JSONL to stdout. The file contains **no `gh` invocation**.

- [ ] **Step 1: Write failing tests**

Append to `test_monitor_dedup()`:

```bash
  local cmd="$PLUGIN_ROOT/commands/monitor-nightly.md"
  # W16: command exists, right frontmatter, calls engine, uses flock, parses config — and NEVER calls gh
  assert_file_exists "W16: command exists" "$cmd"
  assert_file_contains "W16: argument-hint" "$cmd" 'argument-hint'
  assert_file_contains "W16: defines engine path" "$cmd" 'scripts/monitor-dedup.sh'
  assert_file_contains "W16: runs engine commit" "$cmd" '"$ENGINE" commit'
  assert_file_contains "W16: runs engine window" "$cmd" '"$ENGINE" window'
  assert_file_contains "W16: flock" "$cmd" 'flock'
  assert_file_contains "W16: reads .local.md" "$cmd" 'saas-startup-team.local.md'
  # the command must NOT call gh itself (engine owns all gh). Match a gh word-boundary command form.
  assert_file_not_contains "W16: no gh issue calls" "$cmd" 'gh issue'
  assert_file_not_contains "W16: no gh repo calls" "$cmd" 'gh repo'

  # W17: extracted collect block writes a JSONL finding per marker (sanitized kind) to $STATE_FILE.findings
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  printf '2026-06-21 02:00:00 UTC ocr-api down\nconnection refused\n' > "$workdir/.monitor/ocr-api-last-failure.txt"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W17: collect exits 0" "$ec" 0
  assert_file_contains "W17: pattern key from filename" "$workdir/state.json.findings" '"pattern_key":"ops:ocr-api:failure"'
  assert_json_valid "W17: emits valid JSON" "$workdir/state.json.findings"

  # W17b: messy marker filename → sanitized to a valid pattern_key (dot/space/case → dashes)
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  printf 'boom\n' > "$workdir/.monitor/OCR Api.Bad-last-failure.txt"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_file_contains "W17b: sanitized kind" "$workdir/state.json.findings" '"pattern_key":"ops:ocr-api-bad:failure"'
  assert_equals "W17b: key valid per regex" \
    "$(jq -r '.pattern_key' "$workdir/state.json.findings" | grep -cE '^[a-z0-9][a-z0-9:_-]*$')" "1"

  # W18: no markers, no custom-checks → empty findings file, exit 0
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/none.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_exit_code "W18: empty collect exits 0" "$ec" 0
  assert_equals "W18: no findings" "$(tr -d '[:space:]' < "$workdir/state.json.findings")" ""

  # W18b: custom-checks script output is merged into the findings file
  workdir=$(make_workdir); mkdir -p "$workdir/.monitor"
  cat > "$workdir/checks.sh" <<'CC'
#!/usr/bin/env bash
echo '{"pattern_key":"feedback:received","severity":"low","entity":"fb-7","title":"T","body":"B"}'
CC
  chmod +x "$workdir/checks.sh"
  extract_md_bash "$cmd" "## Collect findings" > "$workdir/collect.sh"
  ec=0; output=$(cd "$workdir" && MARKER_DIR="$workdir/.monitor" CUSTOM_CHECKS="$workdir/checks.sh" STATE_FILE="$workdir/state.json" bash "$workdir/collect.sh" 2>&1) || ec=$?
  assert_file_contains "W18b: custom-checks merged" "$workdir/state.json.findings" '"pattern_key":"feedback:received"'
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W1[678]b?:"`
Expected: FAIL — command file does not exist.

- [ ] **Step 3: Write the command**

Create `plugins/saas-startup-team/commands/monitor-nightly.md`:

````markdown
---
name: monitor-nightly
description: Nightly automated monitor — sweeps failure markers + an optional project custom-checks script, files/dedups GitHub issues with reproduction context, persists state across runs. Usage: /monitor-nightly [--dry-run]
argument-hint: "[--dry-run]"
allowed-tools: Bash, Read, Write, Grep, Glob
user_invocable: true
---

# /monitor-nightly — Generic Nightly Monitor

Detect failure signals, file deduplicated GitHub issues with reproduction context, persist state
across runs. Project-agnostic — all specifics come from the `monitor:` block in
`.claude/saas-startup-team.local.md` (all keys optional; defaults below). The command never calls
`gh` itself — the engine (`scripts/monitor-dedup.sh`) owns all GitHub I/O.

**IMPORTANT:** This creates real GitHub issues. Pass `--dry-run` to preview without creating.

## Configuration

Parse the optional `monitor:` block from `.claude/saas-startup-team.local.md`. Each key is read by
its (unique) name regardless of indentation, matching the existing `check-regression-test.sh`
convention. List value `labels` is normalized to a comma string.

```bash
ENGINE="${CLAUDE_PLUGIN_ROOT}/scripts/monitor-dedup.sh"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$GIT_ROOT/.claude/saas-startup-team.local.md"
# Scope parsing to the `monitor:` block only (from `monitor:` to the next top-level key
# or the closing `---`), so keys never collide with the regression-gate's top-level keys.
mon_block=""; [ -f "$CONFIG" ] && mon_block="$(sed -n '/^[[:space:]]*monitor:[[:space:]]*$/,/^[^[:space:]#]/p' "$CONFIG")"
cfg() { printf '%s\n' "$mon_block" | grep -oP "^\s*$1:\s*\K.*" | head -1 | sed -E 's/^["'"'"']//; s/["'"'"']$//'; }

REPO=""; MARKER_DIR=".monitor"; STATE_FILE=".startup/monitor-state.json"
CUSTOM_CHECKS=".startup/monitor-checks.sh"; LABELS="monitor,customer-issue"; REPRO_RECIPE=""
if [ -f "$CONFIG" ]; then
  v="$(cfg repo)";          [ -n "$v" ] && REPO="$v"
  v="$(cfg marker_dir)";    [ -n "$v" ] && MARKER_DIR="$v"
  v="$(cfg state_file)";    [ -n "$v" ] && STATE_FILE="$v"
  v="$(cfg custom_checks)"; [ -n "$v" ] && CUSTOM_CHECKS="$v"
  v="$(cfg repro_recipe)";  [ -n "$v" ] && REPRO_RECIPE="$v"
  v="$(cfg labels)";        [ -n "$v" ] && LABELS="$(printf '%s' "$v" | sed -E 's/.*\[//; s/\].*//; s/[[:space:]]//g')"
fi
DRY_RUN_FLAG=""; case "${ARGUMENTS:-}" in *--dry-run*) DRY_RUN_FLAG="--dry-run" ;; esac
REPO_FLAG=""; [ -n "$REPO" ] && REPO_FLAG="--repo $REPO"
```

## Lock the run

Serialize the whole run with `flock` so a manual run cannot overlap the cron run:

```bash
mkdir -p "$(dirname "$STATE_FILE")"
exec 9>"${STATE_FILE}.lock"
flock -n 9 || { echo "monitor: another run holds the lock; exiting"; exit 0; }
```

## Scan window

```bash
eval "$(bash "$ENGINE" window --state "$STATE_FILE")"
export MONITOR_SINCE MONITOR_SINCE_MINUTES
```

## Collect findings

Self-contained: reads `MARKER_DIR`, `CUSTOM_CHECKS`, and `STATE_FILE` from the environment and
writes findings JSONL (one object per line) to the file `${STATE_FILE}.findings` (the `## Commit`
step reads that file — file-based handoff survives separate shell invocations). Marker `kind` is
sanitized to a valid `pattern_key` segment.

```bash
MARKER_DIR="${MARKER_DIR:-.monitor}"
CUSTOM_CHECKS="${CUSTOM_CHECKS:-.startup/monitor-checks.sh}"
FINDINGS="${STATE_FILE:-.startup/monitor-state.json}.findings"
mkdir -p "$(dirname "$FINDINGS")"; : > "$FINDINGS"

shopt -s nullglob
for marker in "$MARKER_DIR"/*-last-failure.txt; do
  [ -f "$marker" ] || continue
  # lowercase, replace every non [a-z0-9_-] char with '-', collapse/trim dashes → valid key segment
  kind="$(basename "$marker" -last-failure.txt | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  [ -n "$kind" ] || continue
  first_line="$(head -1 "$marker" 2>/dev/null || true)"
  body="$(cat "$marker" 2>/dev/null || true)"
  for cand in "logs/${kind}.log" "logs/nightly-${kind}.log" "$MARKER_DIR/${kind}.log"; do
    [ -f "$cand" ] && { body="$body"$'\n\n--- recent log ---\n'"$(tail -40 "$cand")"; break; }
  done
  body="$body"$'\n\n(The marker auto-clears on the producer'"'"'s next successful run.)'
  jq -nc --arg pk "ops:${kind}:failure" --arg t "[Monitor] ${kind} failed — ${first_line}" --arg b "$body" \
    '{pattern_key:$pk, severity:"high", entity:null, title:$t, body:$b}' >> "$FINDINGS"
done
shopt -u nullglob

if [ -x "$CUSTOM_CHECKS" ]; then
  set +e
  "$CUSTOM_CHECKS" >> "$FINDINGS"; cc_ec=$?
  set -e
  if [ "$cc_ec" -ne 0 ]; then
    jq -nc --arg b "custom-checks exited $cc_ec" \
      '{pattern_key:"ops:monitor-checks:failure", severity:"high", entity:null, title:"[Monitor] custom-checks script failed", body:$b}' >> "$FINDINGS"
  fi
fi
```

> The custom-checks script writes its **own** findings JSONL to stdout (appended straight into
> `$FINDINGS`) and may write diagnostics to stderr. A non-zero exit still keeps the findings it
> already emitted and adds one `ops:monitor-checks:failure` tracking finding.

## Commit

Pipe the collected findings file to the engine (the engine owns all `gh` I/O):

```bash
FINDINGS="${STATE_FILE:-.startup/monitor-state.json}.findings"
grep -v '^[[:space:]]*$' "$FINDINGS" \
  | bash "$ENGINE" commit --state "$STATE_FILE" $REPO_FLAG \
      --labels "$LABELS" --repro-recipe "$REPRO_RECIPE" $DRY_RUN_FLAG
```

## Summary

The engine prints one JSON action per finding. Summarize for the human:

```
Nightly Monitor — <date>
Created: <n>  Commented: <m>  Skipped: <k>
<created/commented issue numbers>
```

If `--dry-run`, prefix every line with `[DRY RUN]`.

## Cron setup

```bash
# 0 2 * * *  cd /path/to/product && claude -p "/monitor-nightly" \
#   --allowedTools "Bash,Read,Write,Grep,Glob" >> /var/log/monitor-nightly.log 2>&1
```

Ensure `ANTHROPIC_API_KEY`, authenticated `gh`, `jq`, GNU `date`, and `flock` are available in the
cron environment.
````

> **Implementer note:** keep the literal `## Collect findings` header with a single ```` ```bash ````
> block under it (the test extracts it). The block writes JSONL to `${STATE_FILE}.findings`; the
> `## Commit` block reads that same file, so the two stay decoupled across separate shell
> invocations. Do **not** add any `gh` call to this file — repo resolution and all issue I/O belong
> to the engine.

- [ ] **Step 4: Run to verify passing**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E "W1[678]b?:"`
Expected: W16–W18b PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/monitor-nightly.md plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): /monitor-nightly command (config parse + collection, no gh) (#51)"
```

---

## Task 6: Config example, README, version bump, final verification

**Files:**
- Modify: `plugins/saas-startup-team/saas-startup-team.local.md.example`
- Modify: `plugins/saas-startup-team/README.md`
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `plugins/saas-startup-team/tests/run-tests.sh` (W19)

**Interfaces:** Consumes nothing new. Produces a shipped, documented command at a bumped, in-sync version.

- [ ] **Step 1: Write the failing test (docs + version sync)**

Append to `test_monitor_dedup()`:

```bash
  # W19: config example, README, and versions are consistent
  assert_file_contains "W19: example has monitor block" "$PLUGIN_ROOT/saas-startup-team.local.md.example" "monitor:"
  assert_file_contains "W19: README documents command" "$PLUGIN_ROOT/README.md" "/monitor-nightly"
  assert_file_contains "W19: README custom-checks contract" "$PLUGIN_ROOT/README.md" "monitor-checks.sh"
  assert_file_contains "W19: README labels config" "$PLUGIN_ROOT/README.md" "repro_recipe"
  local pv mv
  pv="$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  mv="$(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' "$PLUGIN_ROOT/../../.claude-plugin/marketplace.json")"
  assert_equals "W19: plugin/marketplace versions match" "$pv" "$mv"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep "W19:"`
Expected: FAIL — config/README text absent.

- [ ] **Step 3: Add config block, README, bump versions**

Append to `plugins/saas-startup-team/saas-startup-team.local.md.example` (inside the frontmatter, before the closing `---`):

```yaml
# --- Nightly monitor (/monitor-nightly, scripts/monitor-dedup.sh) ---
# All optional. Defaults shown. repro_recipe is single-line; {entity} is substituted.
monitor:
  repo: owner/name                          # default: resolved via `gh repo view`
  labels: [monitor, customer-issue]         # base labels; the finding's severity is appended
  marker_dir: .monitor
  state_file: .startup/monitor-state.json
  custom_checks: .startup/monitor-checks.sh
  # repro_recipe: ssh prod-readonly "session-tar {entity}"
```

Add a `## Nightly monitor (`/monitor-nightly`)` section to `README.md` covering:
- one paragraph + the `--dry-run` note;
- a config table for every `monitor:` key (default + meaning), incl. `labels` and `repro_recipe`;
- the **marker producer contract** (write `<marker_dir>/<kind>-last-failure.txt` on failure, delete on recovery; `kind` kebab-case; human closes the issue when fixed; recurrence-after-close → fresh issue);
- the **custom-checks contract** (executable at `custom_checks`; receives `MONITOR_SINCE`/`MONITOR_SINCE_MINUTES`; writes findings JSONL to stdout; non-zero exit still keeps stdout findings and adds a tracking finding; **`entity` must be a single-line identifier** — no newlines/backticks, so recovery-search marker matching stays reliable);
- the **findings JSONL schema** (`pattern_key`,`severity`,`entity`,`title`,`body`,`summary?`) and the `pattern_key` regex `^[a-z0-9][a-z0-9:_-]*$`;
- the **cron** snippet;
- a **Dependencies** line: authenticated `gh`, `jq`, GNU coreutils `date`, `flock`.

Bump the version (next minor) in BOTH manifests, matching exactly:

```bash
# plugins/saas-startup-team/.claude-plugin/plugin.json → "version": "0.43.0"
# .claude-plugin/marketplace.json (saas-startup-team entry) → "version": "0.43.0"
```

(Use the real current value + 1 minor; confirm the two strings are identical.)

- [ ] **Step 4: Run full suite + version-sync hook**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: ALL pass (W1–W19 included).

Run: `git config core.hooksPath .githooks && bash .githooks/pre-push </dev/null 2>&1 | grep -i "saas-startup-team\|version" || true`
Expected: no version-mismatch error for `saas-startup-team`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/saas-startup-team.local.md.example plugins/saas-startup-team/README.md \
        plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json \
        plugins/saas-startup-team/tests/run-tests.sh
git commit -m "feat(saas-startup-team): monitor docs, config example, version bump to 0.43.0 (#51)"
```

---

## Self-Review (plan author)

**Spec coverage:** §3 architecture → Tasks 1–5; §4 findings contract + validation → Task 2 `_validate`, Task 4 (W15–W15c); §5.1 marker sweep (sanitized) → Task 5 (W17/W17b); §5.2 custom-checks + non-zero handling → Task 5 (W18b); §6 dedup ladder incl. reconciliation/verified-recovery/within-run/labels/per-finding-failure/atomic-write → Tasks 2–4; §6 body markers + repro_recipe + DoD → `_new_body` (Task 2); §7.1 non-advance-on-failure → Task 2 guard + Task 4 (W12/W13/W13b); §7.2 flock → Task 5 (W16); §7.3 malformed surfaced → Task 4 (W12/W12b/W15*); §7.4 corrupt state / dry-run → Task 1 (W4/W4b), Task 4 (W14); §8 state schema + repo-local default → throughout; §9 config (labels/repro_recipe wired, severities dropped) → Tasks 5–6 (W19). ✓

**Placeholder scan:** every code step carries runnable code; the one illustrative `sed` line in the command is explicitly flagged as non-essential narration with the real flow described. ✓

**Type consistency:** action objects `{action,pattern_key,entity,issue}` emitted via `jq -nc` everywhere; state mutated only via `jq` against the fixed schema; `_gh`/`_ensure_labels`/`_new_body`/`_validate`/`_issue_open`/`_recover_issue`/`_write_state` signatures match call sites; null entity is `""` in both fixtures and code. ✓

## Review revisions (folded-in Codex findings)

**Accepted & implemented:** repo resolution moved into the engine (command makes zero `gh` calls; W16 asserts it); null entity normalized to `""` not `"null"` (W10 fixture fixed); strict `_validate` (required keys, `entity` string|null, `pattern_key` regex) → malformed (W15/W15b/W15c); action JSON via `jq -nc` (injection-safe); `known` via `jq -e has($k)`; issue number `0`/empty treated as failure (no state corruption); `_issue_open` treats `gh` failure as **open** (conservative, W10b) so a transient error never spawns duplicates; recovery search **verifies** embedded `**Pattern:**`/`**Entity:**` markers before adopting (W11/W11b); `window` survives an unparseable `last_run_at` (W4b); `_write_state` traps temp-file cleanup; `flock` block does `mkdir -p` and fails closed; marker `kind` sanitized to a valid key (W17b); `monitor.labels` + `repro_recipe` wired end-to-end (config → command → engine → issue body); `.local.md` parser added (modeled on `check-regression-test.sh`); strengthened tests (window range W2, "no gh calls" W6/W14, comment-failure W13b, multi-malformed W12b, empty-stdin W9b, custom-checks merge W18b).

**Deferred (with reason):** strict severity validation — kept lenient and **dropped the unused `severities` config key** instead (a label typo must not drop a real incident); atomic-write-preserves-old-state-on-write-failure, standalone-engine concurrency, and missing-`jq`/`gh` environment tests — out of scope for unit tests (environment/preflight concerns), noted in README dependencies; future-`last_run_at` floor of 1 minute — documented behavior, not separately tested.

### Round 2 (re-review of the revised plan)

A second Codex pass on the *revised* engine found bugs introduced by the round-1 edits; all fixed in place:
- **`window` crash on bad timestamp** — `epoch="$(_iso_to_epoch "$last")"` was the last command in an `&&` chain, so a bad date exited under `set -e`. Now `... || true` → empty epoch → 1440 (W4b now genuinely passes).
- **`--dry-run` exited non-zero** — `_gh issue create` writes only to stderr under dry-run, so number parsing failed → `error`. Added an explicit dry-run create branch emitting `{action:create, issue:null}` (W14 fixed).
- **W17b was an impossible RED** — sanitizer kept `.` but the key regex forbids it. Sanitizer now maps every non-`[a-z0-9_-]` char to `-` and collapses; expected key is `ops:ocr-api-bad:failure`.
- **`_write_state` RETURN trap** persisted and could fire `rm -f "$tmp"` with `$tmp` unset under `set -u` on a later return → replaced with inline cleanup.
- **`_validate` let missing `entity` through** (`.entity==null` is true for an absent key) and could emit multiple objects → added `has("entity")` + `head -1`.
- **Unsafe label word-splitting** `${LABELS//,/ }` → now `IFS=',' read -ra` arrays in both create and malformed paths.
- **`cfg()` matched unrelated top-level keys** → parsing now scoped to the `monitor:` block via a `sed` range.
- **Command `## Commit` referenced an undefined `$ENGINE_CMD`/`sed`** (non-runnable) → replaced with a deterministic file handoff: `## Collect findings` writes `${STATE_FILE}.findings`, `## Commit` reads it. Collection tests (W17–W18b) assert on that file.
- **`_recover_issue` only checked the first search hit** → now verifies every hit's embedded `**Pattern:**`/`**Entity:**` markers before adopting (W11b: a hit with the wrong entity → create, not adopt).
- **Reconciliation legitimately calls `gh issue view`** even on a skip → W6 now asserts "no create/comment" rather than "no gh calls".
- **Mock `gh` flattened** multi-line argv to one log line so per-call counts (`--repo` on every call, exactly-one malformed issue) are accurate.
- **W16 string asserts** aligned to the real command text (`"$ENGINE" commit`/`window`, `scripts/monitor-dedup.sh`).

**Round-2 deferred:** entity values are assumed to be single-line identifiers (newlines/backticks in an `entity` could weaken the recovery marker grep) — documented as a custom-checks contract constraint in the README rather than escaped in code.
