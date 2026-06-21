# Design: Pre-merge safety net (#63)

**Date:** 2026-06-21
**Issue:** #63 — saas-startup-team: scaffold a pre-merge safety net
**Status:** approved (design), pending implementation plan
**Version target:** 0.41.2 → 0.42.0 (new user-facing capability)

## Problem

The plugin builds and ships products well but never establishes an **automated
pre-merge safety net**. A product built entirely through `/startup` + `/improve`
ends up with tests that run *locally if remembered* and a full suite that only
runs *after* merge — so regressions reach `main` (and customers). Closed #50 added
the incident-regression-test gate; four generic gaps remain:

1. `bootstrap`/`startup` scaffold **no CI gate or branch protection**.
2. **No single canonical "full regression" entrypoint** shared by the local ritual
   AND CI — so the two drift (downstream: a "full regression" gate that silently
   skipped the entire frontend suite).
3. **No guard against duplicated domain invariants across layers** — the dominant
   regression generator (the same predicate independently coded in backend +
   aggregator + frontend; patching one desyncs the others).
4. **No golden/invariant testing guidance for derived-output products** and no
   "green-but-wrong" risk class — for computed-correctness products (financial,
   billing, tax, scheduling, pricing) example unit tests pass while the integrated
   output is wrong and the app's own validation is green on a wrong result.

This matters most because the plugin is increasingly run in autonomous loops
(`/goal` + `/goal-deliver`): without a required pre-merge gate (#1/#2) and
correctness coverage that can fail on "green-but-wrong" (#4), an autonomous loop
confidently merges and ships wrong output.

Scope: distinct from closed #50 (incident-regression-test-per-fix). #50 ensures a
*fix* ships a test; this ensures the *project* has an enforced pre-merge gate, a
non-drifting full-suite entrypoint, an anti-duplication principle, and correctness
coverage for computed outputs.

## Architecture: structural coupling via one named entrypoint

The linchpin is **one script, called by name at every call site**: `check.sh`.

- CI runs `./check.sh`.
- The tech-founder pre-handoff build-verification ritual runs `./check.sh`.
- `/improve` (Step 2 tech-founder verify, Step 4 fix retry) runs `./check.sh`.

Because all callers name the same script, the local suite and the CI suite cannot
*independently* drift — there is a single source of truth for "what the full suite
is." This is a convention enforced by a single call site, **not** a hard runtime
guarantee: `check.sh` itself can still be left incomplete. The guards in Component 1
and the plugin-level test in Component 8 defend against the most likely drift, but
the design does not claim drift is structurally impossible.

Gaps #1 and #4's correctness coverage ride on top of this one entrypoint (CI runs
it; golden suites are wired into it).

### Honest framing of "enforced"

Bootstrap auto-scaffolds the **machinery** (the CI workflow + `check.sh`).
**Enforcement** of the gate — marking the CI check *required* on the default branch
— needs one privileged human action (admin on the repo), so it ships as a prominent
`[HUMAN]` task, not an automated step. Until that task is done, PRs *can* merge
without CI. The design makes that action unmissable and correctly *sequenced* (see
Component 3), rather than pretending the plugin can flip branch protection itself.

## Components

### Component 1 — `templates/check.sh` (new)

Stack-agnostic bash, bash 4+ / POSIX tools only. The canonical full-suite entrypoint.
Shebang is `#!/usr/bin/env bash` (never relies on `/bin/sh`).

**Structure:**

- A declared manifest near the top: `REQUIRED_SUITES=(...)` — the suites this project
  asserts it has (e.g. `backend_tests frontend_tests lint typecheck`). The
  tech-founder edits this list when the stack is chosen.
- One function per suite: `backend_tests`, `frontend_tests`, `lint`, `typecheck`,
  `golden_tests`. Each ships **unwired** as a stub that fails by construction:

  ```bash
  backend_tests() { suite_stub backend_tests; }   # replace body when wired
  ```

  where `suite_stub` prints `SUITE <name> is declared in REQUIRED_SUITES but not
  wired up — edit check.sh` and returns non-zero. So a declared-but-unwired suite
  makes `check.sh` fail (Guard 2 below) by construction, not by heuristics.

- A `run_suite <label> <command-string>` helper the founder uses to wire a suite.
  **Fixed calling convention:** exactly two arguments — a label and a *single shell
  command string* — which the helper runs via `bash -c "$cmd"`. This avoids the
  argv-vs-shell-string ambiguity; multi-command suites are a single `&&`-chained
  string:

  ```bash
  frontend_tests() { run_suite frontend_tests 'npm test'; }
  lint()           { run_suite lint 'npm run lint && npm run format:check'; }
  ```

  `run_suite` records that the suite **ran** (increments a counter / appends to a
  `RAN` list), runs the command string under `bash -c`, captures its exit status,
  records pass/fail, and returns that status. Because the whole string runs under
  one `bash -c`, an `&&`-chained mid-command failure propagates — avoiding the
  `pipefail`-without-`-e` masking mode (a multi-command function whose last command
  succeeds).

**Driver / guards:**

- `set -uo pipefail`.
- Iterate over `REQUIRED_SUITES`, call each named function, collect (do not
  short-circuit) failures, print a per-suite PASS/FAIL summary.
- **Guard 1 (anti-vacuous):** if the `RAN` count is 0, exit non-zero with
  `check.sh: no suites ran — refusing to report success`. Kills "green because
  nothing executed."
- **Guard 2 (fail-on-missing-declared):** any suite named in `REQUIRED_SUITES`
  whose function did not call `run_suite` (i.e. still a `suite_stub`) fails the run.
  Nobody can declare `frontend_tests` then leave it a no-op and still pass.
- Exit non-zero if any suite failed or any guard tripped; else exit 0 with a summary.

**Documented residual limitation:** bash cannot generically know a wired command
*discovered any tests* (e.g. a test runner that exits 0 on "0 collected"). `run_suite`
proves a suite *ran and its command succeeded*, not that the command was meaningful.
This residual is covered by the tech-founder's responsibility to wire real commands
and by the golden-suite guidance (Component 5), and is called out as a limitation in
the template header comment.

### Component 2 — `templates/ci-workflow.yml` (new)

A `pull_request`-triggered GitHub Actions workflow (GitHub is assumed — the plugin
already relies on `gh`).

- **Stable, deterministic names** so the required-status-check context is predictable:
  workflow `name: CI`, single job id `check`. The status-check context the human
  branch-protection command references is therefore stable (the job name `check`).
- Steps: `actions/checkout`, then a clearly-marked
  `# [TECH-FOUNDER: language/runtime setup for your stack — e.g. setup-node / setup-python]`
  placeholder block, then `run: ./check.sh`.
- For migrated repos where a stack already exists, bootstrap pre-fills the setup
  block by detection (see Component 3), but the placeholder/marker remains visible
  for the founder to confirm.

### Component 3 — `commands/bootstrap.md` (edits)

New steps, all idempotent and check-before-write (matching the existing bootstrap
style). Inserted as new numbered steps before the final git commit step:

- **Scaffold CI workflow:** if `.github/workflows/ci.yml` absent, write it from
  `templates/ci-workflow.yml`. If a stack is already detectable, pre-fill the setup
  block (Node when `package.json`; Python when `pyproject.toml`/`requirements.txt`).
- **Scaffold `check.sh`:** if absent, write it from `templates/check.sh` and
  `chmod +x`. Pre-fill `REQUIRED_SUITES` + obvious suite wirings **only by
  detection**, and emit a visible banner in the file header:
  `# VERIFY COMPLETE: these suites were auto-detected and may be incomplete —
  confirm every real suite is listed before relying on this gate.` Detection is a
  convenience, never authoritative.
- **Branch-protection `[HUMAN]` task:** append to `.startup/human-tasks.md` a
  `[HUMAN]` item that is **explicitly sequenced**: "After the tech-founder finalizes
  `check.sh` and the first CI run on a PR is green, require the CI check on the
  default branch."

  - **Primary path: the GitHub UI** — *Settings → Branches → Add branch protection
    rule → Require status checks to pass → select the CI check.* This is the
    recommended path because it composes with any existing protections and shows the
    exact check name to select.
  - **Get the exact check-context name first** (it can be `check` or `CI / check`
    depending on GitHub's surfacing — do not guess): run `gh pr checks <pr>` on the
    first green PR and copy the check name verbatim.
  - **CLI alternative (only for repos with no existing protection rule —** a `PUT` to
    `/protection` *replaces* the whole protection object and would wipe existing
    review/restriction/linear-history settings**):** use a full JSON payload via
    `--input` so `null` fields serialize correctly (the `-F key=null` form is
    error-prone):

    ```bash
    BR=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
    CTX="check"   # <- replace with the exact name from `gh pr checks`
    gh api -X PUT "repos/{owner}/{repo}/branches/$BR/protection" \
      -H "Accept: application/vnd.github+json" --input - <<JSON
    {
      "required_status_checks": { "strict": true, "contexts": ["$CTX"] },
      "enforce_admins": false,
      "required_pull_request_reviews": null,
      "restrictions": null
    }
    JSON
    ```

    Notes baked into the task: requires repo-admin and a token with the right scope;
    `enforce_admins` defaults to `false` here (admins can still merge a red PR in an
    emergency — matches the investor's speed-over-safety preference; flip to `true` to
    bind admins too); classic branch protection only (rulesets out of scope).
- **Record canonical-entrypoint expectation:** the bootstrap CLAUDE.md / workflow
  guidance notes that `./check.sh` is the canonical full-suite entrypoint and that the
  tech-founder must finalize it and record the resolved commands in
  `docs/architecture/architecture.md`. (Recording happens at tech-founder
  finalization time, by which point `architecture.md` exists; if absent, the founder
  creates it — `docs/architecture/` is already made in bootstrap Step 1.)
- **Commit:** add `.github/workflows/ci.yml` and `check.sh` to the bootstrap commit's
  `git add` list.

### Component 4 — `commands/improve.md` (edits)

Replace the loose "run the project's typecheck/lint and test commands" guidance in
**Step 2** (tech-founder implementation self-verify) and **Step 4** (fix retry) with
"run `./check.sh` — the canonical full-suite entrypoint recorded in
`docs/architecture/architecture.md`". Preserve the existing self-review intent
(re-read the diff for enum/boundary/null bugs); only the command name is made canonical.

### Component 5 — `skills/tech-founder/SKILL.md` (edits)

- **Testing Approach:** name `./check.sh` as the canonical entrypoint; instruct the
  founder to finalize it (wire `REQUIRED_SUITES` + suites, fill the CI setup block)
  when the stack is chosen and record the resolved commands in `architecture.md`.
- New **"Derived-output correctness"** subsection: for products whose correctness is
  *computed* (financial, billing, tax, scheduling, pricing), build a
  golden/characterization/invariant fixture suite over real (anonymized) cases and
  wire it into `check.sh` (`golden_tests`) as a CI gate.
- New **"green-but-wrong" risk class:** in-app validation passing ≠ output correct;
  treat a green app as insufficient evidence for computed outputs.
- Build-verification step (#7 in the Implementation Workflow) calls `./check.sh`.

### Component 6 — `skills/tech-founder/references/quality-standards.md` (edits)

- New principle: **"Single source of truth for domain/business invariants — derive,
  don't duplicate across layers."** Explains the desync failure mode.
- New code-quality checklist line: "Did this change re-derive a rule that already
  exists in another layer? If a business predicate now lives in >1 place, consolidate
  or derive from one source."

### Component 7 — `agents/business-founder-maintain.md` AND `agents/business-founder.md` (edits)

Both QA workflows gain:

- An **independent-value spot-check**: for computed/derived outputs, verify at least
  one value against an independent source (hand calc / reference doc) — do not trust
  in-app green checks; the app can be green on a wrong result.
- A regression-awareness line: when reviewing a change to a business rule, check
  whether the same rule appears in another layer that may now be desynced.

### Component 8 — Tests (`tests/`, wired into `tests/run-tests.sh`)

Real coverage in the existing bash-harness style:

- **`check.sh` template behavior** (copy template to a temp dir, wire/declare suites):
  - passes when a declared suite is wired and green;
  - **fails on vacuous run** (no suites ran / empty `REQUIRED_SUITES`);
  - **fails when a declared suite is left a stub** (Guard 2);
  - exits non-zero when a wired suite's command fails;
  - is executable / runnable via `./check.sh`.
- **bootstrap scaffolding** (run bootstrap's file-creating steps in a temp repo):
  creates `.github/workflows/ci.yml` + an executable `check.sh` + the `[HUMAN]`
  branch-protection task; idempotent (re-run does not duplicate or overwrite).
- **plugin-self drift guard:** a test asserting the call sites all name `check.sh`
  — `commands/improve.md`, `skills/tech-founder/SKILL.md`, and
  `templates/ci-workflow.yml` each reference `check.sh` — so a future edit can't
  silently reintroduce ad-hoc test commands at one site.

### Component 9 — Version + docs (kept minimal)

- Bump version in **both** `.claude-plugin/plugin.json` and the root
  `.claude-plugin/marketplace.json` (0.41.2 → 0.42.0).
- README: a short addition documenting `check.sh` (canonical entrypoint) and the PR
  CI gate. Strictly minimal — this issue is not a docs/versioning sweep.

## Out of scope (YAGNI)

- No automated grep-based duplicate-invariant detector — gap #3 stays a manual
  checklist item; generalizing "same rule in two layers" across arbitrary stacks is
  too noisy to be worth it.
- No new hook to enforce the canonical entrypoint at runtime — naming one script at
  every call site, plus the plugin-self drift test, is the mechanism.
- No non-GitHub CI providers.
- No GitHub rulesets path (classic branch protection only).

## Verification

- Plugin's own `tests/run-tests.sh` green.
- Manual bootstrap-in-temp-repo smoke test: confirm scaffolded `ci.yml` + executable
  `check.sh` + `[HUMAN]` task, and that `check.sh` fails vacuously until suites are wired.
- Codex review at the spec stage (done) and at the implementation-plan stage.
- Version bumped in both manifests; pre-push hook passes.

## Codex design-review dispositions (2026-06-21)

Codex (gpt-5.5) raised 8 concerns; dispositions:

1. **Gate not enforced until human acts** → accepted; reframed "enforced" honestly
   (machinery auto-scaffolded; enforcement is a sequenced `[HUMAN]` task).
2. **`gh api` context fragility** → accepted; pinned workflow `name: CI` / job `check`
   so the required-check context is stable; command derives default branch.
3. **CI born-failing before stack chosen** → accepted; `[HUMAN]` task explicitly
   sequenced *after* first green CI run so PRs are never blocked on a stub.
4. **"declared no-op fails" underspecified** → accepted; concrete `suite_stub` /
   `run_suite` mechanics added; residual "0 tests collected" limitation documented.
5. **Failure masking under `pipefail` w/o `-e`** → accepted; `run_suite` captures
   per-command status, `&&`-chaining via `bash -c`.
6. **"non-drifting" overstated** → accepted; softened to convention + single call
   site; added plugin-self drift test (Component 8).
7. **Migrated-repo detection false confidence** → accepted; detection is convenience
   prefill with a visible "VERIFY COMPLETE" banner, never authoritative.
8. **README/version scope creep** → accepted; Component 9 kept strictly minimal.

### Round 2 (2026-06-21, on the written spec)

Codex (gpt-5.5) raised 8 more; dispositions:

1. **Required-check context may be `CI / check` not `check`** → accepted; `[HUMAN]`
   task instructs getting the exact name via `gh pr checks` before pasting; UI path
   shows it directly.
2. **`PUT /protection` replaces existing settings (wipe risk)** → accepted; UI is now
   the primary path; CLI alternative is scoped to repos with no existing rule and
   warned.
3. **`-F key=null` serialization fragility** → accepted; CLI alternative switched to a
   full JSON payload via `--input -`.
4. **Shebang** → accepted; `#!/usr/bin/env bash` mandated in Component 1.
5. **`run_suite` calling convention ambiguous** → accepted; fixed to exactly
   `run_suite <label> <single-shell-string>` run via `bash -c`.
6. **Born-failing scaffold + immediate CI sequencing** → already covered by the
   sequenced `[HUMAN]` task and the `check.sh` "VERIFY COMPLETE" banner; reinforced.
7. **`architecture.md` may not exist** → accepted; note added (created at finalization
   time; founder creates if absent).
8. **Drift guard only checks presence, not absence of ad-hoc commands** → acknowledged
   as a known limitation; rejecting arbitrary "ad-hoc command" patterns generically is
   too noisy (same rationale as out-of-scope gap #3). Presence check retained.
