# agent-sync: Deterministic Hook + Init Vendoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the agent-sync PostToolUse hook from nagging when no `sources.json` exists by making it a deterministic script, and make `/agent-sync:init` vendor `generate.sh` into the repo so the scaffolded CI drift-check works without the plugin installed.

**Architecture:** Replace the prompt-based PostToolUse hook with a `command`-type hook backed by a new self-contained bash script (`hooks/check-source-edit.sh`) that is silent on every path except "config exists AND edited file is a tracked source." Add a vendoring step to the `/agent-sync:init` command instructions and collapse the two divergent CI templates into one canonical workflow. Bump the plugin from 0.1.0 → 0.2.0.

**Tech Stack:** Bash 4+, jq, awk, sed. Claude Code plugin hooks (`hooks.json`), slash-command markdown, GitHub Actions YAML.

**Spec:** `docs/superpowers/specs/2026-05-26-agent-sync-hook-vendoring-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `plugins/agent-sync/hooks/check-source-edit.sh` | **New.** Deterministic PostToolUse hook body. Reads payload from stdin, stays silent unless a tracked source file was edited in a configured repo. |
| `plugins/agent-sync/hooks/hooks.json` | **Modify.** Switch the PostToolUse entry from `type: prompt` to `type: command` invoking the new script via `bash`. |
| `plugins/agent-sync/tests/run-tests.sh` | **New.** Self-contained bash test runner for the hook script (matches the saas-startup-team test convention). |
| `plugins/agent-sync/commands/init.md` | **Modify.** Add the vendoring step; replace the inline CI YAML with the canonical workflow. |
| `plugins/agent-sync/skills/agent-sync/references/github-actions-template.md` | **Modify.** Hold the single canonical CI workflow, identical to the one init writes. |
| `plugins/agent-sync/README.md` | **Modify.** Update CI / migration text to say init auto-vendors `generate.sh`. |
| `plugins/agent-sync/.claude-plugin/plugin.json` | **Modify.** Version 0.1.0 → 0.2.0. |
| `.claude-plugin/marketplace.json` | **Modify.** agent-sync version 0.1.0 → 0.2.0 (kept in sync). |

**Branch:** Work happens on `feat/agent-sync-hook-vendoring` (already created; spec is committed there).

---

## Task 1: Hook test harness (failing first)

**Files:**
- Create: `plugins/agent-sync/tests/run-tests.sh`

- [ ] **Step 1: Write the failing test runner**

Create `plugins/agent-sync/tests/run-tests.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Test runner for agent-sync hook (check-source-edit.sh)
# Self-contained: bash 4+ and jq only.
# Usage: bash plugins/agent-sync/tests/run-tests.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/check-source-edit.sh"
PASS=0
FAIL=0

# run NAME PAYLOAD EXPECT
#   EXPECT="" means expect empty stdout; otherwise expect stdout to contain EXPECT.
run() {
  local name="$1" payload="$2" expect="$3" out
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"
  if [[ -z "$expect" ]]; then
    if [[ -z "$out" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
    else echo "FAIL: $name — expected empty stdout, got: $out"; FAIL=$((FAIL+1)); fi
  else
    if [[ "$out" == *"$expect"* ]]; then echo "PASS: $name"; PASS=$((PASS+1));
    else echo "FAIL: $name — expected substring '$expect', got: $out"; FAIL=$((FAIL+1)); fi
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Configured repo fixture
mkdir -p "$TMP/with/tools/agent-sync" "$TMP/with/.claude/rules"
echo "# claude rules" > "$TMP/with/CLAUDE.md"
echo "# architecture" > "$TMP/with/.claude/rules/architecture.md"
echo "# readme" > "$TMP/with/README.md"
cat > "$TMP/with/tools/agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"main":"CLAUDE.md","arch":".claude/rules/architecture.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"Architecture","source":"arch","type":"full-body"}]}]}
JSON

# Unconfigured repo fixture
mkdir -p "$TMP/noconfig"
echo "# claude rules" > "$TMP/noconfig/CLAUDE.md"

# .agent-sync layout fixture
mkdir -p "$TMP/alt/.agent-sync"
echo "# claude rules" > "$TMP/alt/CLAUDE.md"
cat > "$TMP/alt/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"main":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"Rules","source":"main","type":"full-body"}]}]}
JSON

run "no config -> silent" \
  "{\"tool_input\":{\"file_path\":\"$TMP/noconfig/CLAUDE.md\"},\"cwd\":\"$TMP/noconfig\"}" ""
run "tracked file -> reminder" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/CLAUDE.md\"},\"cwd\":\"$TMP/with\"}" "/agent-sync:generate"
run "tracked nested file -> reminder" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/.claude/rules/architecture.md\"},\"cwd\":\"$TMP/with\"}" "/agent-sync:generate"
run "untracked file -> silent" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/README.md\"},\"cwd\":\"$TMP/with\"}" ""
run ".agent-sync layout tracked -> reminder" \
  "{\"tool_input\":{\"file_path\":\"$TMP/alt/CLAUDE.md\"},\"cwd\":\"$TMP/alt\"}" "/agent-sync:generate"
run "malformed stdin -> silent" "not json at all" ""
run "missing file_path -> silent" "{\"cwd\":\"$TMP/with\"}" ""
run "empty stdin -> silent" "" ""

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash plugins/agent-sync/tests/run-tests.sh`
Expected: FAIL — every case errors because `hooks/check-source-edit.sh` does not exist yet (`bash: .../check-source-edit.sh: No such file or directory`), so the "tracked -> reminder" cases fail (empty output) and the runner exits non-zero.

- [ ] **Step 3: Commit the test**

```bash
git add plugins/agent-sync/tests/run-tests.sh
git commit -m "test(agent-sync): add hook test harness for check-source-edit.sh"
```

---

## Task 2: Implement the deterministic hook script

**Files:**
- Create: `plugins/agent-sync/hooks/check-source-edit.sh`
- Test: `plugins/agent-sync/tests/run-tests.sh`

- [ ] **Step 1: Write the hook script**

Create `plugins/agent-sync/hooks/check-source-edit.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# agent-sync PostToolUse hook: remind to regenerate AGENTS.md when a tracked source file is edited.
# Silent (exit 0, no output) on every path EXCEPT: a sources.json exists under cwd AND the edited
# file is one of its tracked sources. Missing jq, malformed input, or no match -> silent exit 0.

set -uo pipefail

# 1. Read hook payload from stdin.
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

# 2. jq is required; if absent, stay silent (jq is a documented agent-sync prerequisite).
command -v jq >/dev/null 2>&1 || exit 0

# 3. Extract the edited file path and the working directory.
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -z "$file_path" ]] && exit 0
[[ -z "$cwd" ]] && cwd="$PWD"

# 4. Locate sources.json directly under cwd (non-recursive, matching generate.sh auto-detect).
#    Repo root == cwd, so tracked relative paths resolve against cwd.
config=""
for candidate in "tools/agent-sync/sources.json" ".agent-sync/sources.json"; do
  if [[ -f "$cwd/$candidate" ]]; then
    config="$cwd/$candidate"
    break
  fi
done
[[ -z "$config" ]] && exit 0

# 5. Resolve a path to its canonical absolute form (parent resolved via subshell cd; portable).
abspath() {
  local p="$1" d b
  case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
  d="$(dirname "$p")"; b="$(basename "$p")"
  ( cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || printf '%s' "$p"
}

abs_edited="$(abspath "$file_path")"

# 6. Compare against each tracked source. On first match, emit reminder; otherwise stay silent.
match=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if [[ "$(abspath "$rel")" == "$abs_edited" ]]; then
    match="yes"
    break
  fi
done < <(jq -r '.files[]? // empty' "$config" 2>/dev/null)

[[ -z "$match" ]] && exit 0

# 7. Match: feed the reminder to Claude as additionalContext (faithful to the old prompt hook).
msg="[agent-sync] Source file changed. Run /agent-sync:generate to update AGENTS.md."
jq -n --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash plugins/agent-sync/tests/run-tests.sh`
Expected: PASS for all 8 cases; final line `PASS=8 FAIL=0`; exit 0.

- [ ] **Step 3: Verify the output mechanism against the hook-development skill**

Invoke the `plugin-dev:hook-development` skill and confirm that a `PostToolUse` `command` hook returning `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…"}}` on stdout with exit 0 surfaces the text to Claude.
- If confirmed: no change.
- If the skill documents a different field/mechanism (fallback: exit code 2 with the message on stderr), adjust **step 7 of the script only** and re-run `bash plugins/agent-sync/tests/run-tests.sh`. Update the "tracked -> reminder" assertions if the surfacing channel changes from stdout (e.g., assert on stderr instead). Keep all silent paths producing no output and exit 0.

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-sync/hooks/check-source-edit.sh
git commit -m "feat(agent-sync): deterministic PostToolUse hook, silent when no sources.json"
```

---

## Task 3: Switch hooks.json to the command hook

**Files:**
- Modify: `plugins/agent-sync/hooks/hooks.json`

- [ ] **Step 1: Replace the prompt hook with the command hook**

Replace the entire contents of `plugins/agent-sync/hooks/hooks.json` with:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/check-source-edit.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate the JSON**

Run: `jq . plugins/agent-sync/hooks/hooks.json`
Expected: pretty-prints without error (valid JSON).

- [ ] **Step 3: Commit**

```bash
git add plugins/agent-sync/hooks/hooks.json
git commit -m "feat(agent-sync): register command hook in place of prompt hook"
```

---

## Task 4: Add vendoring + canonical CI template to /agent-sync:init

**Files:**
- Modify: `plugins/agent-sync/commands/init.md`

- [ ] **Step 1: Replace the "Offer CI template" section with vendoring + canonical workflow**

In `plugins/agent-sync/commands/init.md`, replace the section that currently starts with
`### 6. Offer CI template` and ends just before `### 7. Generate` with exactly this:

````markdown
### 6. Vendor the generator script

So the CI drift-check (and anyone without the plugin installed) can run `generate.sh`, copy it
into the repo next to `sources.json`, stamped with the plugin version. Run:

```bash
VER=$(jq -r .version "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
DEST_DIR=tools/agent-sync   # use .agent-sync if you wrote sources.json there instead
mkdir -p "$DEST_DIR"
awk -v v="$VER" 'NR==1{print; print "# Vendored by agent-sync v" v " — re-run /agent-sync:init to refresh."; next} {print}' \
  "${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh" > "$DEST_DIR/generate.sh"
chmod +x "$DEST_DIR/generate.sh"
```

### 7. Offer CI template

Ask: "Do you want a GitHub Actions workflow for drift detection?"

If yes, write `.github/workflows/agents-sync.yml` using this canonical template (identical to
`skills/agent-sync/references/github-actions-template.md`):

```yaml
name: AGENTS.md Sync Check

on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - 'tools/agent-sync/sources.json'
      - '.agent-sync/sources.json'
      - 'AGENTS.md'
      - '**/AGENTS.md'

jobs:
  check-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get install -y jq

      - name: Check AGENTS.md sync
        run: |
          if [ -f "tools/agent-sync/generate.sh" ]; then
            bash tools/agent-sync/generate.sh --check
          elif [ -f ".agent-sync/generate.sh" ]; then
            bash .agent-sync/generate.sh --check
          else
            echo "agent-sync generate.sh not found. Run /agent-sync:init to vendor it."
            exit 1
          fi
```
````

- [ ] **Step 2: Renumber the trailing "Generate" step**

The old `### 7. Generate` heading now follows step 7 above. Change it to `### 8. Generate`
(its body — "Ask the user if they want to run `/agent-sync:generate` now." — is unchanged).

- [ ] **Step 3: Verify the vendoring command works end-to-end in a scratch repo**

Run:

```bash
SCRATCH="$(mktemp -d)"; cd "$SCRATCH"
mkdir -p .claude/rules tools/agent-sync
printf '# Test\n\n## Rules\n\nBe nice.\n' > CLAUDE.md
cat > tools/agent-sync/sources.json <<'JSON'
{"version":2,"variables":{"project_name":"Scratch"},"files":{"main":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"r","title":"Rules","source":"main","type":"extract","headings":["Rules"]}]}]}
JSON
PLUGIN="/mnt/data/ai/claude-plugins/plugins/agent-sync"
VER=$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")
awk -v v="$VER" 'NR==1{print; print "# Vendored by agent-sync v" v " — re-run /agent-sync:init to refresh."; next} {print}' \
  "$PLUGIN/scripts/generate.sh" > tools/agent-sync/generate.sh
chmod +x tools/agent-sync/generate.sh
bash tools/agent-sync/generate.sh && echo "--- check ---" && bash tools/agent-sync/generate.sh --check
head -2 tools/agent-sync/generate.sh
cd - >/dev/null && rm -rf "$SCRATCH"
```

Expected: `[agent-sync] Updated AGENTS.md.`, then `[agent-sync] OK: AGENTS.md is in sync.`, and the
`head -2` output shows the shebang followed by `# Vendored by agent-sync v0.2.0 — re-run /agent-sync:init to refresh.` (version reads from plugin.json — this will be 0.2.0 after Task 7; before Task 7 it prints 0.1.0).

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-sync/commands/init.md
git commit -m "feat(agent-sync): init vendors generate.sh and uses canonical CI template"
```

---

## Task 5: Make the reference CI template canonical (identical to init)

**Files:**
- Modify: `plugins/agent-sync/skills/agent-sync/references/github-actions-template.md`

- [ ] **Step 1: Replace the file body with the canonical template + auto-vendor note**

Replace the entire contents of
`plugins/agent-sync/skills/agent-sync/references/github-actions-template.md` with:

````markdown
# GitHub Actions Template for AGENTS.md Drift Detection

## Workflow

`/agent-sync:init` writes this to `.github/workflows/agents-sync.yml`. It is reproduced here for
reference — keep the two copies identical.

```yaml
name: AGENTS.md Sync Check

on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - 'tools/agent-sync/sources.json'
      - '.agent-sync/sources.json'
      - 'AGENTS.md'
      - '**/AGENTS.md'

jobs:
  check-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get install -y jq

      - name: Check AGENTS.md sync
        run: |
          if [ -f "tools/agent-sync/generate.sh" ]; then
            bash tools/agent-sync/generate.sh --check
          elif [ -f ".agent-sync/generate.sh" ]; then
            bash .agent-sync/generate.sh --check
          else
            echo "agent-sync generate.sh not found. Run /agent-sync:init to vendor it."
            exit 1
          fi
```

## Setup

`/agent-sync:init` vendors `generate.sh` into your repo automatically (next to `sources.json`),
so the workflow runs without the plugin installed. If you are wiring CI by hand instead, vendor
the script yourself:

```bash
mkdir -p tools/agent-sync
cp "$(claude plugin path agent-sync)/scripts/generate.sh" tools/agent-sync/generate.sh
```

## What It Does

- Triggers on PRs that modify Claude Code config files or AGENTS.md
- Runs `generate.sh --check` to verify AGENTS.md matches current config
- Fails the check if drift is detected
- Suggests running `/agent-sync:generate` to fix
````

- [ ] **Step 2: Verify the two YAML blocks are identical**

Run:

```bash
extract() { awk '/```yaml/{f=1;next} /```/{if(f)exit} f' "$1"; }
diff <(extract plugins/agent-sync/commands/init.md) \
     <(extract plugins/agent-sync/skills/agent-sync/references/github-actions-template.md) \
  && echo "IDENTICAL"
```

Expected: prints `IDENTICAL` with no diff output. (Note: `extract` returns the *first* yaml block
in each file; the first yaml block in `init.md` is the workflow.)

- [ ] **Step 3: Commit**

```bash
git add plugins/agent-sync/skills/agent-sync/references/github-actions-template.md
git commit -m "docs(agent-sync): single canonical CI template, note auto-vendoring"
```

---

## Task 6: Update README CI / migration text

**Files:**
- Modify: `plugins/agent-sync/README.md`

- [ ] **Step 1: Update the CI Integration section**

In `plugins/agent-sync/README.md`, replace the `## CI Integration` section body:

Old:
```markdown
## CI Integration

Add drift detection to your CI pipeline. See `/agent-sync:init` to generate the workflow, or see `skills/agent-sync/references/github-actions-template.md`.
```

New:
```markdown
## CI Integration

`/agent-sync:init` vendors `generate.sh` into `tools/agent-sync/` (next to `sources.json`) and can
scaffold `.github/workflows/agents-sync.yml`, so drift detection runs in CI without the plugin
installed. See `skills/agent-sync/references/github-actions-template.md` for the workflow.
```

- [ ] **Step 2: Update the Migration section's step 4**

In the `## Migration from Node.js Version` list, replace step 4:

Old:
```markdown
4. Replace `node tools/agent-sync/generate-agents.mjs` with `/agent-sync:generate`
```

New:
```markdown
4. Replace `node tools/agent-sync/generate-agents.mjs` with `/agent-sync:generate` (and run
   `/agent-sync:init` once to vendor the bash `generate.sh` for CI)
```

- [ ] **Step 3: Commit**

```bash
git add plugins/agent-sync/README.md
git commit -m "docs(agent-sync): README notes init auto-vendors generate.sh"
```

---

## Task 7: Version bump to 0.2.0 (both manifests)

**Files:**
- Modify: `plugins/agent-sync/.claude-plugin/plugin.json:3`
- Modify: `.claude-plugin/marketplace.json:45`

- [ ] **Step 1: Bump plugin.json**

In `plugins/agent-sync/.claude-plugin/plugin.json`, change `"version": "0.1.0",` to
`"version": "0.2.0",`.

- [ ] **Step 2: Bump marketplace.json**

In `.claude-plugin/marketplace.json`, in the `agent-sync` entry (around line 45), change
`"version": "0.1.0",` to `"version": "0.2.0",`.

- [ ] **Step 3: Verify both versions match**

Run:

```bash
a=$(jq -r .version plugins/agent-sync/.claude-plugin/plugin.json)
b=$(jq -r '.plugins[] | select(.name=="agent-sync") | .version' .claude-plugin/marketplace.json)
echo "plugin=$a marketplace=$b"; [ "$a" = "0.2.0" ] && [ "$b" = "0.2.0" ] && echo "OK"
```

Expected: `plugin=0.2.0 marketplace=0.2.0` then `OK`.

- [ ] **Step 4: Commit**

```bash
git add plugins/agent-sync/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(agent-sync): v0.2.0 — deterministic hook + init vendoring"
```

---

## Task 8: Final integration verification

**Files:** none (verification only)

- [ ] **Step 1: Run the hook test suite**

Run: `bash plugins/agent-sync/tests/run-tests.sh`
Expected: `PASS=8 FAIL=0`, exit 0.

- [ ] **Step 2: Re-run the scratch vendoring check and confirm the 0.2.0 stamp**

Re-run the scratch script from Task 4 Step 3.
Expected: `Updated AGENTS.md`, `OK: AGENTS.md is in sync`, and `head -2` shows
`# Vendored by agent-sync v0.2.0 — re-run /agent-sync:init to refresh.`

- [ ] **Step 3: Confirm no leftover prompt hook**

Run: `jq -r '.hooks.PostToolUse[].hooks[].type' plugins/agent-sync/hooks/hooks.json`
Expected: `command` (and nothing says `prompt`).

- [ ] **Step 4: Confirm the working tree is clean and review the branch diff**

Run: `git status --short && git log --oneline origin/main..HEAD`
Expected: clean tree; commits for test, hook, hooks.json, init, reference template, README, and version bump.
