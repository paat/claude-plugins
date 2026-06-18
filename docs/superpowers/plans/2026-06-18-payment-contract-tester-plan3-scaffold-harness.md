# payment-contract-tester Plan 3 — `/scaffold` generator + CI/hook enforcement harness

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `/payment-contract-tester:scaffold` command that detects a target repo's stack + gateway, drafts repo-adapted contract tests using the skill knowledge + reference fixtures as few-shot exemplars, self-verifies them, and wires enforcement — backed by a tested CI/pre-push harness.

**Architecture:** Three new surfaces on top of the shipped skill + fixtures (Plans 1–2): (1) `commands/scaffold.md` — instructions-for-Claude generator implementing design spec §4.2; (2) `harness/` — a *tested* enforcement toolkit: CI snippets (the authoritative gate), a generic `pre-push.sh` hook body, and an `install-pre-push.sh` installer that satisfies the §4.3 MUSTs (manager detection, managed block, exec-bit, clean removal, fail-safe) as mechanical, regression-proof bash rather than prose; (3) docs reconciliation (README + skill) and a version bump. New harness tests are wired into the existing `tests/run-tests.sh` so the acceptance criteria stay provable from one entry point.

**Tech Stack:** Bash 4+ (POSIX tools: grep/sed/awk), Markdown (command + skill docs), YAML (GitHub Actions + GitLab CI), Python 3 (YAML-parse validation in tests — always present in this env), pytest + .NET 9 SDK (only for the pre-existing fixture self-tests, not Plan 3's new code).

## Global Constraints

- Plugins must be **generic and project-agnostic**: no hardcoded company/product names, paths, or stacks. Anything project-specific is a template variable or a runtime parameter. (Repo CLAUDE.md)
- Bash **4+** and standard **POSIX tools** only. External deps (jq/awk/sed) must be documented in README. (Repo CLAUDE.md)
- **Version bump in BOTH** `plugins/payment-contract-tester/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`, kept in sync. This plan bumps **0.1.1 → 0.2.0** (`/scaffold` is the headline feature). (Repo CLAUDE.md + handoff)
- README MUST keep the **Installation** section with the three scopes (user / project / local). (Repo CLAUDE.md)
- **Enforcement framing (do not regress):** CI is the **authoritative** gate; the local pre-push hook is **convenience only**, explicitly NOT the security boundary; `--no-verify` is the documented escape hatch. Never claim "automatic correctness" from a local hook. (Spec §4.3, codex P0)
- **Webhook authenticity is per-gateway:** signed-payload-authoritative for Stripe/Montonio; forced re-fetch from `GET /v2/payments/{id}` for Mollie (legacy webhooks unsigned). NOT universal re-fetch. (Spec §3.2–3.4)
- **`reconciliation` is skill-knowledge only** — `/scaffold` documents the manual shape but does NOT auto-generate reconciliation tests. (Spec §3.1.5, §8)
- The `/scaffold` command **never edits payment source** — it writes tests, the CI snippet, and (optionally) the hook. (Spec §4.2)
- Generated tests need a human skim — the self-verify step, the `TODO-verify-against-sandbox` flags, and the generation report are the honesty mechanisms; do not overclaim. (Spec §7)
- Branch off `main` first (do not implement on `main`). Commit trailer on every commit: `Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y`.
- Keep self-test temp files namespaced via `mktemp`; any SKIP guard must require the actual toolchain (e.g. `dotnet --list-sdks` non-empty, not just `command -v dotnet`). (Plan 2 review findings)

---

## File Structure

**New files:**
- `plugins/payment-contract-tester/commands/scaffold.md` — the `/payment-contract-tester:scaffold` generator (instructions for Claude; spec §4.2).
- `plugins/payment-contract-tester/harness/pre-push.sh` — generic hook body: runs the configured payment-test subset, exits non-zero on red.
- `plugins/payment-contract-tester/harness/install-pre-push.sh` — installer/uninstaller: manager detection, managed block, exec-bit, clean removal, fail-safe (spec §4.3 MUSTs).
- `plugins/payment-contract-tester/harness/ci/github-actions.yml` — GitHub Actions snippet (authoritative gate).
- `plugins/payment-contract-tester/harness/ci/gitlab-ci.yml` — GitLab CI snippet (authoritative gate).
- `plugins/payment-contract-tester/harness/README.md` — CI + hook install/uninstall/config docs.
- `plugins/payment-contract-tester/harness/tests/install-pre-push.test.sh` — TDD tests for the installer/hook body.
- `plugins/payment-contract-tester/harness/tests/ci-snippets.test.sh` — YAML-parse + content validation for the CI snippets.
- `plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh` — structural validation of `scaffold.md`.

**Modified files:**
- `plugins/payment-contract-tester/tests/run-tests.sh` — add a `### harness tests ###` section invoking the three new test scripts.
- `plugins/payment-contract-tester/README.md` — document `/scaffold` + harness; remove the "arrives in a later version" note (line ~20); keep Installation + deps + policy.
- `plugins/payment-contract-tester/skills/payment-contract-tester/SKILL.md` — reconcile the scaffold/harness references with the now-shipped paths (wording only; they are already present-tense and become accurate).
- `plugins/payment-contract-tester/.claude-plugin/plugin.json` — version 0.1.1 → 0.2.0.
- `.claude-plugin/marketplace.json` — version 0.1.1 → 0.2.0 (payment-contract-tester entry).

**Design decision (recorded so a reviewer can accept/reject deliberately):** the handoff names `harness/pre-push.sh` + `harness/README.md`. This plan splits the *hook body* (`pre-push.sh`) from the *installer logic* (`install-pre-push.sh`). Rationale: the §4.3 MUSTs are mechanical (managed block / exec-bit / clean removal / fail-safe) and far more robust as one tested script than as prose for Claude to re-execute each scaffold run. The installer is the TDD core. `/scaffold` step 6 calls it; `harness/README.md` documents manual use.

---

## Task 1: pre-push hook body + installer (the tested enforcement core)

**Files:**
- Create: `plugins/payment-contract-tester/harness/pre-push.sh`
- Create: `plugins/payment-contract-tester/harness/install-pre-push.sh`
- Test: `plugins/payment-contract-tester/harness/tests/install-pre-push.test.sh`

**Interfaces:**
- Produces — `pre-push.sh`: a standalone git pre-push hook body. Resolves the test command from env `PCT_TEST_CMD`, else from `<repo-root>/.pct-hook.conf` (a line `PCT_TEST_CMD=<command>`). If unset → prints a notice and exits **0** (fail-open: a convenience hook never blocks when unconfigured). If set → prints a header, runs the command via `bash -c`, exits with its status. `git push --no-verify` is handled natively by git (the hook is not invoked), so the script needs no flag for it.
- Produces — `install-pre-push.sh`: usage `install-pre-push.sh [--uninstall] [--test-cmd "<cmd>"] [--repo <path>]`. `--repo` defaults to `$(git rev-parse --show-toplevel)`. Manager detection (husky `.husky/`, lefthook `lefthook.{yml,yaml,toml}`, pre-commit `.pre-commit-config.yaml`, `git config core.hooksPath` set to anything other than empty/`.git/hooks`): if any present → print the manager-specific integration snippet and exit 0 **without writing**. Else → write a clearly-delimited managed block into `<repo>/.git/hooks/pre-push` that `exec`s this directory's `pre-push.sh`; create the file +x if absent, append+preserve if present, replace-in-place if our block already exists. `--test-cmd` writes `<repo-root>/.pct-hook.conf`. `--uninstall` strips only the managed block (removing the file if nothing but a shebang remains). Ambiguity (hook file exists, non-empty, and NOT executable) → print instructions, modify nothing, exit 0. Block markers: `# >>> payment-contract-tester >>>` / `# <<< payment-contract-tester <<<`.

- [ ] **Step 1: Write the failing test script**

Create `plugins/payment-contract-tester/harness/tests/install-pre-push.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for install-pre-push.sh: managed-block install/uninstall, exec-bit preservation,
# existing-hook composition, hook-manager detection (no-clobber), and fail-safe on ambiguity.
# Each case runs in a fresh throwaway git repo under mktemp — never touches the real repo.
set -uo pipefail
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$HARNESS/install-pre-push.sh"
HOOKBODY="$HARNESS/pre-push.sh"
BEGIN='# >>> payment-contract-tester >>>'
END='# <<< payment-contract-tester <<<'
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

newrepo() {  # echoes a fresh repo path; safe to rm afterwards
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  printf '%s\n' "$d"
}

# 1) fresh install creates an executable hook containing our managed block
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'echo subset' >/dev/null 2>&1
h="$r/.git/hooks/pre-push"
if [ -x "$h" ] && grep -qF "$BEGIN" "$h" && grep -qF "$END" "$h"; then
  pass "fresh install writes executable managed block"
else
  bad "fresh install did not write an executable managed block"
fi
# .pct-hook.conf records the test command
if grep -qF 'PCT_TEST_CMD=echo subset' "$r/.pct-hook.conf"; then
  pass "test command recorded in .pct-hook.conf"
else
  bad ".pct-hook.conf missing the test command"
fi
rm -rf "$r"

# 2) re-install is idempotent (exactly one managed block)
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'echo a' >/dev/null 2>&1
bash "$INSTALL" --repo "$r" --test-cmd 'echo b' >/dev/null 2>&1
n=$(grep -cF "$BEGIN" "$r/.git/hooks/pre-push")
if [ "$n" -eq 1 ]; then pass "re-install stays idempotent (one block)"; else bad "re-install produced $n blocks"; fi
rm -rf "$r"

# 3) uninstall removes only our block, preserving pre-existing hook content + exec bit
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho "pre-existing custom hook"\n' >"$h"; chmod +x "$h"
bash "$INSTALL" --repo "$r" --test-cmd 'echo x' >/dev/null 2>&1
bash "$INSTALL" --repo "$r" --uninstall >/dev/null 2>&1
if [ -x "$h" ] && grep -qF 'pre-existing custom hook' "$h" && ! grep -qF "$BEGIN" "$h"; then
  pass "uninstall preserves existing hook + exec bit, drops our block"
else
  bad "uninstall damaged the existing hook or left our block"
fi
rm -rf "$r"

# 4) installing alongside an existing hook appends (does not clobber)
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho "keep me"\n' >"$h"; chmod +x "$h"
bash "$INSTALL" --repo "$r" --test-cmd 'echo y' >/dev/null 2>&1
if grep -qF 'keep me' "$h" && grep -qF "$BEGIN" "$h" && [ -x "$h" ]; then
  pass "install composes with existing hook content"
else
  bad "install clobbered or failed to compose with existing hook"
fi
rm -rf "$r"

# 5) hook manager present (core.hooksPath) -> print instructions, write NOTHING to .git/hooks
r=$(newrepo)
git -C "$r" config core.hooksPath .husky
out=$(bash "$INSTALL" --repo "$r" --test-cmd 'echo z' 2>&1)
if [ ! -e "$r/.git/hooks/pre-push" ] && printf '%s' "$out" | grep -qi 'hooksPath\|husky\|manager'; then
  pass "core.hooksPath detected -> no clobber, prints integration guidance"
else
  bad "core.hooksPath case wrote a hook or gave no guidance"
fi
rm -rf "$r"

# 6) husky directory present -> no clobber, prints guidance
r=$(newrepo); mkdir -p "$r/.husky"
out=$(bash "$INSTALL" --repo "$r" --test-cmd 'echo z' 2>&1)
if [ ! -e "$r/.git/hooks/pre-push" ] && printf '%s' "$out" | grep -qi 'husky'; then
  pass "husky detected -> no clobber, prints guidance"
else
  bad "husky case wrote a hook or gave no guidance"
fi
rm -rf "$r"

# 7) fail-safe: existing NON-executable non-empty hook -> modify nothing, print instructions
r=$(newrepo); h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho weird\n' >"$h"   # intentionally not chmod +x
before=$(cat "$h")
out=$(bash "$INSTALL" --repo "$r" --test-cmd 'echo z' 2>&1)
if [ "$(cat "$h")" = "$before" ] && printf '%s' "$out" | grep -qi 'manual\|instruction\|not modif'; then
  pass "ambiguous non-executable hook -> fail-safe, no modification"
else
  bad "ambiguous hook case modified the file instead of failing safe"
fi
rm -rf "$r"

# 8) the installed hook body actually fails the push when the test command fails
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'exit 7' >/dev/null 2>&1
if ( cd "$r" && ! bash .git/hooks/pre-push </dev/null >/dev/null 2>&1 ); then
  pass "installed hook propagates a red test command (non-zero exit)"
else
  bad "installed hook did not fail on a red test command"
fi
rm -rf "$r"

# 9) the hook body fails OPEN (exit 0) when no test command is configured
r=$(newrepo)
if ( cd "$r" && PCT_TEST_CMD= bash "$HOOKBODY" </dev/null >/dev/null 2>&1 ); then
  pass "hook body fails open (exit 0) when unconfigured"
else
  bad "hook body blocked the push despite no configured command"
fi
rm -rf "$r"

[ "$fail" -eq 0 ] && echo "install-pre-push tests: ALL PASS" || echo "install-pre-push tests: FAILURES"
exit $fail
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash plugins/payment-contract-tester/harness/tests/install-pre-push.test.sh`
Expected: FAIL — the scripts under test do not exist yet (e.g. `FAIL: fresh install did not write an executable managed block`), exit 1.

- [ ] **Step 3: Write the hook body**

Create `plugins/payment-contract-tester/harness/pre-push.sh`:

```bash
#!/usr/bin/env bash
# payment-contract-tester — optional pre-push hook BODY (fast-feedback convenience ONLY; NOT the
# security boundary — CI is the authoritative gate, and `git push --no-verify` bypasses this hook).
# Runs the configured payment-test subset and blocks the push on red. The command comes from the
# PCT_TEST_CMD env var, else from <repo-root>/.pct-hook.conf. Unconfigured => fail open (exit 0).
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cmd="${PCT_TEST_CMD:-}"
if [ -z "$cmd" ] && [ -f "$root/.pct-hook.conf" ]; then
  # read a single `PCT_TEST_CMD=...` line without sourcing arbitrary code
  cmd=$(sed -n 's/^PCT_TEST_CMD=//p' "$root/.pct-hook.conf" | head -n1)
fi

if [ -z "$cmd" ]; then
  echo "payment-contract-tester pre-push: no PCT_TEST_CMD configured — skipping (not blocking)."
  exit 0
fi

echo "payment-contract-tester pre-push: running payment-test subset:"
echo "  $cmd"
bash -c "$cmd"
status=$?
if [ "$status" -ne 0 ]; then
  echo "payment-contract-tester pre-push: payment tests FAILED — push blocked."
  echo "  (CI is the authoritative gate; to bypass locally: git push --no-verify)"
fi
exit $status
```

- [ ] **Step 4: Write the installer**

Create `plugins/payment-contract-tester/harness/install-pre-push.sh`:

```bash
#!/usr/bin/env bash
# payment-contract-tester — installs/uninstalls the optional pre-push hook (convenience only).
# Fails SAFE: detects existing hook managers and prints guidance rather than clobbering; composes
# with an existing hook via a clearly-delimited managed block; preserves the executable bit;
# supports clean removal. CI remains the authoritative gate; this hook is bypassable (--no-verify).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKBODY="$HERE/pre-push.sh"
BEGIN='# >>> payment-contract-tester >>>'
END='# <<< payment-contract-tester <<<'

uninstall=0 testcmd='' repo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) uninstall=1 ;;
    --test-cmd)  testcmd="${2:-}"; shift ;;
    --repo)      repo="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
  echo "Not a git repository (no --repo and no .git found). Nothing to do." >&2
  exit 0
fi
hook="$repo/.git/hooks/pre-push"

# --- managed-block helpers (POSIX awk; no GNU-only flags) ---
strip_block() {  # prints $1 with our block removed
  awk -v b="$BEGIN" -v e="$END" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}
  ' "$1"
}
block_text() {
  printf '%s\n' "$BEGIN"
  printf '%s\n' "# Managed by payment-contract-tester. Edit via install-pre-push.sh, not by hand."
  printf 'exec "%s" "$@"\n' "$HOOKBODY"
  printf '%s\n' "$END"
}

if [ "$uninstall" -eq 1 ]; then
  if [ ! -f "$hook" ]; then echo "No pre-push hook present — nothing to uninstall."; exit 0; fi
  if ! grep -qF "$BEGIN" "$hook"; then echo "No payment-contract-tester block found — leaving hook untouched."; exit 0; fi
  tmp=$(mktemp); strip_block "$hook" >"$tmp"
  # if only a shebang / blank lines remain, remove the file entirely
  if ! grep -Eq '[^[:space:]]' <(grep -vE '^#!' "$tmp"); then
    rm -f "$hook"; echo "Removed payment-contract-tester block; hook was otherwise empty, deleted it."
  else
    cat "$tmp" >"$hook"; echo "Removed payment-contract-tester block; preserved the rest of the hook."
  fi
  rm -f "$tmp"; exit 0
fi

# record the test command for the hook body to read
if [ -n "$testcmd" ]; then
  printf 'PCT_TEST_CMD=%s\n' "$testcmd" >"$repo/.pct-hook.conf"
fi

# --- fail-safe: detect existing hook managers; print guidance, do NOT clobber ---
hookspath=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
manager=''
case "$hookspath" in ""|".git/hooks") ;; *) manager="core.hooksPath ($hookspath)";; esac
[ -d "$repo/.husky" ] && manager="Husky (.husky/)"
for f in lefthook.yml lefthook.yaml lefthook.toml; do [ -f "$repo/$f" ] && manager="lefthook ($f)"; done
[ -f "$repo/.pre-commit-config.yaml" ] && manager="pre-commit (.pre-commit-config.yaml)"

if [ -n "$manager" ]; then
  cat <<EOF
Detected an existing hook manager: $manager
Not writing .git/hooks/pre-push (it would be ignored or would clobber your setup).
Add a pre-push step in your manager that runs the payment-test subset, e.g.:

    "$HOOKBODY"

with PCT_TEST_CMD set (or a .pct-hook.conf at the repo root containing:
    PCT_TEST_CMD=<your subset command>).
See harness/README.md for Husky / lefthook / pre-commit snippets.
EOF
  exit 0
fi

# --- fail-safe: an existing, non-empty, NON-executable hook is an unusual setup — don't fight it ---
if [ -f "$hook" ] && [ -s "$hook" ] && [ ! -x "$hook" ]; then
  cat <<EOF
A non-executable pre-push hook already exists at:
    $hook
This is an unusual setup, so nothing was modified. To install manually, add this block to that file:

$(block_text)

Then ensure the file is executable: chmod +x "$hook"
EOF
  exit 0
fi

# --- install: create fresh, or compose with an existing hook (idempotent replace) ---
mkdir -p "$repo/.git/hooks"
if [ ! -f "$hook" ]; then
  { printf '#!/usr/bin/env bash\n'; block_text; } >"$hook"
elif grep -qF "$BEGIN" "$hook"; then
  tmp=$(mktemp); { strip_block "$hook"; block_text; } >"$tmp"; cat "$tmp" >"$hook"; rm -f "$tmp"
else
  block_text >>"$hook"
fi
chmod +x "$hook"
echo "Installed payment-contract-tester pre-push hook at $hook"
echo "  (convenience only — CI is the authoritative gate; bypass with: git push --no-verify)"
exit 0
```

- [ ] **Step 5: Make both scripts executable**

Run: `chmod +x plugins/payment-contract-tester/harness/pre-push.sh plugins/payment-contract-tester/harness/install-pre-push.sh`

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash plugins/payment-contract-tester/harness/tests/install-pre-push.test.sh`
Expected: every `OK:` line, final `install-pre-push tests: ALL PASS`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add plugins/payment-contract-tester/harness/pre-push.sh plugins/payment-contract-tester/harness/install-pre-push.sh plugins/payment-contract-tester/harness/tests/install-pre-push.test.sh
git commit -m "feat(payment-contract-tester): pre-push hook body + fail-safe installer

Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y"
```

---

## Task 2: CI snippets (the authoritative gate)

**Files:**
- Create: `plugins/payment-contract-tester/harness/ci/github-actions.yml`
- Create: `plugins/payment-contract-tester/harness/ci/gitlab-ci.yml`
- Test: `plugins/payment-contract-tester/harness/tests/ci-snippets.test.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: two valid YAML CI templates. Each runs on push + PR/MR, contains BOTH adaptable runner commands as clearly-commented alternatives — `pytest -k "<payment subset expr>"` and `dotnet test --filter "FullyQualifiedName~<payment subset>"` — and a comment marking it the authoritative gate. The scaffold (Task 4) edits one in and deletes the other when wiring a concrete repo.

- [ ] **Step 1: Write the failing validation test**

Create `plugins/payment-contract-tester/harness/tests/ci-snippets.test.sh`:

```bash
#!/usr/bin/env bash
# Validates the CI snippets parse as YAML and carry both adaptable runner commands + the
# "authoritative gate" framing. Uses python3 (always present here) for a real YAML parse.
set -uo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ci" && pwd)"
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

for f in github-actions.yml gitlab-ci.yml; do
  p="$CI/$f"
  if [ ! -f "$p" ]; then bad "$f missing"; continue; fi
  if python3 -c "import sys,yaml; yaml.safe_load(open('$p'))" 2>/dev/null; then
    pass "$f is valid YAML"
  else
    bad "$f failed to parse as YAML"
  fi
  grep -qF 'pytest -k' "$p"        && pass "$f has the pytest runner" || bad "$f missing the pytest runner"
  grep -qF 'dotnet test --filter' "$p" && pass "$f has the dotnet runner" || bad "$f missing the dotnet runner"
  grep -qi 'authoritative' "$p"    && pass "$f states the authoritative-gate framing" || bad "$f missing authoritative-gate framing"
done

[ "$fail" -eq 0 ] && echo "ci-snippets tests: ALL PASS" || echo "ci-snippets tests: FAILURES"
exit $fail
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash plugins/payment-contract-tester/harness/tests/ci-snippets.test.sh`
Expected: FAIL — `FAIL: github-actions.yml missing` etc., exit 1.

- [ ] **Step 3: Write the GitHub Actions snippet**

Create `plugins/payment-contract-tester/harness/ci/github-actions.yml`:

```yaml
# payment-contract-tester — GitHub Actions snippet (the AUTHORITATIVE enforcement gate).
# This is versioned, team-propagated, present in CI, and NOT bypassable with `git push --no-verify`.
# The local pre-push hook is convenience only; THIS is the boundary.
#
# /scaffold wires this in: it keeps the job matching your stack, fills the payment-test SUBSET
# selector, and deletes the alternative below. Drop into .github/workflows/payment-contract.yml.
name: payment-contract-tests
on:
  push:
  pull_request:
jobs:
  payment-contract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # --- Python / pytest repos -------------------------------------------------
      # Adapt the -k expression to select ONLY your payment/webhook contract tests.
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Run payment contract tests (pytest)
        run: |
          pip install -r requirements.txt
          pytest -k "payment or webhook or contract" -v

      # --- .NET / xUnit repos (delete the pytest block above and use this instead) ---
      # - name: Set up .NET
      #   uses: actions/setup-dotnet@v4
      #   with:
      #     dotnet-version: "9.0.x"
      # - name: Run payment contract tests (xUnit)
      #   run: dotnet test --filter "FullyQualifiedName~Payment|FullyQualifiedName~Webhook" -v minimal
```

- [ ] **Step 4: Write the GitLab CI snippet**

Create `plugins/payment-contract-tester/harness/ci/gitlab-ci.yml`:

```yaml
# payment-contract-tester — GitLab CI snippet (the AUTHORITATIVE enforcement gate).
# Versioned, team-propagated, present in CI, NOT bypassable with `git push --no-verify`.
# The local pre-push hook is convenience only; THIS is the boundary.
#
# /scaffold wires this in: keep the job matching your stack, fill the payment-test SUBSET selector,
# delete the alternative. Include into .gitlab-ci.yml (or use `include:`).
payment-contract-tests:
  stage: test
  rules:
    - if: $CI_PIPELINE_SOURCE == "push"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  # --- Python / pytest repos ---
  image: python:3.12
  script:
    - pip install -r requirements.txt
    # Adapt the -k expression to select ONLY your payment/webhook contract tests.
    - pytest -k "payment or webhook or contract" -v
  # --- .NET / xUnit repos (swap image + script) ---
  # image: mcr.microsoft.com/dotnet/sdk:9.0
  # script:
  #   - dotnet test --filter "FullyQualifiedName~Payment|FullyQualifiedName~Webhook" -v minimal
```

- [ ] **Step 5: Run the validation test to verify it passes**

Run: `bash plugins/payment-contract-tester/harness/tests/ci-snippets.test.sh`
Expected: all `OK:`, final `ci-snippets tests: ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add plugins/payment-contract-tester/harness/ci plugins/payment-contract-tester/harness/tests/ci-snippets.test.sh
git commit -m "feat(payment-contract-tester): authoritative CI snippets (GitHub Actions + GitLab)

Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y"
```

---

## Task 3: harness/README.md (CI + hook install/uninstall docs)

**Files:**
- Create: `plugins/payment-contract-tester/harness/README.md`
- Modify: `plugins/payment-contract-tester/tests/run-tests.sh` (wire in the harness tests)
- Test: inline grep assertions (Step 4) + the now-wired `tests/run-tests.sh`

**Interfaces:**
- Consumes: the file/flag names produced by Tasks 1–2 (`install-pre-push.sh`, `--uninstall`, `.pct-hook.conf`, `harness/ci/*`).
- Produces: operator docs. No code interface.

- [ ] **Step 1: Write the harness README**

Create `plugins/payment-contract-tester/harness/README.md`:

```markdown
# payment-contract-tester — enforcement harness

Two layers of enforcement for your generated payment contract tests. **CI is the authoritative
gate.** The local pre-push hook is fast-feedback convenience only — it is **bypassable**
(`git push --no-verify`) and is **not** the security boundary.

## 1. CI snippet (authoritative)

Templates live in [`ci/`](ci/):

- `ci/github-actions.yml` → copy into `.github/workflows/payment-contract.yml`
- `ci/gitlab-ci.yml` → merge into `.gitlab-ci.yml`

Each runs on push and PR/MR. Keep the block matching your stack, set the payment-test **subset**
selector (`pytest -k "…"` or `dotnet test --filter "…"`), and delete the other block. Because it
runs in CI, it is versioned, shared with the whole team, and cannot be skipped with `--no-verify`.

## 2. Optional pre-push hook (convenience)

`pre-push.sh` is the hook body; `install-pre-push.sh` installs it safely.

### Install

```bash
harness/install-pre-push.sh --test-cmd 'pytest -k "payment or webhook"'
# or, for xUnit:
harness/install-pre-push.sh --test-cmd 'dotnet test --filter "FullyQualifiedName~Payment"'
```

The installer:

- **Detects existing hook managers** (Husky, lefthook, pre-commit, `core.hooksPath`) and, if one is
  present, prints the integration to add to *that* manager instead of writing `.git/hooks/pre-push`.
- Otherwise writes a **clearly-delimited managed block** into `.git/hooks/pre-push`, composing with
  any existing hook content and preserving the executable bit.
- Records the subset command in `.pct-hook.conf` at the repo root (the hook reads it at push time;
  you can also override per-invocation with the `PCT_TEST_CMD` environment variable).
- **Fails safe**: if the setup is ambiguous (e.g. a non-executable hook already exists) it prints
  manual instructions and modifies nothing.

### Hook-manager snippets

If you use a manager, add a pre-push step that runs the hook body:

- **Husky** — in `.husky/pre-push`: `PCT_TEST_CMD='pytest -k "payment"' "$(git rev-parse --show-toplevel)/harness/pre-push.sh"`
- **lefthook** — under `pre-push.commands`: `run: harness/pre-push.sh` with `PCT_TEST_CMD` exported.
- **pre-commit** — a `repo: local` hook with `stages: [push]` invoking `harness/pre-push.sh`.

### Uninstall

```bash
harness/install-pre-push.sh --uninstall
```

Removes only the payment-contract-tester managed block, preserving the rest of your hook.

### Why pre-push (not pre-commit)

Full payment-test runners are too slow to run on every commit. Pre-push gives the signal before the
code leaves your machine without taxing each commit. CI still re-runs it as the real gate.
```

- [ ] **Step 2: Wire the existing harness tests into the self-test orchestrator**

In `plugins/payment-contract-tester/tests/run-tests.sh`, after the xunit block (current lines 12–13) and before the summary `if`, add (the `scaffold-doc.test.sh` line is added in Task 4 when that test is created — do NOT reference it yet):

```bash
echo "### harness tests ###"
bash "$ROOT/harness/tests/install-pre-push.test.sh" || rc=1
bash "$ROOT/harness/tests/ci-snippets.test.sh" || rc=1
```

- [ ] **Step 3: Run the full self-test to verify everything is green**

Run: `bash plugins/payment-contract-tester/tests/run-tests.sh`
Expected: the pytest + xunit sections (xunit SKIPs if no SDK), then `install-pre-push tests: ALL PASS`, `ci-snippets tests: ALL PASS`, and finally `ALL SELF-TESTS PASSED`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add plugins/payment-contract-tester/harness/README.md plugins/payment-contract-tester/tests/run-tests.sh
git commit -m "feat(payment-contract-tester): harness README + wire harness tests into self-test

Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y"
```

---

## Task 4: `/scaffold` generator command

**Files:**
- Create: `plugins/payment-contract-tester/commands/scaffold.md`
- Create: `plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh`
- Modify: `plugins/payment-contract-tester/tests/run-tests.sh` (add the scaffold-doc test to the harness section)
- Test: `plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh`

**Interfaces:**
- Consumes: the skill knowledge (`skills/payment-contract-tester/SKILL.md` + `references/*`), the reference fixtures (`reference/pytest/`, `reference/xunit/`), and the harness (`harness/ci/*`, `harness/install-pre-push.sh`).
- Produces: a slash command. Auto-discovered from `commands/` → invoked as `/payment-contract-tester:scaffold`. No code interface; validated structurally.

- [ ] **Step 1: Write the failing structural test**

Create `plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh`:

```bash
#!/usr/bin/env bash
# Structural validation of commands/scaffold.md: it must encode the spec §4.2 generator flow and the
# critical non-regression framing. Content is instructions-for-Claude, so we assert the load-bearing
# anchors are present (not prose quality).
set -uo pipefail
DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/commands/scaffold.md"
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

[ -f "$DOC" ] || { echo "FAIL: commands/scaffold.md missing"; exit 1; }

# YAML frontmatter with a description
head -1 "$DOC" | grep -qx -- '---' && pass "has frontmatter opener" || bad "missing frontmatter opener"
grep -qiE '^description:' "$DOC" && pass "frontmatter has a description" || bad "frontmatter missing description"

# the 7 flow steps (anchored by their spec verbs)
for kw in "Detect stack" "Detect gateway" "Locate seam" "Draft contract test" "Self-verify" "Wire enforcement" "Report"; do
  grep -qiF "$kw" "$DOC" && pass "covers step: $kw" || bad "missing step: $kw"
done

# critical non-regression framing (Global Constraints)
grep -qi 'never edits\|does not edit\|not edit.*source\|never.*payment source' "$DOC" && pass "states never-edits-source" || bad "missing never-edits-source rule"
grep -qi 'authoritative' "$DOC" && pass "states CI-authoritative framing" || bad "missing CI-authoritative framing"
grep -qiF 'no first-class support' "$DOC" && pass "handles unsupported stacks honestly" || bad "missing unsupported-stack honesty"
grep -qiF 'TODO-verify-against-sandbox' "$DOC" && pass "flags unverified assertions" || bad "missing TODO-verify-against-sandbox"
grep -qi 're-fetch\|/v2/payments' "$DOC" && pass "encodes Mollie re-fetch model" || bad "missing Mollie re-fetch model"
grep -qi 'reconciliation' "$DOC" && pass "addresses reconciliation (not auto-generated)" || bad "missing reconciliation note"
grep -qiF 'reference/' "$DOC" && pass "points at the few-shot exemplar fixtures" || bad "missing reference/<stack> exemplar pointer"
grep -qi 'install-pre-push\|harness/ci' "$DOC" && pass "wires the harness" || bad "missing harness wiring"

[ "$fail" -eq 0 ] && echo "scaffold-doc tests: ALL PASS" || echo "scaffold-doc tests: FAILURES"
exit $fail
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh`
Expected: FAIL — `FAIL: commands/scaffold.md missing`, exit 1.

- [ ] **Step 3: Write the scaffold command**

Create `plugins/payment-contract-tester/commands/scaffold.md`:

```markdown
---
description: Detect a repo's payment stack + gateway, draft repo-adapted contract tests using the payment-contract-tester skill, self-verify them (green on current source, red on a broken copy), and wire CI + an optional pre-push hook. Never edits payment source.
---

# /payment-contract-tester:scaffold

You are generating payment **contract tests** for the current repository and wiring enforcement.
First invoke the **payment-contract-tester skill** (`skills/payment-contract-tester/SKILL.md` and its
`references/`) — it holds the invariants, the per-gateway verified/unverified tables, and the
GREEN/RED test shapes you will adapt. Follow this flow. It is instructions for you (Claude), not a
rigid script — adapt to the repo, but never skip the honesty checks.

**Non-negotiable framing (do not regress):**
- **CI is the authoritative gate.** The local pre-push hook is convenience only and is bypassable
  (`git push --no-verify`); never claim a local hook gives "automatic correctness".
- **Never edit payment source.** You write tests, the CI snippet, and (optionally) the hook — nothing else.
- **Webhook authenticity is per-gateway:** signed-payload is authoritative for Stripe/Montonio;
  for **Mollie** the webhook body is id-only and (legacy) unsigned, so the handler MUST re-fetch
  `GET /v2/payments/{id}` and branch on the fetched status — re-fetch IS the security model. Not universal re-fetch.
- **Generated tests need a human skim.** The self-verify step, the `TODO-verify-against-sandbox`
  flags, and the final report are the honesty mechanisms. Do not overclaim.

## 1. Detect stack

- `*.csproj` referencing `xunit` → **xUnit** (.NET).
- `pyproject.toml` / `requirements.txt` with `pytest.ini` (or `[tool.pytest]`) → **pytest** (Python).

These two are first-class — the golden fixtures under `reference/xunit/` and `reference/pytest/`
back them. For any other stack (JS, Go, …), **report "no first-class support yet"** and stop rather
than emit an unbacked, low-quality path.

## 2. Detect gateway(s) — propose, do not decide

Grep heuristics (brittle: wrapped clients, env-configured keys, false hits in docs/tests):
- **Montonio:** `stargate`, `merchantReference`
- **Stripe:** `stripe`, `whsec_`, `construct_event`
- **Mollie:** `mollie`, `X-Mollie-Signature`, `tr_`

Present the detected gateways as a **proposal the user confirms**. Do not proceed on a guess.

## 3. Locate seams

Find: the webhook entry point(s); order/charge creation; the money field + its type; existing payment
tests (to **imitate, not duplicate**); and the test-invocation pattern (xUnit `WebApplicationFactory`
+ DI fake, or pytest `TestClient` + `monkeypatch`). If there is **no testable seam** (no injectable
clock, no raw-body access, no fake gateway client, no durable store), **report the seam the repo
needs** instead of emitting a superficial test.

## 4. Draft contract tests

For each confirmed gateway, emit tests for the applicable invariants using the skill's GREEN/RED
shapes, adapted to the repo's idioms and the discovered seam. Use `reference/<stack>/` as the
**few-shot exemplar** (e.g. `reference/pytest/test_contract.py` + `handler.py`, or
`reference/xunit/ContractTests.cs` + `CorrectHandler.cs`).

- Only assert **VERIFIED** behavior. Comment uncertain assertions `TODO-verify-against-sandbox` —
  never silently include them. Never assert corrected-away literals (Montonio `409 ALREADY_PAID_FOR`,
  `EXPIRED`/`FAILED`; the real drop status is `ABANDONED`).
- Prefer the gateway's **official SDK helper** (e.g. Stripe `construct_event`) over hand-rolled HMAC,
  unless the repo verifies signatures manually — then assert raw-body preservation + constant-time
  compare + a recency window.
- **`reconciliation` is NOT auto-generated** — it needs a job + alerting and can't be generically
  contract-tested. Point the user to the skill's documented manual shape; do not emit a runnable test.

## 5. Self-verify the drafts (the honesty check)

- Run the drafts against the **current source** → expect **green**.
- Run them against a **deliberately-broken copy** of the handler (seed one trap per invariant, mirroring
  `reference/<stack>/` traps) → expect **red**.
- **Report any test that does not move.** A test that cannot go red is worthless — reject it.

## 6. Wire enforcement

- **CI (authoritative):** copy the matching `harness/ci/` snippet into the repo
  (`.github/workflows/…` or `.gitlab-ci.yml`), set the payment-test **subset** selector
  (`pytest -k "…"` / `dotnet test --filter "…"`), and delete the other stack's block.
- **Optional pre-push hook (convenience):** offer to run
  `harness/install-pre-push.sh --test-cmd '<subset command>'`. It detects existing hook managers and
  fails safe; see `harness/README.md`. CI remains the boundary.

## 7. Report

Summarize: the generated test files; the CI snippet added; whether the local hook was installed;
**every** `TODO-verify-against-sandbox` assertion; and any seam the repo still needs. State plainly
that the generated tests need a human skim — do not overclaim correctness.
```

- [ ] **Step 4: Run the structural test to verify it passes**

Run: `bash plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh`
Expected: all `OK:`, final `scaffold-doc tests: ALL PASS`, exit 0.

- [ ] **Step 5: Wire the scaffold-doc test into the self-test orchestrator**

In `plugins/payment-contract-tester/tests/run-tests.sh`, in the `### harness tests ###` section (added in Task 3), append after the `ci-snippets.test.sh` line:

```bash
bash "$ROOT/harness/tests/scaffold-doc.test.sh" || rc=1
```

- [ ] **Step 6: Run the full self-test to confirm nothing regressed**

Run: `bash plugins/payment-contract-tester/tests/run-tests.sh`
Expected: `install-pre-push tests: ALL PASS`, `ci-snippets tests: ALL PASS`, `scaffold-doc tests: ALL PASS`, then `ALL SELF-TESTS PASSED`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add plugins/payment-contract-tester/commands/scaffold.md plugins/payment-contract-tester/harness/tests/scaffold-doc.test.sh plugins/payment-contract-tester/tests/run-tests.sh
git commit -m "feat(payment-contract-tester): /scaffold generator command (spec §4.2)

Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y"
```

---

## Task 5: README + SKILL.md reconciliation

**Files:**
- Modify: `plugins/payment-contract-tester/README.md`
- Modify: `plugins/payment-contract-tester/skills/payment-contract-tester/SKILL.md`
- Test: inline grep assertions (Step 4)

**Interfaces:**
- Consumes: the now-shipped `commands/scaffold.md` + `harness/` paths.
- Produces: user-facing docs that no longer forward-reference unshipped features.

- [ ] **Step 1: Remove the "later version" note and document `/scaffold` + harness in the README**

In `plugins/payment-contract-tester/README.md`, replace the note line (currently line ~20):

```markdown
**Note:** The `/scaffold` generator and CI/hook harness for automated fixture integration arrive in a later version.
```

with:

```markdown
## `/scaffold` — generate contract tests for your repo

Run `/payment-contract-tester:scaffold` in a target repo. It detects your stack (pytest or xUnit)
and payment gateway(s) (Montonio / Stripe / Mollie), drafts contract tests adapted to your code using
the skill knowledge and the reference fixtures as exemplars, **self-verifies** them (green against
current source, red against a deliberately-broken copy), and wires enforcement. It never edits your
payment source — it writes tests, a CI snippet, and (optionally) a pre-push hook — and it flags every
assertion that still needs sandbox verification. Generated tests are meant to be skimmed by a human.

## Enforcement harness

- **CI snippet (authoritative gate):** `harness/ci/github-actions.yml` and `harness/ci/gitlab-ci.yml`
  run your payment-test subset on every push/PR — versioned, team-wide, not bypassable.
- **Optional pre-push hook (convenience):** `harness/install-pre-push.sh` installs a fast-feedback
  hook that runs the same subset before a push. It detects existing hook managers, composes safely,
  and uninstalls cleanly (`--uninstall`). It is bypassable (`git push --no-verify`) and is **not** the
  security boundary — CI is. See `harness/README.md`.
```

- [ ] **Step 2: Update the "What it provides" section to list the command + harness**

In the same README, in the `## What it provides` section, after the **Reference fixtures** paragraph, add:

```markdown
**`/scaffold` command:** Generates repo-adapted payment contract tests, self-verifies them, and wires
CI + an optional pre-push hook (see below).

**Harness:** CI snippets (the authoritative gate) plus a safe, uninstallable pre-push hook installer.
```

- [ ] **Step 3: Reconcile SKILL.md wording (already present-tense — confirm it matches shipped paths)**

In `plugins/payment-contract-tester/skills/payment-contract-tester/SKILL.md`, the scaffold/harness
references (the intro paragraph at lines ~12–14 and workflow step 6 at lines ~70–71) are already
accurate now that the command + harness ship. Verify they name the real paths and adjust only if
wording implies they are future work. Confirm step 6 reads (edit to match if it does not):

```markdown
6. Wire enforcement: CI snippet (`harness/ci/`) is the authoritative gate; the optional pre-push hook
   (`harness/install-pre-push.sh` / `harness/pre-push.sh`) is fast-feedback convenience only.
```

- [ ] **Step 4: Verify the docs no longer forward-reference and still satisfy repo rules**

Run:
```bash
README=plugins/payment-contract-tester/README.md
! grep -qiF 'arrive in a later version' "$README" && echo "OK: no later-version note" || { echo "FAIL: stale note remains"; exit 1; }
grep -qiF '/payment-contract-tester:scaffold' "$README" && echo "OK: scaffold documented" || { echo "FAIL: scaffold not documented"; exit 1; }
grep -qiF 'Install for you' "$README" && grep -qiF 'Install for all collaborators' "$README" && echo "OK: installation 3 scopes intact" || { echo "FAIL: installation section regressed"; exit 1; }
grep -qiF 'install-pre-push.sh' "$README" && echo "OK: harness documented" || { echo "FAIL: harness not documented"; exit 1; }
```
Expected: four `OK:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/payment-contract-tester/README.md plugins/payment-contract-tester/skills/payment-contract-tester/SKILL.md
git commit -m "docs(payment-contract-tester): document /scaffold + harness; drop later-version note

Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y"
```

---

## Task 6: Version bump + full verification

**Files:**
- Modify: `plugins/payment-contract-tester/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Test: full self-test + the repo's pre-push version-check hook + plugin validation

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a release-ready 0.2.0 with both manifests in sync and a green self-test.

- [ ] **Step 1: Bump the plugin manifest**

In `plugins/payment-contract-tester/.claude-plugin/plugin.json`, change `"version": "0.1.1"` to `"version": "0.2.0"`.

- [ ] **Step 2: Bump the marketplace manifest**

In `.claude-plugin/marketplace.json`, in the `payment-contract-tester` entry, change `"version": "0.1.1"` to `"version": "0.2.0"`.

- [ ] **Step 3: Verify the two versions are in sync**

Run:
```bash
a=$(grep -m1 '"version"' plugins/payment-contract-tester/.claude-plugin/plugin.json)
b=$(grep -A3 '"name": "payment-contract-tester"' .claude-plugin/marketplace.json | grep '"version"')
echo "plugin: $a"; echo "marketplace: $b"
echo "$a" | grep -q '0.2.0' && echo "$b" | grep -q '0.2.0' && echo "OK: both at 0.2.0" || { echo "FAIL: version mismatch"; exit 1; }
```
Expected: `OK: both at 0.2.0`, exit 0.

- [ ] **Step 4: Run the full self-test**

Run: `bash plugins/payment-contract-tester/tests/run-tests.sh`
Expected: pytest + xunit (xunit SKIPs cleanly if no SDK), `install-pre-push tests: ALL PASS`, `ci-snippets tests: ALL PASS`, `scaffold-doc tests: ALL PASS`, then `ALL SELF-TESTS PASSED`, exit 0.

- [ ] **Step 5: Run the repo's version-check pre-push hook locally**

Run (the repo hook lives in `.githooks/`; run it directly so it doesn't require an actual push):
```bash
git config core.hooksPath .githooks 2>/dev/null || true
[ -x .githooks/pre-push ] && bash .githooks/pre-push </dev/null && echo "OK: version-check hook passed" || echo "NOTE: inspect .githooks output above"
```
Expected: the repo's version-sync check passes (no plugin.json/marketplace.json mismatch reported).

- [ ] **Step 6: Validate plugin structure**

Dispatch the `plugin-dev:plugin-validator` agent against `plugins/payment-contract-tester/` (or run the project's validation), and confirm: `plugin.json` valid, `commands/scaffold.md` discovered, no broken references. Address any errors it raises before finishing.

- [ ] **Step 7: Commit**

```bash
git add plugins/payment-contract-tester/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(payment-contract-tester): bump 0.1.1 -> 0.2.0 (/scaffold + harness)

Claude-Session: https://claude.ai/code/session_01KqgpXMcZuGxrUNu8bnWL8y"
```

---

## Self-Review (run after authoring; fix inline)

**Spec coverage (§4.2 / §4.3 / handoff deliverables):**
- §4.2 generator 7-step flow → Task 4 `scaffold.md` (each step + the structural test asserting all 7).
- §4.3 CI authoritative → Task 2 snippets + "authoritative" framing test.
- §4.3 hook MUSTs (manager detection / managed block / exec-bit / clean removal / fail-safe) → Task 1 installer + 9 test cases.
- Mollie re-fetch / per-gateway authenticity → scaffold.md framing + `scaffold-doc.test.sh` assertion.
- reconciliation not auto-generated → scaffold.md step 4 + test assertion.
- README forward-reference removal + scaffold/harness docs → Task 5.
- version bump both manifests → Task 6.
- AC stays provable → harness tests wired into `tests/run-tests.sh` (Task 3).

**Placeholder scan:** all "implement" steps carry full file contents or exact edits. No stubs — Task 3 wires only the two test scripts that exist by then; Task 4 creates `scaffold-doc.test.sh` (real assertions) and adds its wiring line to `run-tests.sh` in the same task.

**Type/name consistency:** block markers (`# >>> payment-contract-tester >>>` / `# <<< … <<<`), the `PCT_TEST_CMD` env var, `.pct-hook.conf`, and the installer flags (`--uninstall` / `--test-cmd` / `--repo`) are used identically in `pre-push.sh`, `install-pre-push.sh`, the installer test, `harness/README.md`, and `scaffold.md`.
