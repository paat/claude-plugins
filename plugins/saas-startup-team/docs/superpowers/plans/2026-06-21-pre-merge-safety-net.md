# Pre-merge Safety Net Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every project the `saas-startup-team` plugin scaffolds inherit a pre-merge safety net: a canonical full-suite entrypoint (`check.sh`), a PR-triggered CI gate, an anti-duplication invariant principle, and golden/"green-but-wrong" correctness guidance.

**Architecture:** One named entrypoint, `check.sh`, called identically by CI, the tech-founder build ritual, and `/improve`. Bootstrap scaffolds `check.sh` + a GitHub Actions PR workflow from templates (idempotent, check-before-write) and queues a sequenced `[HUMAN]` branch-protection task. Guidance edits (anti-duplication principle, derived-output correctness, green-but-wrong QA) land in the tech-founder skill, quality-standards reference, and both business-founder agents.

**Tech Stack:** Bash 4+ (POSIX tools only), GitHub Actions YAML, GitHub `gh` CLI, jq. Plugin's own bash test harness (`tests/run-tests.sh`).

## Global Constraints

- Bash 4+, POSIX tools only (no GNU-only flags that fail on the documented toolset).
- No hardcoded company/project names anywhere; project-specific values use template variables / `{{TOKENS}}`.
- External deps (jq, awk, sed) are already documented; do not add new runtime deps.
- Version MUST bump in BOTH `.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`, kept in sync: `0.41.2` → `0.42.0`.
- `check.sh` template shebang is `#!/usr/bin/env bash`.
- All bootstrap scaffolding must be **idempotent** (check-before-write; re-run never duplicates or overwrites user content).
- `run_suite` calling convention is fixed: `run_suite <label> <single-shell-command-string>`, executed via `bash -c`.
- All paths below are relative to the plugin root `plugins/saas-startup-team/` unless stated otherwise. The repo root is `/mnt/data/ai/claude-plugins`.
- Work happens on branch `feat/pre-merge-safety-net` (already created).
- Run the full suite with: `bash plugins/saas-startup-team/tests/run-tests.sh` (from repo root).

---

### Task 1: `check.sh` template — core driver + guards

**Files:**
- Create: `plugins/saas-startup-team/templates/check.sh`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new suite `test_check_sh_template`, registered in `main()`)

**Interfaces:**
- Produces: an executable bash template with a top `REQUIRED_SUITES=()` array; suite functions `backend_tests`, `frontend_tests`, `lint`, `typecheck`, `golden_tests` (each shipped as `suite_stub <name>`); helpers `suite_stub <name>` (records nothing, returns 1 with an "unwired" message) and `run_suite <label> <cmd-string>` (marks the suite as ran via the `RAN` array, runs `bash -c "$cmd"`, records pass/fail, returns the command's status); a driver that iterates `REQUIRED_SUITES`, calls each, and applies Guard 1 (zero ran → fail) and Guard 2 (a declared suite that never called `run_suite` → fail).
- Consumes: nothing (leaf artifact).

- [ ] **Step 1: Write the failing test suite skeleton**

Add this function to `plugins/saas-startup-team/tests/run-tests.sh` (before `main()`), and add the line `test_check_sh_template` to `main()` after `test_templates`:

```bash
# ---------------------------------------------------------------------------
# Suite W: check.sh template (canonical full-suite entrypoint)
# ---------------------------------------------------------------------------

test_check_sh_template() {
  echo -e "\n${CYAN}Suite W: check.sh template${NC}"
  local tmpl="$PLUGIN_ROOT/templates/check.sh"
  local workdir ec output

  # W1: template exists and has the bash shebang
  assert_file_exists "W1: check.sh template exists" "$tmpl"
  assert_file_contains "W2: uses env bash shebang" "$tmpl" '#!/usr/bin/env bash'
  assert_file_contains "W3: has REQUIRED_SUITES array" "$tmpl" 'REQUIRED_SUITES='
  assert_file_contains "W4: has run_suite helper" "$tmpl" 'run_suite()'
  assert_file_contains "W5: has suite_stub helper" "$tmpl" 'suite_stub()'
  assert_file_contains "W6: VERIFY COMPLETE banner present" "$tmpl" 'VERIFY COMPLETE'

  # W7: vacuous run (no suites declared) → non-zero, refuses to report success
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W7: vacuous run fails (non-zero)" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W7b: refuses to report success" "$output" "no suites ran"
  rm -rf "$workdir"

  # W8: a wired, green suite → exit 0
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  # declare + wire frontend_tests to a trivially-green command.
  # NOTE: the wiring seds match `^name().*` so they are agnostic to the
  # template's column-aligned spacing between `()` and `{`.
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(frontend_tests)/' "$workdir/check.sh"
  sed -i "s|^frontend_tests().*|frontend_tests() { run_suite frontend_tests 'true'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_exit_code "W8: wired green suite passes" "$ec" 0
  rm -rf "$workdir"

  # W9: a declared-but-unwired suite → non-zero (Guard 2)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(backend_tests)/' "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W9: unwired declared suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W9b: names the unwired suite" "$output" "backend_tests"
  rm -rf "$workdir"

  # W9c: declared suite hand-edited to return 0 WITHOUT run_suite → still fails (Guard 2)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(backend_tests)/' "$workdir/check.sh"
  sed -i 's|^backend_tests().*|backend_tests() { true; }|' "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W9c: declared-but-never-ran suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W9d: Guard 2 names never-ran suite" "$output" "never ran a command"
  rm -rf "$workdir"

  # W10: a wired, RED suite → non-zero
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(lint)/' "$workdir/check.sh"
  sed -i "s|^lint().*|lint() { run_suite lint 'false'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W10: wired red suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  rm -rf "$workdir"

  # W11: mid-command failure in an &&-chain propagates (no pipefail masking)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(typecheck)/' "$workdir/check.sh"
  sed -i "s|^typecheck().*|typecheck() { run_suite typecheck 'false \&\& true'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W11: &&-chain mid failure fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  rm -rf "$workdir"
}
```

- [ ] **Step 2: Run the new suite to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -A2 'Suite W'`
Expected: FAIL — `W1: check.sh template exists (file not found: .../templates/check.sh)` (and dependent assertions fail).

- [ ] **Step 3: Create the `check.sh` template**

Create `plugins/saas-startup-team/templates/check.sh`:

```bash
#!/usr/bin/env bash
# check.sh — canonical full-suite entrypoint for this project.
#
# This ONE script is what CI runs, what the tech-founder runs before every
# handoff, and what /improve runs. Local and CI cannot diverge because they
# call the same script by name.
#
# VERIFY COMPLETE: wire REQUIRED_SUITES + each suite below to your real
# commands — this gate FAILS until you do. Declare every suite your project
# has (backend, frontend, lint, typecheck, golden/integration). A suite you
# declare but leave unwired fails the run on purpose.
#
# LIMITATION: this proves each declared suite RAN and its command SUCCEEDED.
# It cannot prove a command was meaningful (e.g. a runner that exits 0 on
# "0 tests collected"). Wire real commands and add golden tests for
# computed-output correctness.

set -uo pipefail

# --- Declare which suites this project has (edit me) --------------------------
REQUIRED_SUITES=()

# --- Suite functions: replace each stub body with run_suite <label> '<cmd>' --
# Examples (uncomment + adapt):
#   frontend_tests() { run_suite frontend_tests 'npm test'; }
#   lint()           { run_suite lint 'npm run lint && npm run format:check'; }
#   backend_tests()  { run_suite backend_tests 'pytest -q'; }
#   typecheck()      { run_suite typecheck 'npx tsc --noEmit'; }
#   golden_tests()   { run_suite golden_tests 'npm run test:golden'; }
backend_tests()  { suite_stub backend_tests; }
frontend_tests() { suite_stub frontend_tests; }
lint()           { suite_stub lint; }
typecheck()      { suite_stub typecheck; }
golden_tests()   { suite_stub golden_tests; }

# --- Machinery (do not edit below) -------------------------------------------
RAN=()                 # suites that actually invoked run_suite
FAILED=()              # suites that failed (red command, or never ran)
declare -A STATUS      # label -> pass|fail (only set by run_suite)

suite_stub() {
  echo "  ✗ SUITE '$1' is declared in REQUIRED_SUITES but not wired up — edit check.sh"
  return 1
}

ran_contains() {
  local x="$1" r
  for r in "${RAN[@]:-}"; do [ "$r" = "$x" ] && return 0; done
  return 1
}

run_suite() {
  local label="$1" cmd="$2"
  RAN+=("$label")
  echo "  ▶ $label: $cmd"
  if bash -c "$cmd"; then
    echo "  ✓ $label passed"
    STATUS[$label]="pass"
    return 0
  else
    echo "  ✗ $label failed"
    STATUS[$label]="fail"
    return 1
  fi
}

main() {
  local suite

  # Guard 1: anti-vacuous — nothing declared at all (the freshly-scaffolded
  # state). Triggers before running so an empty manifest can never look green.
  local declared=0
  for suite in "${REQUIRED_SUITES[@]:-}"; do [ -n "$suite" ] && declared=$((declared+1)); done
  if [ "$declared" -eq 0 ]; then
    echo "check.sh: no suites ran — refusing to report success."
    echo "Declare and wire suites in REQUIRED_SUITES (see VERIFY COMPLETE banner)."
    exit 1
  fi

  # Run each declared suite. We judge by RAN + STATUS, not the function's raw
  # return, so a suite that returns 0 WITHOUT calling run_suite cannot slip by.
  for suite in "${REQUIRED_SUITES[@]:-}"; do
    [ -z "$suite" ] && continue
    "$suite" || true
  done

  # Guard 2: every declared suite must have actually run a command via
  # run_suite (catches both unwired suite_stub and a hand-edited `{ true; }`),
  # and any suite whose command failed is a failure.
  for suite in "${REQUIRED_SUITES[@]:-}"; do
    [ -z "$suite" ] && continue
    if ! ran_contains "$suite"; then
      echo "  ✗ SUITE '$suite' declared but never ran a command (Guard 2)"
      FAILED+=("$suite")
    elif [ "${STATUS[$suite]:-}" = "fail" ]; then
      FAILED+=("$suite")
    fi
  done

  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "check.sh: FAILED suites: ${FAILED[*]}"
    exit 1
  fi

  echo "check.sh: all ${#RAN[@]} suite(s) passed: ${RAN[*]}"
  exit 0
}

main "$@"
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Suite W|W[0-9]+'`
Expected: all `W1`–`W11` PASS.

- [ ] **Step 5: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/templates/check.sh plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): check.sh canonical full-suite entrypoint template (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 2: CI workflow template

**Files:**
- Create: `plugins/saas-startup-team/templates/ci-workflow.yml`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_check_sh_template` with CI-template assertions, or add `test_ci_workflow_template`)

**Interfaces:**
- Consumes: nothing.
- Produces: a GitHub Actions workflow file with `name: CI`, a `pull_request` trigger, one job with id `check`, a `{{STACK_SETUP}}` token line, and a final `run: ./check.sh` step.

- [ ] **Step 1: Write the failing test**

Append to `test_check_sh_template` (after W11), and ensure the file is referenced via `$PLUGIN_ROOT/templates/ci-workflow.yml`:

```bash
  # W12-W16: CI workflow template
  local ci="$PLUGIN_ROOT/templates/ci-workflow.yml"
  assert_file_exists "W12: ci-workflow.yml exists" "$ci"
  assert_file_contains "W13: workflow name is CI" "$ci" '^name: CI'
  assert_file_contains "W14: pull_request trigger" "$ci" 'pull_request'
  assert_file_contains "W15: job id check" "$ci" '^  check:'
  assert_file_contains "W16: runs ./check.sh" "$ci" './check.sh'
  assert_file_contains "W17: has STACK_SETUP token" "$ci" '{{STACK_SETUP}}'
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'W1[2-7]'`
Expected: FAIL — `W12: ci-workflow.yml exists (file not found ...)`.

- [ ] **Step 3: Create the workflow template**

Create `plugins/saas-startup-team/templates/ci-workflow.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main, master]

jobs:
  check:
    name: check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # {{STACK_SETUP}}

      - name: Run full regression suite
        run: ./check.sh
```

Note: the literal `{{STACK_SETUP}}` token sits alone on its own comment line so bootstrap can replace the whole line — with a detected runtime-setup block (Node/Python), or, when no stack is detected, with a `[TECH-FOUNDER: ...]` marker for the founder to fill. Keeping it a single token (no inline fallback) avoids leaving a stale comment in detected-stack repos.

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'W1[2-7]'`
Expected: `W12`–`W17` PASS.

- [ ] **Step 5: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/templates/ci-workflow.yml plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): pull_request CI workflow template running ./check.sh (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 3: Bootstrap scaffolding — CI + check.sh + branch-protection task

**Files:**
- Modify: `plugins/saas-startup-team/commands/bootstrap.md` (add Step 6.5 "Scaffold the pre-merge safety net" before the existing "Step 7: Initialize Git and Commit"; extend Step 7's `git add`)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new suite `test_bootstrap_safety_net`, registered in `main()`)

**Interfaces:**
- Consumes: `templates/check.sh`, `templates/ci-workflow.yml` (Tasks 1–2) via `${CLAUDE_PLUGIN_ROOT}/templates/`.
- Produces: a single extractable `bash` block under the heading `## Step 6.5: Scaffold the pre-merge safety net` that, given `CLAUDE_PLUGIN_ROOT` set and run from a project root, creates `.github/workflows/ci.yml` (with `{{STACK_SETUP}}` substituted by detection), an executable `./check.sh` (with detection suggestions appended as comments), and appends a sequenced `[HUMAN]` branch-protection task to `.startup/human-tasks.md` — all idempotent.

- [ ] **Step 1: Write the failing test**

Add to `plugins/saas-startup-team/tests/run-tests.sh` (before `main()`), and add `test_bootstrap_safety_net` to `main()` after `test_check_sh_template`:

```bash
# ---------------------------------------------------------------------------
# Suite X: bootstrap pre-merge safety-net scaffolding
# ---------------------------------------------------------------------------

test_bootstrap_safety_net() {
  echo -e "\n${CYAN}Suite X: bootstrap safety-net scaffolding${NC}"
  local cmd="$PLUGIN_ROOT/commands/bootstrap.md"
  local workdir ec output

  # Extract the scaffolding bash block from bootstrap.md
  local script
  workdir=$(mktemp -d)
  extract_md_bash "$cmd" "## Step 6.5: Scaffold the pre-merge safety net" > "$workdir/scaffold.sh"

  # X1: the block is non-empty
  assert_equals "X1: scaffold block extracted" "$([ -s "$workdir/scaffold.sh" ] && echo yes || echo no)" "yes"

  # X2-X5: no stack present → scaffolds files with the placeholder marker
  mkdir -p "$workdir/repo"; (cd "$workdir/repo" && git init -q)
  mkdir -p "$workdir/repo/.startup"
  ec=0; output=$(cd "$workdir/repo" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X2: scaffold runs cleanly" "$ec" 0
  assert_file_exists "X3: ci.yml created" "$workdir/repo/.github/workflows/ci.yml"
  assert_file_exists "X4: check.sh created" "$workdir/repo/check.sh"
  assert_equals "X5: check.sh executable" "$([ -x "$workdir/repo/check.sh" ] && echo yes || echo no)" "yes"
  assert_file_contains "X6: human-tasks has branch-protection task" "$workdir/repo/.startup/human-tasks.md" "branch protection"
  assert_file_contains "X7: human task is sequenced after green CI" "$workdir/repo/.startup/human-tasks.md" "first CI run"
  # no stack detected → placeholder marker remains in ci.yml
  assert_file_contains "X8: no-stack keeps TECH-FOUNDER marker" "$workdir/repo/.github/workflows/ci.yml" "TECH-FOUNDER"

  # X9: idempotent — re-run does not duplicate the human task or error
  ec=0; output=$(cd "$workdir/repo" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X9: re-run is idempotent (clean exit)" "$ec" 0
  local count
  # Count the unique idempotency-guard heading (the phrase "branch protection"
  # itself appears twice per block: in the heading and in the UI instructions).
  count=$(grep -c "Require the CI check (branch protection)" "$workdir/repo/.startup/human-tasks.md")
  assert_equals "X10: branch-protection task not duplicated" "$count" "1"

  # X11-X13: node stack detected → STACK_SETUP substituted with setup-node
  rm -rf "$workdir/repo2"; mkdir -p "$workdir/repo2/.startup"; (cd "$workdir/repo2" && git init -q)
  echo '{"scripts":{"test":"jest"}}' > "$workdir/repo2/package.json"
  ec=0; output=$(cd "$workdir/repo2" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X11: node scaffold runs cleanly" "$ec" 0
  assert_file_contains "X12: node setup injected" "$workdir/repo2/.github/workflows/ci.yml" "setup-node"
  assert_file_contains "X13: check.sh has node detection hint" "$workdir/repo2/check.sh" "DETECTED"

  rm -rf "$workdir"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Suite X|X[0-9]+'`
Expected: FAIL — `X1: scaffold block extracted` is `no` (heading not present yet).

- [ ] **Step 3: Add the scaffolding step to `bootstrap.md`**

Insert this section in `plugins/saas-startup-team/commands/bootstrap.md` immediately before `## Step 7: Initialize Git and Commit`:

````markdown
## Step 6.5: Scaffold the pre-merge safety net

Scaffold the CI gate and the canonical full-suite entrypoint so every project
inherits a pre-merge safety net. Idempotent — existing files are left untouched.

```bash
set -uo pipefail

# 1. Canonical entrypoint: check.sh (copy template, make executable)
if [ ! -f check.sh ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/templates/check.sh" check.sh
  chmod +x check.sh

  # Detection: append INERT commented suggestions only. REQUIRED_SUITES stays
  # empty, so a mis-detection can never produce a falsely-green gate.
  if [ -f package.json ]; then
    {
      echo ""
      echo "# DETECTED package.json — consider:"
      if command -v jq >/dev/null 2>&1 && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
        echo "#   REQUIRED_SUITES+=(frontend_tests); frontend_tests() { run_suite frontend_tests 'npm test'; }"
      fi
      if command -v jq >/dev/null 2>&1 && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
        echo "#   REQUIRED_SUITES+=(lint); lint() { run_suite lint 'npm run lint'; }"
      fi
      [ -f tsconfig.json ] && echo "#   REQUIRED_SUITES+=(typecheck); typecheck() { run_suite typecheck 'npx tsc --noEmit'; }"
    } >> check.sh
  fi
  if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.cfg ]; then
    {
      echo ""
      echo "# DETECTED Python project — consider:"
      echo "#   REQUIRED_SUITES+=(backend_tests); backend_tests() { run_suite backend_tests 'pytest -q'; }"
    } >> check.sh
  fi
fi

# 2. CI workflow: .github/workflows/ci.yml (copy template, substitute STACK_SETUP)
if [ ! -f .github/workflows/ci.yml ]; then
  mkdir -p .github/workflows
  cp "${CLAUDE_PLUGIN_ROOT}/templates/ci-workflow.yml" .github/workflows/ci.yml

  # Build the runtime-setup block. Install command depends on which lock/manifest
  # files exist so CI does not fail before ./check.sh (npm ci needs a lockfile;
  # pip -r needs requirements.txt).
  setup=""
  if [ -f package.json ]; then
    if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      setup='      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n          cache: npm\n      - run: npm ci'
    else
      setup='      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n      - run: npm install'
    fi
  elif [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.cfg ]; then
    if [ -f requirements.txt ]; then
      pyinstall='pip install -r requirements.txt'
    else
      pyinstall='pip install -e .'
    fi
    setup="      - uses: actions/setup-python@v5\n        with:\n          python-version: \"3.12\"\n      - run: $pyinstall"
  else
    # No stack detected: leave a marker for the tech-founder to fill in.
    setup='      # [TECH-FOUNDER: add language/runtime setup for your stack, then\n      #  install deps, before ./check.sh runs.]'
  fi
  # Replace the whole {{STACK_SETUP}} token line. GNU sed expands \n in the
  # replacement to newlines, producing the multi-line YAML block.
  sed -i "s|.*{{STACK_SETUP}}.*|$setup|" .github/workflows/ci.yml
fi

# 3. Branch-protection [HUMAN] task (sequenced, idempotent).
# NOTE: do NOT put fenced code blocks inside this heredoc — the test harness's
# markdown bash-block extractor stops at the first closing fence. Commands are
# shown indented as plain text instead.
mkdir -p .startup
touch .startup/human-tasks.md
if ! grep -q "Require the CI check (branch protection)" .startup/human-tasks.md; then
  cat >> .startup/human-tasks.md <<'TASK'

## [HUMAN] Require the CI check (branch protection)

Sequencing: do this ONLY after the tech-founder has finalized `check.sh` and the
first CI run on a real PR is green — otherwise you block every PR on a stub.

1. Get the exact check name from the first green PR:
   gh pr checks <pr-number>      (it is `check` or `CI / check` — copy verbatim)
2. Primary path — GitHub UI: Settings → Branches → Add branch protection rule →
   "Require status checks to pass before merging" → select that check.
3. CLI alternative (ONLY for a repo with no existing protection rule — a PUT to
   /protection REPLACES all protection settings; use the UI otherwise):

       BR=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
       CTX="check"   # replace with the exact name from step 1
       gh api -X PUT "repos/{owner}/{repo}/branches/$BR/protection" \
         -H "Accept: application/vnd.github+json" --input - <<JSON
       {
         "required_status_checks": { "strict": true, "contexts": ["$CTX"] },
         "enforce_admins": false,
         "required_pull_request_reviews": null,
         "restrictions": null
       }
       JSON

   Requires repo-admin + a token with the right scope. enforce_admins:false
   lets admins merge a red PR in an emergency — set true to bind admins too.
TASK
fi
```
````

- [ ] **Step 4: Extend the Step 7 commit `git add` list**

In `plugins/saas-startup-team/commands/bootstrap.md`, change the Step 7 staging command to include the new files:

```bash
git add docs/ .startup/.gitkeep .gitignore CLAUDE.md check.sh .github/workflows/ci.yml
git commit -m "chore: bootstrap project structure for saas-startup-team plugin"
```

- [ ] **Step 5: Run to verify the suite passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Suite X|X[0-9]+'`
Expected: `X1`–`X13` PASS.

- [ ] **Step 6: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/commands/bootstrap.md plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): bootstrap scaffolds CI gate + check.sh + branch-protection task (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 4: Route `/improve` and tech-founder through `./check.sh`

**Files:**
- Modify: `plugins/saas-startup-team/commands/improve.md` (Step 2 self-verify; Step 4 fix retry)
- Modify: `plugins/saas-startup-team/skills/tech-founder/SKILL.md` (Implementation Workflow step 7 build verification)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (new suite `test_canonical_entrypoint_wiring`, registered in `main()`) — the plugin-self drift guard

**Interfaces:**
- Consumes: the canonical entrypoint name `check.sh` (Task 1).
- Produces: `commands/improve.md`, `skills/tech-founder/SKILL.md`, and `templates/ci-workflow.yml` all reference `check.sh` by name (asserted by the drift test).

- [ ] **Step 1: Write the failing drift test**

Add to `plugins/saas-startup-team/tests/run-tests.sh` (before `main()`), and register `test_canonical_entrypoint_wiring` in `main()`:

```bash
# ---------------------------------------------------------------------------
# Suite Y: canonical entrypoint wiring (plugin-self drift guard)
# ---------------------------------------------------------------------------

test_canonical_entrypoint_wiring() {
  echo -e "\n${CYAN}Suite Y: canonical entrypoint wiring${NC}"
  assert_file_contains "Y1: improve.md names check.sh" \
    "$PLUGIN_ROOT/commands/improve.md" "check.sh"
  assert_file_contains "Y2: tech-founder SKILL names check.sh" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "check.sh"
  assert_file_contains "Y3: ci-workflow names check.sh" \
    "$PLUGIN_ROOT/templates/ci-workflow.yml" "check.sh"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Suite Y|Y[0-9]+'`
Expected: `Y1` and `Y2` FAIL (neither file references `check.sh` yet); `Y3` PASS (from Task 2).

- [ ] **Step 3: Edit `improve.md` Step 2**

In `plugins/saas-startup-team/commands/improve.md`, replace the Step 2 bullet:

```
> - Run the project's typecheck/lint and test commands (from `docs/architecture/architecture.md`; e.g. the build, unit, and relevant E2E suites). Fix every failure before handing off — do not hand off red.
```

with:

```
> - Run `./check.sh` — the canonical full-suite entrypoint (recorded in `docs/architecture/architecture.md`; it runs every suite: build, unit, lint, typecheck, golden/E2E). Fix every failure before handing off — do not hand off red.
```

- [ ] **Step 4: Edit `improve.md` Step 4 (fix retry)**

In the Step 4 FAIL-first-attempt dispatch, replace:

```
> Fix the issues, then re-run the project's typecheck/lint and test commands and confirm they pass before handing off. Write an updated handoff back to the business founder stating which checks you ran.
```

with:

```
> Fix the issues, then re-run `./check.sh` (the canonical full-suite entrypoint) and confirm it passes before handing off. Write an updated handoff back to the business founder stating that check.sh passed.
```

- [ ] **Step 5: Edit tech-founder SKILL.md build verification**

In `plugins/saas-startup-team/skills/tech-founder/SKILL.md`, replace the Implementation Workflow step 7 block:

```
7. BUILD VERIFICATION (mandatory before handoff):
   a. Run full build (npm run build or equivalent) — fix all errors
   b. Validate all modified .json files (python3 -m json.tool)
   c. Check TypeScript errors if applicable (npx tsc --noEmit)
```

with:

```
7. BUILD VERIFICATION (mandatory before handoff):
   a. Run `./check.sh` — the canonical full-suite entrypoint. Fix every failure.
      (If the stack was just chosen, finalize check.sh first — see Testing Approach.)
   b. Validate all modified .json files (python3 -m json.tool)
```

- [ ] **Step 6: Run to verify the suite passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Suite Y|Y[0-9]+'`
Expected: `Y1`–`Y3` PASS.

- [ ] **Step 7: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/commands/improve.md plugins/saas-startup-team/skills/tech-founder/SKILL.md plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): route /improve + tech-founder build verify through ./check.sh (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 5: Tech-founder guidance — canonical entrypoint, derived-output correctness, green-but-wrong

**Files:**
- Modify: `plugins/saas-startup-team/skills/tech-founder/SKILL.md` (Testing Approach section)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_canonical_entrypoint_wiring` with content assertions)

**Interfaces:**
- Consumes: `check.sh` concept (Task 1).
- Produces: Testing Approach section naming `check.sh` as canonical entrypoint + a "Derived-output correctness" subsection + a "green-but-wrong" risk statement.

- [ ] **Step 1: Write the failing test**

Append to `test_canonical_entrypoint_wiring`:

```bash
  assert_file_contains "Y4: tech-founder names canonical entrypoint" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "canonical"
  assert_file_contains "Y5: tech-founder has derived-output guidance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Derived-output correctness"
  assert_file_contains "Y6: tech-founder names green-but-wrong risk" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "green-but-wrong"
  assert_file_contains "Y7: tech-founder mentions golden suite" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "golden"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Y[4-7]'`
Expected: `Y4`–`Y7` FAIL.

- [ ] **Step 3: Replace the Testing Approach section**

In `plugins/saas-startup-team/skills/tech-founder/SKILL.md`, replace the `### Testing Approach` block:

```
### Testing Approach
- Write testable code (dependency injection, pure functions)
- Manual testing instructions in every handoff
- Focus on happy path + main error path
- Automated tests for critical business logic
```

with:

```
### Testing Approach
- Write testable code (dependency injection, pure functions)
- Manual testing instructions in every handoff
- Focus on happy path + main error path
- Automated tests for critical business logic

**Canonical entrypoint — `./check.sh`.** Every project has ONE script that runs
the full regression suite (backend + frontend + lint + typecheck + golden). CI,
your pre-handoff verification, and `/improve` all call it by name, so the local
and CI suites cannot drift. When you choose the stack, finalize `check.sh`: set
`REQUIRED_SUITES` to every suite the project has, wire each to its real command,
fill the CI `{{STACK_SETUP}}` block in `.github/workflows/ci.yml`, and record the
resolved commands in `docs/architecture/architecture.md`. A declared suite left
unwired fails the gate on purpose — never weaken `check.sh` to make it pass.

#### Derived-output correctness
For products whose correctness is *computed* — financial, billing, tax, invoicing,
scheduling, pricing — example-based unit tests pass while the integrated output is
wrong. Build a **golden / characterization / invariant fixture suite** over real
(anonymized) cases and wire it into `check.sh` (`golden_tests`) as a CI gate.
Treat invariants explicitly (e.g. balance sheet balances; VAT sign; totals
reconcile) and fail the suite when they break.

**"Green-but-wrong" risk class.** The app's own in-app validation passing does NOT
mean the output is correct — validation can be green on a wrong result. For
computed outputs, a green app is insufficient evidence; require golden-fixture
coverage and an independent spot-check (the business founder does the latter in QA).
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Y[4-7]'`
Expected: `Y4`–`Y7` PASS.

- [ ] **Step 5: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/skills/tech-founder/SKILL.md plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): derived-output correctness + green-but-wrong guidance (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 6: Anti-duplication invariant principle

**Files:**
- Modify: `plugins/saas-startup-team/skills/tech-founder/references/quality-standards.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_canonical_entrypoint_wiring`)

**Interfaces:**
- Consumes: nothing.
- Produces: a "Single source of truth for domain invariants" principle + a checklist line in quality-standards.md.

- [ ] **Step 1: Write the failing test**

Append to `test_canonical_entrypoint_wiring`:

```bash
  assert_file_contains "Y8: quality-standards has single-source-of-truth principle" \
    "$PLUGIN_ROOT/skills/tech-founder/references/quality-standards.md" "Single source of truth"
  assert_file_contains "Y9: quality-standards warns about re-derived rules" \
    "$PLUGIN_ROOT/skills/tech-founder/references/quality-standards.md" "re-derive"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Y[89]'`
Expected: `Y8`, `Y9` FAIL.

- [ ] **Step 3: Add the principle and checklist line**

In `plugins/saas-startup-team/skills/tech-founder/references/quality-standards.md`, add this checklist line to the `### While Writing Code` list (after the magic-numbers line):

```
- [ ] Did this change **re-derive a rule that already exists in another layer**? If a business predicate (tax test, acquisition check, VAT sign, eligibility rule) now lives in >1 place, consolidate or derive from one source — divergent copies are the #1 regression generator.
```

And add a new top-level section after the `## Code Quality Checklist` section (before `## UI Quality Standards`):

```
## Single source of truth for domain invariants

**Derive, don't duplicate domain/business rules across layers.** When the same
predicate is coded independently in the backend engine, an aggregator, and a
frontend gate, patching one silently desyncs the others — the dominant source of
recurring bugs. Define each business rule once and have every layer call or derive
from that single definition. In review, when a rule appears in more than one layer,
treat it as a defect to consolidate, not a coincidence.
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Y[89]'`
Expected: `Y8`, `Y9` PASS.

- [ ] **Step 5: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/skills/tech-founder/references/quality-standards.md plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): single-source-of-truth invariant principle (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 7: Business-founder QA — independent spot-check + duplicated-rule awareness

**Files:**
- Modify: `plugins/saas-startup-team/agents/business-founder-maintain.md`
- Modify: `plugins/saas-startup-team/agents/business-founder.md`
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (extend `test_canonical_entrypoint_wiring`)

**Interfaces:**
- Consumes: the "green-but-wrong" concept (Task 5).
- Produces: both agents' QA sections instruct an independent spot-check of computed values and a duplicated-rule awareness line.

- [ ] **Step 1: Write the failing test**

Append to `test_canonical_entrypoint_wiring`:

```bash
  assert_file_contains "Y10: maintain agent has independent spot-check" \
    "$PLUGIN_ROOT/agents/business-founder-maintain.md" "independent source"
  assert_file_contains "Y11: build agent has independent spot-check" \
    "$PLUGIN_ROOT/agents/business-founder.md" "independent source"
  assert_file_contains "Y12: maintain agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/agents/business-founder-maintain.md" "another layer"
  assert_file_contains "Y13: build agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/agents/business-founder.md" "another layer"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Y1[01]'`
Expected: `Y10`, `Y11` FAIL.

- [ ] **Step 3: Edit `business-founder-maintain.md`**

In `plugins/saas-startup-team/agents/business-founder-maintain.md`, in the `### 3. Regression Awareness` block, after the existing two bullets, add:

```
- For **computed/derived outputs** (totals, taxes, prices, schedules): verify at least one value against an **independent source** (hand calc or a reference doc) — do NOT trust in-app green checks; the app can be green on a wrong result.
- When a change touches a business rule, check whether the same rule lives in another layer that may now be desynced.
```

- [ ] **Step 4: Edit `business-founder.md`**

In `plugins/saas-startup-team/agents/business-founder.md`, in the browser-QA workflow list (the numbered "QA workflow" steps ending around step 9 "Visually verify..."), add two final steps (both phrases are asserted — keep "independent source" and "another layer"):

```
10. For computed/derived outputs, spot-check at least one value against an independent source (hand calc / reference doc) — do not trust in-app green checks; the app can be green on a wrong result.
11. When a change touches a business rule, check whether the same rule lives in another layer that may now be desynced.
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh 2>&1 | grep -E 'Y1[0-3]'`
Expected: `Y10`–`Y13` PASS.

- [ ] **Step 6: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/agents/business-founder-maintain.md plugins/saas-startup-team/agents/business-founder.md plugins/saas-startup-team/tests/run-tests.sh
git -C /mnt/data/ai/claude-plugins commit -m "feat(saas-startup-team): business QA spot-checks computed output vs independent source (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

### Task 8: Version bump + README

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json` (version)
- Modify: `.claude-plugin/marketplace.json` (matching version for this plugin)
- Modify: `plugins/saas-startup-team/README.md` (short feature note)
- Test: `plugins/saas-startup-team/tests/run-tests.sh` (the existing `test_plugin_config` / `test_cross_file_consistency` already assert version sync — confirm they still pass)

**Interfaces:**
- Consumes: nothing.
- Produces: both manifests at `0.42.0`; README documents `check.sh` + CI gate.

- [ ] **Step 1: Confirm current versions and the sync test**

Run: `grep -n '"version"' plugins/saas-startup-team/.claude-plugin/plugin.json; grep -n 'saas-startup-team' -A3 .claude-plugin/marketplace.json | grep version`
Expected: both show `0.41.2`.

- [ ] **Step 2: Bump `plugin.json`**

In `plugins/saas-startup-team/.claude-plugin/plugin.json`, change `"version": "0.41.2"` to `"version": "0.42.0"`.

- [ ] **Step 3: Bump `marketplace.json`**

In `/mnt/data/ai/claude-plugins/.claude-plugin/marketplace.json`, change the `saas-startup-team` entry's `"version": "0.41.2"` to `"version": "0.42.0"`.

- [ ] **Step 4: Add a README note**

In `plugins/saas-startup-team/README.md`, add a concise bullet to the feature list (find the existing features/commands list and add one line):

```
- **Pre-merge safety net**: `/bootstrap` scaffolds a canonical `check.sh` full-suite entrypoint and a `pull_request` CI workflow, and queues a branch-protection task — so regressions are caught before merge, not after.
```

- [ ] **Step 5: Run the full suite**

Run: `bash plugins/saas-startup-team/tests/run-tests.sh`
Expected: All tests pass (including version-sync assertions and all new W/X/Y suites). Final line: `All tests passed!`.

- [ ] **Step 6: Verify the pre-push version hook is satisfied**

Run: `git -C /mnt/data/ai/claude-plugins diff --stat HEAD~1` then attempt a dry check if a hook script exists: `ls /mnt/data/ai/claude-plugins/.githooks/`.
Expected: version-check hook present; versions in both manifests match (`0.42.0`).

- [ ] **Step 7: Commit**

```bash
git -C /mnt/data/ai/claude-plugins add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/saas-startup-team/README.md
git -C /mnt/data/ai/claude-plugins commit -m "chore(saas-startup-team): bump to 0.42.0 + README for pre-merge safety net (#63)

Claude-Session: https://claude.ai/code/session_01HmGZ9uHqBKwbjo6BPYcJZw"
```

---

## Final Verification

- [ ] Run the full plugin suite from repo root: `bash plugins/saas-startup-team/tests/run-tests.sh` → `All tests passed!`
- [ ] Manual smoke: in a throwaway temp git repo with `CLAUDE_PLUGIN_ROOT` pointed at the plugin, extract and run the Step 6.5 block; confirm `.github/workflows/ci.yml`, executable `check.sh`, and the `[HUMAN]` task appear; run `./check.sh` and confirm it fails vacuously with "no suites ran"; wire one suite and confirm it passes.
- [ ] Confirm versions synced in both manifests (`0.42.0`).
- [ ] Codex review of the final diff (`git diff main...HEAD` piped to `codex exec --dangerously-bypass-approvals-and-sandbox -`).
- [ ] Open the PR with `Closes #63` and a `## Regression test` section listing the new W/X/Y suites.

## Notes on residual limitations (carried from the spec)

- `check.sh` proves a declared suite *ran and succeeded*, not that its command was meaningful (e.g. "0 tests collected" exit 0). Mitigated by founder responsibility + golden tests.
- Branch protection is a sequenced `[HUMAN]` task, not automated — the gate is not enforced until a human enables the required check.
- The drift guard asserts call sites *reference* `check.sh`; it does not forbid adding ad-hoc commands beside it (generically detecting that is too noisy — accepted).
