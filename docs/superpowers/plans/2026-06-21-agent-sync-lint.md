# agent-sync lint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic, vendorable `lint.sh` to the `agent-sync` plugin that flags cross-file stack contradictions, oversized rules files, and soft-preference directives, wired into `/agent-sync:check` and CI.

**Architecture:** A new standalone bash script `scripts/lint.sh` mirrors `generate.sh`'s CLI/config/REPO_ROOT conventions. It reads an optional `lint` block from `sources.json`, runs three independent checks (contradictions, line-budget, soft-preferences), collects all findings into one array, prints them in a deterministic sorted order, and exits 0/1/2. `/agent-sync:check`, `/agent-sync:init`, the GHA template, and docs are updated to run and describe it.

**Tech Stack:** bash 4+, `jq`, `grep -E`, `awk`, `sort`, `sed`. No LLM, no network. Everything runs under `LC_ALL=C`.

## Global Constraints

- bash 4+, POSIX tools only; dependencies `jq`, `grep`, `awk`, `sort`, `sed`.
- Deterministic and vendorable into CI **without** the plugin or any LLM installed.
- Backward compatible: a `sources.json` with **no** `lint` key produces **no** output and exits 0.
- All `grep`/`sort`/character-class ops run under `export LC_ALL=C` for byte-stable output.
- No hardcoded project names/paths/stacks — generic plugin code only.
- Exit codes: `0` = no error-severity findings; `1` = ≥1 error-severity finding; `2` = config error.
- Severity values: `error` (counts toward exit 1), `warn` (printed only), `off` (check skipped).
- Default severities: all three checks default to `warn`.
- Default file lists: `contradictions` → `["README.md","CLAUDE.md"]`; `lineBudget` and `softPreferences` → `["CLAUDE.md",".claude/rules/*.md"]`.
- Version bump `0.2.2 → 0.3.0` in **both** `plugins/agent-sync/.claude-plugin/plugin.json` **and** root `.claude-plugin/marketplace.json` before pushing (repo rule; pre-push hook enforces equality).
- All paths below are relative to `plugins/agent-sync/` unless stated. Run tests from repo root.

---

### Task 1: lint.sh skeleton — CLI, config/root resolution, reporting harness

Build the script shell: argument parsing, config autodetect, REPO_ROOT resolution, dependency check, the `lint`-key gate, and the findings collector + reporting/summary/exit logic. **No checks are wired yet** — the deliverable is the no-op + reporting harness.

**Files:**
- Create: `plugins/agent-sync/scripts/lint.sh`
- Create: `plugins/agent-sync/tests/run-lint-tests.sh`

**Interfaces:**
- Produces (consumed by Tasks 3–5):
  - Global `CONFIG` (string contents of sources.json), `REPO_ROOT` (absolute path).
  - `add_finding SEVERITY CHECK_IDX SORT_KEY MESSAGE` — appends one finding. `CHECK_IDX` is `0` contradictions / `1` line-budget / `2` soft-preferences (fixed emit order). `SORT_KEY` is an arbitrary string used to order findings within a check.
  - `report` — sorts `FINDINGS`, prints messages, prints the summary line, exits 0/1.
  - Global associative-safe `LINT` is read via `jq` against `CONFIG` directly (no separate global needed).

- [ ] **Step 1: Write the failing test harness with the no-op + empty-block cases**

Create `plugins/agent-sync/tests/run-lint-tests.sh`:

```bash
#!/usr/bin/env bash
# Test runner for agent-sync linter (lint.sh)
# Self-contained: bash 4+, jq, grep, awk, sort, sed.
# Usage: bash plugins/agent-sync/tests/run-lint-tests.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$PLUGIN_ROOT/scripts/lint.sh"
PASS=0
FAIL=0

# assert_exit NAME EXPECTED_CODE -- ARGS...   (runs lint.sh, checks exit code)
assert_exit() {
  local name="$1" want="$2"; shift 2; shift  # drop the literal --
  bash "$LINT" "$@" >/dev/null 2>&1; local ec=$?
  if [[ "$ec" -eq "$want" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — exit $ec, expected $want"; FAIL=$((FAIL+1)); fi
}

# assert_stdout_contains NAME SUBSTRING -- ARGS...
assert_stdout_contains() {
  local name="$1" sub="$2"; shift 2; shift
  local out; out="$(bash "$LINT" "$@" 2>/dev/null)"
  if [[ "$out" == *"$sub"* ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — missing '$sub' in: $out"; FAIL=$((FAIL+1)); fi
}

# assert_stdout_empty NAME -- ARGS...
assert_stdout_empty() {
  local name="$1"; shift; shift
  local out; out="$(bash "$LINT" "$@" 2>/dev/null)"
  if [[ -z "$out" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — expected empty stdout, got: $out"; FAIL=$((FAIL+1)); fi
}

# assert_stdout_absent NAME SUBSTRING -- ARGS...
assert_stdout_absent() {
  local name="$1" sub="$2"; shift 2; shift
  local out; out="$(bash "$LINT" "$@" 2>/dev/null)"
  if [[ "$out" != *"$sub"* ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — unexpected '$sub' in: $out"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- Fixture: no lint block -> silent exit 0 ---
NOLINT="$TMP/nolint"; mkdir -p "$NOLINT/.agent-sync"
echo "# claude" > "$NOLINT/CLAUDE.md"
cat > "$NOLINT/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}]}
JSON
assert_stdout_empty "no lint block -> silent" -- --config "$NOLINT/.agent-sync/sources.json" --root "$NOLINT"
assert_exit "no lint block -> exit 0" 0 -- --config "$NOLINT/.agent-sync/sources.json" --root "$NOLINT"

# --- Fixture: empty lint block -> prints summary 0/0, exit 0 ---
EMPTY="$TMP/empty"; mkdir -p "$EMPTY/.agent-sync"
echo "# claude" > "$EMPTY/CLAUDE.md"
cat > "$EMPTY/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":{}}
JSON
assert_stdout_contains "empty lint -> summary 0/0" "summary: 0 errors, 0 warnings" -- --config "$EMPTY/.agent-sync/sources.json" --root "$EMPTY"
assert_exit "empty lint -> exit 0" 0 -- --config "$EMPTY/.agent-sync/sources.json" --root "$EMPTY"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: FAIL (lint.sh does not exist yet — runner reports failures / non-zero).

- [ ] **Step 3: Write the lint.sh skeleton**

Create `plugins/agent-sync/scripts/lint.sh`:

```bash
#!/usr/bin/env bash
# agent-sync: lint Claude Code config for doc-drift and rules-file bloat.
# Dependencies: bash 4+, jq, grep, awk, sort, sed. Deterministic, vendorable.
set -euo pipefail
export LC_ALL=C

CONFIG_PATH=""
REPO_ROOT=""

# --- CLI parsing (mirrors generate.sh) ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ -z "${2:-}" ]] && { echo "[agent-sync lint] --config requires a path" >&2; exit 2; }
      CONFIG_PATH="$2"; shift 2 ;;
    --root)
      [[ -z "${2:-}" ]] && { echo "[agent-sync lint] --root requires a path" >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: lint.sh [--config <path>] [--root <path>]"
      echo ""
      echo "  --config <path>  Path to sources.json (default: auto-detect)"
      echo "  --root <path>    Project root (default: inferred from config dir)"
      exit 0 ;;
    *)
      echo "[agent-sync lint] Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Locate config (same precedence as generate.sh) ---
find_config() {
  local search_dir="${1:-.}"
  for candidate in "tools/agent-sync/sources.json" ".agent-sync/sources.json"; do
    [[ -f "$search_dir/$candidate" ]] && { echo "$search_dir/$candidate"; return 0; }
  done
  return 1
}

if [[ -z "$CONFIG_PATH" ]]; then
  if ! CONFIG_PATH="$(find_config "$(pwd)")"; then
    echo "[agent-sync lint] No sources.json found. Run /agent-sync:init to create one." >&2
    exit 2
  fi
fi
[[ -f "$CONFIG_PATH" ]] || { echo "[agent-sync lint] Config not found: $CONFIG_PATH" >&2; exit 2; }
CONFIG_PATH="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"

# --- Resolve REPO_ROOT (same logic as generate.sh; --root overrides) ---
if [[ -z "$REPO_ROOT" ]]; then
  config_dir="$(dirname "$CONFIG_PATH")"
  parent_dir="$(dirname "$config_dir")"
  dir_name="$(basename "$config_dir")"
  if [[ "$dir_name" == "agent-sync" || "$dir_name" == ".agent-sync" ]]; then
    if [[ "$(basename "$parent_dir")" == "tools" ]]; then
      REPO_ROOT="$(dirname "$parent_dir")"
    else
      REPO_ROOT="$parent_dir"
    fi
  else
    REPO_ROOT="$config_dir"
  fi
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# --- Dependency check ---
for cmd in jq grep awk sort sed; do
  command -v "$cmd" &>/dev/null || { echo "[agent-sync lint] Missing dependency: $cmd" >&2; exit 2; }
done

# --- Read + parse config ---
CONFIG="$(cat "$CONFIG_PATH")"
jq empty <<<"$CONFIG" 2>/dev/null || { echo "[agent-sync lint] config error: malformed JSON in $CONFIG_PATH" >&2; exit 2; }

# --- Gate: no lint block -> silent success ---
[[ "$(jq 'has("lint")' <<<"$CONFIG")" == "true" ]] || exit 0

# --- Findings collector ---
# Each entry: "SEVERITY<TAB>CHECK_IDX<TAB>SORT_KEY<TAB>MESSAGE"
FINDINGS=()
add_finding() { FINDINGS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }

# --- Reporting ---
report() {
  local errors=0 warns=0 entry sev
  for entry in "${FINDINGS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    sev="${entry%%$'\t'*}"
    [[ "$sev" == "error" ]] && errors=$((errors+1))
    [[ "$sev" == "warn" ]] && warns=$((warns+1))
  done
  if ((${#FINDINGS[@]})); then
    printf '%s\n' "${FINDINGS[@]}" | sort -t$'\t' -k2,2 -k3,3 | cut -f4-
  fi
  printf '[agent-sync lint] summary: %d errors, %d warnings\n' "$errors" "$warns"
  if (( errors > 0 )); then exit 1; fi
  exit 0
}

# (checks wired in later tasks call add_finding before report)

report
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: PASS (4 assertions pass, `PASS=4 FAIL=0`).

- [ ] **Step 5: Make lint.sh executable and commit**

```bash
chmod +x plugins/agent-sync/scripts/lint.sh
git add plugins/agent-sync/scripts/lint.sh plugins/agent-sync/tests/run-lint-tests.sh
git commit -m "feat(agent-sync): lint.sh skeleton — CLI, config resolution, reporting harness (#55)"
```

---

### Task 2: Config validation (exit code 2)

Validate the `lint` block before running any check. Invalid severity, non-positive-integer `max`, non-array `files`, or non-array-of-arrays `exclusiveGroups` are config errors → stderr message + exit 2.

**Files:**
- Modify: `plugins/agent-sync/scripts/lint.sh` (add `validate_lint_config` + call)
- Modify: `plugins/agent-sync/tests/run-lint-tests.sh` (add cases)

**Interfaces:**
- Produces: `validate_lint_config` — exits 2 with `[agent-sync lint] config error: <detail>` on invalid config; returns 0 otherwise. Called immediately after the lint-key gate, before any check.

- [ ] **Step 1: Write the failing tests**

Append to `plugins/agent-sync/tests/run-lint-tests.sh` **before** the final `echo "-----"` block:

```bash
# --- Config validation (exit 2) ---
mk_cfg() {  # $1 dir, $2 lint-json  -> writes sources.json, echoes its path
  local d="$1" lint="$2"; mkdir -p "$d/.agent-sync"; echo "# c" > "$d/CLAUDE.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

C1="$(mk_cfg "$TMP/badsev" '{"lineBudget":{"severity":"loud","max":200}}')"
assert_exit "invalid severity -> exit 2" 2 -- --config "$C1" --root "$TMP/badsev"

C2="$(mk_cfg "$TMP/badmax" '{"lineBudget":{"max":0}}')"
assert_exit "max=0 -> exit 2" 2 -- --config "$C2" --root "$TMP/badmax"

C2b="$(mk_cfg "$TMP/badmax2" '{"lineBudget":{"max":"two"}}')"
assert_exit "max non-numeric -> exit 2" 2 -- --config "$C2b" --root "$TMP/badmax2"

C3="$(mk_cfg "$TMP/badfiles" '{"lineBudget":{"files":"CLAUDE.md"}}')"
assert_exit "files not array -> exit 2" 2 -- --config "$C3" --root "$TMP/badfiles"

C4="$(mk_cfg "$TMP/badgroups" '{"contradictions":{"exclusiveGroups":["Supabase","Postgres"]}}')"
assert_exit "exclusiveGroups not array-of-arrays -> exit 2" 2 -- --config "$C4" --root "$TMP/badgroups"

# malformed JSON -> exit 2
MJ="$TMP/malformed"; mkdir -p "$MJ/.agent-sync"; echo "# c" > "$MJ/CLAUDE.md"
printf '{ this is not json' > "$MJ/.agent-sync/sources.json"
assert_exit "malformed JSON -> exit 2" 2 -- --config "$MJ/.agent-sync/sources.json" --root "$MJ"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: FAIL on the new cases (lint.sh currently exits 0, not 2, for bad severity/max/files/groups).

- [ ] **Step 3: Implement validate_lint_config**

In `plugins/agent-sync/scripts/lint.sh`, insert this function and its call **after** the lint-key gate line (`[[ "$(jq 'has("lint")' ...)" ]] || exit 0`) and **before** the `# --- Findings collector ---` block:

```bash
# --- Config validation ---
cfg_err() { echo "[agent-sync lint] config error: $1" >&2; exit 2; }

validate_lint_config() {
  local check sev t
  # lint itself must be an object.
  [[ "$(jq -r '.lint | type' <<<"$CONFIG")" == "object" ]] || cfg_err "lint must be an object"
  for check in contradictions lineBudget softPreferences; do
    [[ "$(jq --arg c "$check" 'has("lint") and (.lint｜has($c))' <<<"$CONFIG")" == "true" ]] || continue
    # each configured check must be an object.
    [[ "$(jq -r --arg c "$check" '.lint[$c] | type' <<<"$CONFIG")" == "object" ]] \
      || cfg_err "$check must be an object"
    # severity
    sev="$(jq -r --arg c "$check" '.lint[$c].severity // "warn"' <<<"$CONFIG")"
    case "$sev" in error|warn|off) ;; *) cfg_err "invalid severity '$sev' for $check (use error|warn|off)";; esac
    # files type
    t="$(jq -r --arg c "$check" '.lint[$c].files | type' <<<"$CONFIG")"
    [[ "$t" == "array" || "$t" == "null" ]] || cfg_err "$check.files must be an array"
    if [[ "$t" == "array" ]]; then
      [[ "$(jq --arg c "$check" '[.lint[$c].files[] | type] | all(. == "string")' <<<"$CONFIG")" == "true" ]] \
        || cfg_err "$check.files must be an array of strings"
    fi
  done
  # lineBudget.max must be a positive integer when present
  if [[ "$(jq 'has("lint") and (.lint｜has("lineBudget")) and (.lint.lineBudget｜has("max"))' <<<"$CONFIG")" == "true" ]]; then
    [[ "$(jq -r '.lint.lineBudget.max | (type == "number" and . == floor and . > 0)' <<<"$CONFIG")" == "true" ]] \
      || cfg_err "lineBudget.max must be a positive integer"
  fi
  # exclusiveGroups must be an array of arrays of strings when present
  if [[ "$(jq 'has("lint") and (.lint｜has("contradictions")) and (.lint.contradictions｜has("exclusiveGroups"))' <<<"$CONFIG")" == "true" ]]; then
    [[ "$(jq '.lint.contradictions.exclusiveGroups | type' <<<"$CONFIG")" == '"array"' ]] \
      || cfg_err "contradictions.exclusiveGroups must be an array"
    [[ "$(jq '[.lint.contradictions.exclusiveGroups[] | (type == "array") and ([.[] | type] | all(. == "string"))] | all' <<<"$CONFIG")" == "true" ]] \
      || cfg_err "contradictions.exclusiveGroups must be an array of arrays of strings"
  fi
}
validate_lint_config
```

> **NOTE TO IMPLEMENTER:** the `｜` characters above are a stand-in for the jq pipe `|` to survive
> markdown. Replace every `｜` with a literal `|` when you write the file. (They appear only inside
> `jq has(...)` expressions like `.lint｜has($c)` → `.lint|has($c)`.)

- [ ] **Step 4: Run to verify pass**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: PASS (all prior + 6 new validation cases; `FAIL=0`).

- [ ] **Step 5: Commit**

```bash
git add plugins/agent-sync/scripts/lint.sh plugins/agent-sync/tests/run-lint-tests.sh
git commit -m "feat(agent-sync): lint config validation with exit code 2 (#55)"
```

---

### Task 3: Line-budget check (+ file-resolution helper)

Introduce the shared `resolve_files` helper (glob expansion relative to `REPO_ROOT`, `nullglob`, dedup, missing-skipped) and the line-budget check using it.

**Files:**
- Modify: `plugins/agent-sync/scripts/lint.sh`
- Modify: `plugins/agent-sync/tests/run-lint-tests.sh`

**Interfaces:**
- Produces (consumed by Tasks 4–5):
  - `resolve_files JQ_FILES_PATH DEFAULT1 [DEFAULT2 ...]` — prints, one per line, the **absolute** paths of existing files for a check, deduplicated. `JQ_FILES_PATH` is a jq expression yielding the check's `files` array (e.g. `.lint.lineBudget.files`); when it is absent/null, the passed defaults are used. Globs (`*`) expand relative to `REPO_ROOT`; non-matching globs and missing literal files yield nothing.
  - `relpath ABS` — prints `ABS` relative to `REPO_ROOT` with any leading `./` stripped.
- Consumes: `add_finding`, `CONFIG`, `REPO_ROOT` from Task 1.

- [ ] **Step 1: Write the failing tests**

Append before the final summary block in `run-lint-tests.sh`:

```bash
# --- Line budget ---
mk_repo_lb() {  # $1 dir, $2 line-count for big.md, $3 lint-json
  local d="$1" n="$2" lint="$3"; mkdir -p "$d/.agent-sync" "$d/.claude/rules"
  echo "# c" > "$d/CLAUDE.md"
  awk -v n="$n" 'BEGIN{for(i=1;i<=n;i++) print "line " i}' > "$d/.claude/rules/big.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

LB1="$(mk_repo_lb "$TMP/lb_over" 250 '{"lineBudget":{"max":200,"files":[".claude/rules/*.md"]}}')"
assert_stdout_contains "250-line file flagged" "big.md is 250 lines (budget 200)" -- --config "$LB1" --root "$TMP/lb_over"
assert_exit "line-budget warn -> exit 0" 0 -- --config "$LB1" --root "$TMP/lb_over"

LB2="$(mk_repo_lb "$TMP/lb_under" 50 '{"lineBudget":{"max":200,"files":[".claude/rules/*.md"]}}')"
assert_stdout_absent "in-budget file not flagged" "big.md" -- --config "$LB2" --root "$TMP/lb_under"

LB3="$(mk_repo_lb "$TMP/lb_off" 250 '{"lineBudget":{"severity":"off","max":200,"files":[".claude/rules/*.md"]}}')"
assert_stdout_absent "severity off -> no finding" "big.md" -- --config "$LB3" --root "$TMP/lb_off"

LB4="$(mk_repo_lb "$TMP/lb_err" 250 '{"lineBudget":{"severity":"error","max":200,"files":[".claude/rules/*.md"]}}')"
assert_exit "line-budget error -> exit 1" 1 -- --config "$LB4" --root "$TMP/lb_err"

# Missing glob / missing literal file -> no crash, no finding
LB5="$(mk_repo_lb "$TMP/lb_missing" 50 '{"lineBudget":{"max":200,"files":["does-not-exist.md","nope/*.md"]}}')"
assert_exit "missing files skipped -> exit 0" 0 -- --config "$LB5" --root "$TMP/lb_missing"
assert_stdout_contains "missing files -> summary 0/0" "0 errors, 0 warnings" -- --config "$LB5" --root "$TMP/lb_missing"

# Dedup: overlapping glob + literal resolve to one file -> single finding line
LB6="$(mk_repo_lb "$TMP/lb_dedup" 250 '{"lineBudget":{"max":200,"files":[".claude/rules/*.md",".claude/rules/big.md"]}}')"
DEDUP_OUT="$(bash "$LINT" --config "$LB6" --root "$TMP/lb_dedup" 2>/dev/null | grep -c 'big.md is 250')"
if [[ "$DEDUP_OUT" -eq 1 ]]; then echo "PASS: dedup overlapping globs"; PASS=$((PASS+1));
else echo "FAIL: dedup overlapping globs — got $DEDUP_OUT finding lines"; FAIL=$((FAIL+1)); fi
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: FAIL on the new line-budget cases (no check wired yet).

- [ ] **Step 3: Implement resolve_files, relpath, and the line-budget check**

In `lint.sh`, add the helpers **after** `validate_lint_config` and **before** `# --- Findings collector ---`:

```bash
# --- Path helpers ---
relpath() { local p="$1"; p="${p#"$REPO_ROOT"/}"; p="${p#./}"; printf '%s' "$p"; }

# resolve_files JQ_FILES_PATH DEFAULT...  -> absolute existing paths, deduplicated, one per line
resolve_files() {
  local jqpath="$1"; shift
  local -a entries=()
  if [[ "$(jq -r "($jqpath) | type" <<<"$CONFIG" 2>/dev/null)" == "array" ]]; then
    mapfile -t entries < <(jq -r "($jqpath)[]" <<<"$CONFIG")
  else
    entries=("$@")
  fi
  local -A seen=()
  local e abs
  # Save/restore caller's nullglob state.
  local nullglob_was=0; shopt -q nullglob && nullglob_was=1
  shopt -s nullglob
  for e in "${entries[@]}"; do
    # Unquoted $e enables glob expansion (paths assumed free of spaces, like generate.sh).
    for abs in "$REPO_ROOT"/$e; do
      [[ -f "$abs" ]] || continue
      if [[ -z "${seen[$abs]:-}" ]]; then seen[$abs]=1; printf '%s\n' "$abs"; fi
    done
  done
  (( nullglob_was )) && shopt -s nullglob || shopt -u nullglob
}
```

Then add the check function **after** the collector/`report` definitions but **before** the final `report` call. Replace the `# (checks wired in later tasks ...)` comment with:

```bash
# --- Check: line budget ---
check_line_budget() {
  [[ "$(jq 'has("lint") and (.lint|has("lineBudget"))' <<<"$CONFIG")" == "true" ]] || return 0
  local sev max abs rel n
  sev="$(jq -r '.lint.lineBudget.severity // "warn"' <<<"$CONFIG")"
  [[ "$sev" == "off" ]] && return 0
  max="$(jq -r '.lint.lineBudget.max // 200' <<<"$CONFIG")"
  while IFS= read -r abs; do
    [[ -z "$abs" ]] && continue
    n="$(wc -l < "$abs" | tr -d ' ')"
    if (( n > max )); then
      rel="$(relpath "$abs")"
      add_finding "$sev" 1 "$rel" "[agent-sync lint] line-budget: $rel is $n lines (budget $max)"
    fi
  done < <(resolve_files ".lint.lineBudget.files" "CLAUDE.md" ".claude/rules/*.md")
}
check_line_budget
```

> **NOTE:** `wc -l` counts newline characters; a file with no trailing newline on its last line
> undercounts by one. The fixtures use `awk '{print}'` which always terminates lines, so the 250
> count is exact. This matches the spec's "raw line count" semantics.

- [ ] **Step 4: Run to verify pass**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: PASS (all prior + line-budget cases; `FAIL=0`).

- [ ] **Step 5: Commit**

```bash
git add plugins/agent-sync/scripts/lint.sh plugins/agent-sync/tests/run-lint-tests.sh
git commit -m "feat(agent-sync): line-budget lint check + file-resolution helper (#55)"
```

---

### Task 4: Soft-preferences check

Flag lines where `prefer` is the leading directive verb, across the resolved files.

**Files:**
- Modify: `plugins/agent-sync/scripts/lint.sh`
- Modify: `plugins/agent-sync/tests/run-lint-tests.sh`

**Interfaces:**
- Consumes: `resolve_files`, `relpath`, `add_finding` from Tasks 1/3.

- [ ] **Step 1: Write the failing tests**

Append before the final summary block:

```bash
# --- Soft preferences ---
mk_repo_sp() {  # $1 dir, $2 body-file-content (heredoc text), $3 lint-json
  local d="$1" lint="$3"; mkdir -p "$d/.agent-sync" "$d/.claude/rules"
  printf '%s' "$2" > "$d/.claude/rules/style.md"
  echo "# c" > "$d/CLAUDE.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

SP_BODY=$'# Style\n\nPrefer composition over inheritance.\n- prefer using hooks\n1. Prefer X\nUsers prefer dark mode here.\nWe preferred the old API.\n'
SP1="$(mk_repo_sp "$TMP/sp" "$SP_BODY" '{"softPreferences":{"files":[".claude/rules/*.md"]}}')"
# NOTE: the file lives at .claude/rules/style.md, so the reported path is the full relative path.
assert_stdout_contains "leading Prefer flagged" "soft-preference: .claude/rules/style.md:3" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_contains "bullet prefer flagged" ".claude/rules/style.md:4" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_contains "numbered Prefer flagged" ".claude/rules/style.md:5" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_absent "mid-sentence prefer NOT flagged" ".claude/rules/style.md:6:" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_absent "mid-sentence preferred NOT flagged" ".claude/rules/style.md:7:" -- --config "$SP1" --root "$TMP/sp"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: FAIL on soft-preference cases.

- [ ] **Step 3: Implement the soft-preferences check**

In `lint.sh`, add **after** `check_line_budget` and its call, **before** the final `report`:

```bash
# --- Check: soft preferences ---
SOFT_PREF_RE='^[[:space:]]*([-*+]|#{1,6}|[0-9]+[.)])?[[:space:]]*prefer(s|red)?([[:space:]]|$)'
check_soft_preferences() {
  [[ "$(jq 'has("lint") and (.lint|has("softPreferences"))' <<<"$CONFIG")" == "true" ]] || return 0
  local sev abs rel lineno text
  sev="$(jq -r '.lint.softPreferences.severity // "warn"' <<<"$CONFIG")"
  [[ "$sev" == "off" ]] && return 0
  while IFS= read -r abs; do
    [[ -z "$abs" ]] && continue
    rel="$(relpath "$abs")"
    # grep -niE: line numbers + case-insensitive ERE. Each hit: "N:full text".
    while IFS=: read -r lineno text; do
      [[ -z "$lineno" ]] && continue
      # trim leading whitespace from reported text
      text="${text#"${text%%[![:space:]]*}"}"
      add_finding "$sev" 2 "$(printf '%s:%010d' "$rel" "$lineno")" \
        "[agent-sync lint] soft-preference: $rel:$lineno: $text"
    done < <(grep -niE "$SOFT_PREF_RE" "$abs" || true)
  done < <(resolve_files ".lint.softPreferences.files" "CLAUDE.md" ".claude/rules/*.md")
}
check_soft_preferences
```

> **NOTE:** The `%010d` zero-pads the line number in the **sort key only** (so line 9 sorts before
> line 10); the human-readable message uses the bare `$lineno`. The `([-*+]|#{1,6}|[0-9]+[.)])?`
> group makes an optional bullet/heading/number marker; mid-sentence "users prefer" never matches
> because of the leading `^[[:space:]]*` + marker structure requiring `prefer` at line start.

- [ ] **Step 4: Run to verify pass**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: PASS (`FAIL=0`).

- [ ] **Step 5: Commit**

```bash
git add plugins/agent-sync/scripts/lint.sh plugins/agent-sync/tests/run-lint-tests.sh
git commit -m "feat(agent-sync): soft-preference lint check (#55)"
```

---

### Task 5: Contradictions check

For each `exclusiveGroup`, flag when ≥2 distinct terms appear (whole-word via non-alphanumeric boundaries) across the union of the check's files.

**Files:**
- Modify: `plugins/agent-sync/scripts/lint.sh`
- Modify: `plugins/agent-sync/tests/run-lint-tests.sh`

**Interfaces:**
- Consumes: `resolve_files`, `relpath`, `add_finding`.

- [ ] **Step 1: Write the failing tests**

Append before the final summary block:

```bash
# --- Contradictions ---
mk_repo_ct() {  # $1 dir, $2 README content, $3 CLAUDE content, $4 lint-json
  local d="$1" lint="$4"; mkdir -p "$d/.agent-sync"
  printf '%s' "$2" > "$d/README.md"
  printf '%s' "$3" > "$d/CLAUDE.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

# Contradiction across README + CLAUDE.md
CT1="$(mk_repo_ct "$TMP/ct" $'We use Supabase.\n' $'We use Postgres.\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_stdout_contains "contradiction flagged" "contradiction: group {Supabase, Postgres}" -- --config "$CT1" --root "$TMP/ct"
assert_exit "contradiction warn default -> exit 0" 0 -- --config "$CT1" --root "$TMP/ct"

CT1e="$(mk_repo_ct "$TMP/ct_err" $'Supabase\n' $'Postgres\n' '{"contradictions":{"severity":"error","files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_exit "contradiction error -> exit 1" 1 -- --config "$CT1e" --root "$TMP/ct_err"

# Single term present -> no finding
CT2="$(mk_repo_ct "$TMP/ct_single" $'Postgres only\n' $'Postgres again\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_stdout_absent "single term -> no contradiction" "contradiction:" -- --config "$CT2" --root "$TMP/ct_single"

# Boundary guard: Postgres term must NOT match inside PostgreSQL
CT3="$(mk_repo_ct "$TMP/ct_bound" $'We use Supabase.\n' $'We use PostgreSQL 16.\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_stdout_absent "Postgres not matched in PostgreSQL" "contradiction:" -- --config "$CT3" --root "$TMP/ct_bound"

# Punctuation + multiword terms match literally
CT4="$(mk_repo_ct "$TMP/ct_punct" $'Built with .NET and Node.js.\n' $'Also uses Claude Code.\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[[".NET","Claude Code"]]}}')"
assert_stdout_contains "punct/multiword terms match" "contradiction: group {.NET, Claude Code}" -- --config "$CT4" --root "$TMP/ct_punct"

# Group with <2 terms -> skipped, no error
CT5="$(mk_repo_ct "$TMP/ct_short" $'Supabase\n' $'Supabase\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase"]]}}')"
assert_exit "group <2 terms skipped -> exit 0" 0 -- --config "$CT5" --root "$TMP/ct_short"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: FAIL on contradiction cases.

- [ ] **Step 3: Implement the contradictions check**

In `lint.sh`, add **after** `check_soft_preferences` and its call, **before** the final `report`:

```bash
# --- Check: contradictions ---
# Escape ERE metacharacters in a term so it is matched literally.
ere_escape() { printf '%s' "$1" | sed 's/[][\\^$.*+?(){}|]/\\&/g'; }

# term_present ABS_FILE TERM -> 0 if TERM appears with non-alphanumeric boundaries
term_present() {
  local file="$1" term="$2" esc
  esc="$(ere_escape "$term")"
  grep -iEq -- "(^|[^[:alnum:]])${esc}([^[:alnum:]]|\$)" "$file"
}

check_contradictions() {
  [[ "$(jq 'has("lint") and (.lint|has("contradictions"))' <<<"$CONFIG")" == "true" ]] || return 0
  local sev gcount gi tcount
  sev="$(jq -r '.lint.contradictions.severity // "warn"' <<<"$CONFIG")"
  [[ "$sev" == "off" ]] && return 0
  gcount="$(jq '.lint.contradictions.exclusiveGroups | length // 0' <<<"$CONFIG")"
  [[ "$gcount" -eq 0 ]] && return 0

  # Resolve files once (union); store absolute paths.
  local -a files=()
  mapfile -t files < <(resolve_files ".lint.contradictions.files" "README.md" "CLAUDE.md")
  [[ "${#files[@]}" -eq 0 ]] && return 0

  gi=0
  while [[ $gi -lt $gcount ]]; do
    tcount="$(jq --argjson g "$gi" '.lint.contradictions.exclusiveGroups[$g] | length' <<<"$CONFIG")"
    if [[ "$tcount" -lt 2 ]]; then gi=$((gi+1)); continue; fi
    local -a terms=()
    mapfile -t terms < <(jq -r --argjson g "$gi" '.lint.contradictions.exclusiveGroups[$g][]' <<<"$CONFIG")
    # Collect terms that are present anywhere across the union, in config order.
    local -a present=()
    local term abs found
    for term in "${terms[@]}"; do
      found=""
      for abs in "${files[@]}"; do
        if term_present "$abs" "$term"; then found="yes"; break; fi
      done
      [[ -n "$found" ]] && present+=("$term")
    done
    if [[ "${#present[@]}" -ge 2 ]]; then
      # Join with ", " explicitly — the IFS-on-[*] trick only uses IFS's first char.
      local joined="" t
      for t in "${present[@]}"; do
        [[ -n "$joined" ]] && joined+=", "
        joined+="$t"
      done
      # Sort key includes the zero-padded group index so groups keep config order
      # even when two groups share a first term.
      add_finding "$sev" 0 "$(printf '%010d:%s' "$gi" "${terms[0]}")" \
        "[agent-sync lint] contradiction: group {$joined} — multiple exclusive terms present"
    fi
    gi=$((gi+1))
  done
}
check_contradictions
```

> **NOTE:** The finding message lists the present terms in config order (`{Supabase, Postgres}`),
> matching the test substrings. The sort key is `<zero-padded group index>:<first term>`. Emit order is
> fixed at CHECK_IDX `0`, so contradictions print before line-budget (`1`) and soft-prefs (`2`).
> Reminder: ensure `check_contradictions` is invoked **before** the final `report` call, and the
> three check calls appear in source order contradictions/line-budget/soft-prefs is **not**
> required (sort handles ordering) — but keep all three calls above `report`.

- [ ] **Step 4: Run to verify pass**

Run: `bash plugins/agent-sync/tests/run-lint-tests.sh`
Expected: PASS (`FAIL=0`).

- [ ] **Step 5: Add the end-to-end acceptance + determinism cases, then commit**

Append before the final summary block:

```bash
# --- Acceptance: clean synced fixture -> no findings, exit 0 ---
CLEAN="$TMP/clean"; mkdir -p "$CLEAN/.agent-sync" "$CLEAN/.claude/rules"
printf '# App\nWe use Postgres on Hetzner.\n' > "$CLEAN/README.md"
printf '# Claude\nWe use Postgres on Hetzner.\n' > "$CLEAN/CLAUDE.md"
printf '# Arch\nKeep modules small.\n' > "$CLEAN/.claude/rules/architecture.md"
cat > "$CLEAN/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],
"lint":{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"],["Vercel","Hetzner"]]},
"lineBudget":{"max":200,"files":["CLAUDE.md",".claude/rules/*.md"]},
"softPreferences":{"files":["CLAUDE.md",".claude/rules/*.md"]}}}
JSON
assert_stdout_contains "clean fixture -> 0/0 summary" "0 errors, 0 warnings" -- --config "$CLEAN/.agent-sync/sources.json" --root "$CLEAN"
assert_exit "clean fixture -> exit 0" 0 -- --config "$CLEAN/.agent-sync/sources.json" --root "$CLEAN"

# --- Determinism: two runs of CT1 produce byte-identical output ---
D1="$(bash "$LINT" --config "$CT1" --root "$TMP/ct" 2>/dev/null)"
D2="$(bash "$LINT" --config "$CT1" --root "$TMP/ct" 2>/dev/null)"
if [[ "$D1" == "$D2" ]]; then echo "PASS: deterministic output"; PASS=$((PASS+1));
else echo "FAIL: deterministic output differs"; FAIL=$((FAIL+1)); fi
```

```bash
git add plugins/agent-sync/scripts/lint.sh plugins/agent-sync/tests/run-lint-tests.sh
git commit -m "feat(agent-sync): contradiction lint check + acceptance/determinism tests (#55)"
```

---

### Task 6: Wire into commands, docs, CI template, and version bump

Integrate the finished `lint.sh`: run it from `/agent-sync:check`, vendor it in `/agent-sync:init`, run it in the GHA template, document the `lint` block, and bump the version.

**Files:**
- Modify: `plugins/agent-sync/commands/check.md`
- Modify: `plugins/agent-sync/commands/init.md`
- Modify: `plugins/agent-sync/skills/agent-sync/references/github-actions-template.md`
- Modify: `plugins/agent-sync/skills/agent-sync/references/sources-json-format.md`
- Modify: `plugins/agent-sync/README.md`
- Modify: `plugins/agent-sync/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json` (repo root)

**Interfaces:** none (integration + docs).

- [ ] **Step 1: Update `/agent-sync:check` to also run the linter**

In `plugins/agent-sync/commands/check.md`, after the existing drift-check `bash "$GEN" ... --check` block (step 3), add a new step that resolves and runs `lint.sh` with the same vendored-copy precedence, and update the "Report results" step. Insert before the final "Report results clearly" section:

```markdown
4. Run the linter (doc-drift contradictions + rules-file bloat). Use the same vendored-first
   precedence as the generator so the command matches CI:
   ```bash
   if [ -f "tools/agent-sync/lint.sh" ]; then
     LINT=tools/agent-sync/lint.sh
   elif [ -f ".agent-sync/lint.sh" ]; then
     LINT=.agent-sync/lint.sh
   else
     LINT="${CLAUDE_PLUGIN_ROOT}/scripts/lint.sh"
   fi
   bash "$LINT" --config "<path-to-sources.json>"; lint_rc=$?
   ```
   - `lint_rc=0`: no error-severity findings (warnings may still print).
   - `lint_rc=1`: at least one error-severity finding.
   - `lint_rc=2`: a **configuration error** in the `lint` block — surface it as a config problem to
     fix, distinct from drift or content findings.
```

Then change the final "Report results clearly" section so the overall result is a failure if
**either** the drift check or the lint returns non-zero, reporting drift, lint findings, and lint
config errors (`rc=2`) distinctly.

- [ ] **Step 2: Verify the check.md edit references lint.sh**

Run: `grep -c 'lint.sh' plugins/agent-sync/commands/check.md`
Expected: `≥ 3` (the three precedence lines).

- [ ] **Step 3: Update `/agent-sync:init` to vendor lint.sh and run it in CI**

In `plugins/agent-sync/commands/init.md` step 6 ("Vendor the generator script"), extend the vendoring snippet to also copy `lint.sh`:

```bash
for s in generate.sh lint.sh; do
  awk -v v="$VER" 'NR==1{print; print "# Vendored by agent-sync v" v " — re-run /agent-sync:init to refresh."; next} {print}' \
    "${CLAUDE_PLUGIN_ROOT}/scripts/$s" > "$DEST_DIR/$s"
  chmod +x "$DEST_DIR/$s"
done
```

In step 7 ("Offer CI template"), update the embedded workflow's "Check AGENTS.md sync" step to run
the linter after the drift check (use the `tools/agent-sync` / `.agent-sync` precedence already in
the template):

```yaml
      - name: Check AGENTS.md sync and lint
        run: |
          if [ -f "tools/agent-sync/generate.sh" ]; then
            DIR=tools/agent-sync
          elif [ -f ".agent-sync/generate.sh" ]; then
            DIR=.agent-sync
          else
            echo "agent-sync scripts not found. Run /agent-sync:init to vendor them."
            exit 1
          fi
          bash "$DIR/generate.sh" --check
          bash "$DIR/lint.sh"
```

- [ ] **Step 4: Mirror the workflow change in the reference template**

Update `plugins/agent-sync/skills/agent-sync/references/github-actions-template.md` so its workflow
block is byte-identical to the one now in `init.md` (the file itself states "keep the two copies
identical"). Replace the old single-step `Check AGENTS.md sync` block with the combined
sync-and-lint block from Step 3.

- [ ] **Step 5: Verify both workflow copies run the linter**

Markdown range-diffing is brittle, so just confirm both embedded workflows invoke `lint.sh`:

```bash
for f in plugins/agent-sync/commands/init.md \
         plugins/agent-sync/skills/agent-sync/references/github-actions-template.md; do
  grep -q 'bash "$DIR/lint.sh"' "$f" && echo "OK: $f" || echo "MISSING lint.sh in: $f"
done
```
Expected: `OK:` for both files. Visually confirm the two YAML blocks are identical (the
reference file states the two copies must match).

- [ ] **Step 6: Document the `lint` block in sources-json-format.md**

Append a `## Lint` section to `plugins/agent-sync/skills/agent-sync/references/sources-json-format.md`
documenting: the three checks, all fields, default severities (`warn`), default file lists, the
`error`/`warn`/`off` severities, glob semantics (relative to root, no `**`), the
non-alphanumeric-boundary contradiction matching with its known limitations (co-occurrence ≠ proof;
short ambiguous terms; no aliases/section-scoping in v1), raw-line-count budget, the line-leading
`prefer` rule (all lines incl. code fences scanned), and exit codes 0/1/2. Include this example:

````markdown
## Lint (optional)

```jsonc
"lint": {
  "contradictions": {
    "severity": "warn",                      // error | warn | off (default warn)
    "files": ["README.md", "CLAUDE.md"],     // default if omitted
    "exclusiveGroups": [["Supabase", "Postgres"], ["Vercel", "Hetzner"]]
  },
  "lineBudget":     { "severity": "warn", "max": 200, "files": ["CLAUDE.md", ".claude/rules/*.md"] },
  "softPreferences":{ "severity": "warn",             "files": ["CLAUDE.md", ".claude/rules/*.md"] }
}
```

- **No `lint` block** → linter prints nothing and exits 0 (fully backward compatible).
- Exit codes: `0` no error-severity findings · `1` an error-severity finding · `2` config error.
- Contradiction matching is whole-word with non-alphanumeric boundaries (handles `.NET`, `Node.js`,
  `C++`; `Postgres` does not match inside `PostgreSQL`). Co-occurrence is a heuristic, not proof —
  hence the `warn` default. Aliases and section scoping are out of scope in v1.
- Line budget counts raw lines (`wc -l`, blanks and code fences included).
- Soft-preference flags line-leading `prefer`/`prefers`/`prefer to`/`preferred`; mid-sentence prose
  is not flagged. All lines are scanned, including fenced code examples.
````

- [ ] **Step 7: Update README.md (Linting subsection + Components row)**

In `plugins/agent-sync/README.md`, add a short "Linting" subsection under "How It Works" describing
the three checks and that they run in `/agent-sync:check`, and add a Components-table row:

```markdown
| `lint.sh` | Script | Lint config for stack contradictions, rules-file bloat, and soft directives |
```

- [ ] **Step 8: Bump the version in both manifests**

Edit `plugins/agent-sync/.claude-plugin/plugin.json`: change `"version": "0.2.2"` → `"version": "0.3.0"`.

Find and edit the agent-sync entry in the root `.claude-plugin/marketplace.json` to `0.3.0` as well:

```bash
grep -n '"name": "agent-sync"' -A8 .claude-plugin/marketplace.json
```
Update that entry's `version` field to `0.3.0`.

- [ ] **Step 9: Verify version sync**

Run:
```bash
PV=$(jq -r .version plugins/agent-sync/.claude-plugin/plugin.json)
MV=$(jq -r '.plugins[] | select(.name=="agent-sync") | .version' .claude-plugin/marketplace.json)
echo "plugin=$PV marketplace=$MV"; [ "$PV" = "0.3.0" ] && [ "$MV" = "0.3.0" ] && echo "VERSION OK"
```
Expected: `plugin=0.3.0 marketplace=0.3.0` and `VERSION OK`.

- [ ] **Step 10: Run the full agent-sync test suite**

Run:
```bash
bash plugins/agent-sync/tests/run-lint-tests.sh && \
bash plugins/agent-sync/tests/run-generate-tests.sh && \
bash plugins/agent-sync/tests/run-tests.sh
```
Expected: every runner ends `FAIL=0` and exits 0 (lint, generator, and hook suites all green).

- [ ] **Step 11: Commit**

```bash
git add plugins/agent-sync/commands/check.md plugins/agent-sync/commands/init.md \
  plugins/agent-sync/skills/agent-sync/references/github-actions-template.md \
  plugins/agent-sync/skills/agent-sync/references/sources-json-format.md \
  plugins/agent-sync/README.md plugins/agent-sync/.claude-plugin/plugin.json \
  .claude-plugin/marketplace.json
git commit -m "feat(agent-sync): wire lint into check/init/CI + docs, bump to 0.3.0 (#55)"
```

---

## Self-Review

**Spec coverage:**
- New `scripts/lint.sh`, CLI/config/root conventions → Task 1. ✓
- No-lint-block → exit 0 silent; empty block → summary → Task 1. ✓
- "Only configured blocks run"; default file lists → Tasks 2–5 (per-check `has(...)` gates + `resolve_files` defaults). ✓
- Config validation (severity/max/files/groups/malformed JSON) → exit 2 → Task 2. ✓
- Severities error/warn/off + defaults warn → each check (Tasks 3–5). ✓
- Contradictions: non-alphanumeric boundary matching, ≥2 distinct terms, punctuation/multiword, PostgreSQL guard, <2-term skip → Task 5. ✓
- Line budget: raw `wc -l`, glob/dedup/missing-skip, defaults → Task 3. ✓
- Soft preferences: line-leading ERE, mid-sentence excluded, fences scanned → Task 4. ✓
- Reporting: LC_ALL=C, sort keys, path normalization, dedup, summary rule, exit 0/1/2 → Tasks 1, 3 (helpers), 5. ✓
- Wiring: check.md, init.md vendoring, GHA template (+ ref copy), sources-json-format.md, README, version bump in both manifests → Task 6. ✓
- Tests cover all 15 spec acceptance/robustness cases → distributed across Tasks 1–5. ✓

**Placeholder scan:** No TBD/TODO. Every code step shows complete code. The one substitution hazard (jq `|` rendered as `｜` in Task 2) is called out explicitly with instructions to replace.

**Type/name consistency:** `add_finding SEV IDX SORTKEY MSG`, `resolve_files JQPATH DEFAULTS...`, `relpath`, `report`, `cfg_err`, `term_present`, `ere_escape`, `check_line_budget`/`check_soft_preferences`/`check_contradictions` — names are used identically across the tasks that define and call them. CHECK_IDX values (0/1/2) are consistent between `add_finding` calls and the sort comment.
