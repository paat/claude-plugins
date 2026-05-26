# agent-sync: deterministic hook + init vendoring — design

**Date:** 2026-05-26
**Plugin:** `plugins/agent-sync`
**Version target:** 0.1.0 → 0.2.0 (bugfix to hook + new init capability)

## Motivation

A real session on the `est-biz-aruannik-dev` project exposed two concrete pain points in
`agent-sync`:

1. **The PostToolUse hook nags constantly.** During a `CLAUDE.md` migration with no
   `sources.json` present, the hook fired on *every* `Edit`/`Write`. Its prompt instructs
   "if no config exists … output nothing," but because it is a **prompt-based** (LLM-evaluated)
   hook, that instruction was not reliably obeyed. The user had to type
   *"keep migrating, ignore the hook"* five times in one session.

2. **CI drift-check references a script that isn't in the repo.** `/agent-sync:init` scaffolds a
   GitHub Actions workflow that runs `tools/agent-sync/generate.sh --check`, but that script lives
   only in the plugin cache. The user had to copy it into the repo by hand. There are also two
   divergent CI templates (the inline one in `commands/init.md` and the one in
   `skills/agent-sync/references/github-actions-template.md`).

Out of scope for this round (deferred, surfaced in the same session): tool-specific output
filenames (GEMINI.md, `.github/copilot-instructions.md`, `.cursor/rules`), and the no-op
`/agent-sync:agent-sync` router skill.

## Part A — Deterministic, silent-by-default hook

### Current behavior

`hooks/hooks.json` registers a single `PostToolUse` hook on `Edit|Write` of `"type": "prompt"`.
The model is asked to locate `sources.json`, match the edited path, and either print a fixed
reminder or "output nothing." Being LLM-evaluated, it is non-deterministic and produced noise
when no config existed.

### New behavior

Replace the prompt hook with a `"type": "command"` hook that runs a new script
`${CLAUDE_PLUGIN_ROOT}/hooks/check-source-edit.sh`. Contract:

1. Read hook JSON from **stdin**; extract `.tool_input.file_path` (the edited/written file) and
   `.cwd` (the project directory the hook ran in).
2. Search from `cwd` for the config, in order: `tools/agent-sync/sources.json`, then
   `.agent-sync/sources.json`.
   - **No config found → exit 0 with no output.** This is the fix for the noise.
3. If a config is found, the **repo root is `cwd`**. Because the hook auto-detects the config
   *directly under* `cwd` (the same non-recursive search `generate.sh` uses), repo root is simply
   `cwd` — there is no need to replicate generate.sh's parent/grandparent derivation (that logic
   only applies to explicit `--config` paths). Build the set of tracked source files from `.files`
   in the config, resolved to absolute paths against `cwd`.
4. Normalize the edited `file_path` to an absolute path (resolve against `cwd` if it is ever
   relative) and compare against the tracked set.
   - **Match → emit exactly one reminder**:
     `[agent-sync] Source file changed. Run /agent-sync:generate to update AGENTS.md.`
   - **No match → exit 0 with no output.**
5. **No generator run** — the hook only does a path-set membership check, so latency on every
   `Edit`/`Write` is negligible (per the "fast path-match" decision).

### Output mechanism

The faithful equivalent of the old prompt hook (which fed reminder text to Claude as context) is
**JSON stdout with `additionalContext`** and exit 0:

```json
{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "[agent-sync] Source file changed. Run /agent-sync:generate to update AGENTS.md."}}
```

The exact schema will be confirmed against the `hook-development` skill during implementation
(fallback: exit code 2 with the message on stderr, which `PostToolUse` feeds back to Claude). The
**behavioral contract above is fixed**; only the surfacing mechanism is the detail to verify.
Whichever mechanism is chosen, the silent paths (steps 2 and 4 "no match") must produce no output
and exit 0.

### Hook registration

`hooks/hooks.json` invokes the script via `bash` so it does not depend on the executable bit
surviving plugin install, and sets a small timeout:

```json
{
  "type": "command",
  "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/check-source-edit.sh\"",
  "timeout": 10
}
```

### Robustness requirements

- Missing `jq`, malformed JSON on stdin, or a missing/empty `file_path` → exit 0 silently
  (never break the user's edit flow with hook errors).
- The script must not depend on the current working directory of the shell; use `cwd` from the
  hook payload, falling back to `$PWD` if absent.

## Part B — `/agent-sync:init` vendors generate.sh + one CI template

### Current behavior

`commands/init.md` step 6 scaffolds CI that calls `tools/agent-sync/generate.sh`, but no step
copies the script there. A second, more robust template (with a `tools/` → `.agent-sync/`
fallback) lives in `references/github-actions-template.md`. The two are inconsistent.

### New behavior

1. **Vendor the script.** After writing `sources.json`, `/agent-sync:init` copies
   `${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh` → `tools/agent-sync/generate.sh`
   (or `.agent-sync/generate.sh`, matching where `sources.json` was written), and marks it
   executable. The vendored copy gets a stamped header comment inserted right after the shebang:

   ```
   # Vendored by agent-sync v<version> — re-run /agent-sync:init to refresh.
   ```

   where `<version>` is read from the plugin's `plugin.json`. This is for traceability only.
   `init.md` specifies the exact deterministic command for a future session to run, e.g.:

   ```bash
   VER=$(jq -r .version "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
   mkdir -p tools/agent-sync   # or .agent-sync, matching where sources.json was written
   awk -v v="$VER" 'NR==1{print; print "# Vendored by agent-sync v" v " — re-run /agent-sync:init to refresh."; next} {print}' \
     "${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh" > tools/agent-sync/generate.sh
   chmod +x tools/agent-sync/generate.sh
   ```

2. **One CI template.** Both `commands/init.md` and `references/github-actions-template.md` use a
   single canonical workflow — the robust version that tries `tools/agent-sync/generate.sh` then
   `.agent-sync/generate.sh`. Remove the divergent inline template from `init.md` and point it at
   the canonical one (or inline the same content verbatim).

3. **README update.** The CI / migration section of `README.md` is updated to state that
   `/agent-sync:init` vendors `generate.sh` automatically, and the manual `cp` instructions are
   adjusted to "init does this for you; copy manually only if scaffolding by hand."

### Out of scope (confirmed)

- No separate `/agent-sync:vendor` refresh command.
- No automated staleness check comparing the vendored script's stamped version against the
  installed plugin version. The stamp is informational only (YAGNI).
- **`agents/sync-watcher.md` is intentionally unchanged.** It does not reference the prompt hook,
  fires only when explicitly invoked as an agent (no automatic noise), and already uses the
  correct `${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh` path.

## Files touched

| File | Change |
|---|---|
| `plugins/agent-sync/hooks/hooks.json` | Prompt hook → command hook invoking `check-source-edit.sh` |
| `plugins/agent-sync/hooks/check-source-edit.sh` | **New** deterministic, silent-by-default script |
| `plugins/agent-sync/commands/init.md` | Add vendoring step; collapse to one CI template |
| `plugins/agent-sync/skills/agent-sync/references/github-actions-template.md` | Canonical CI template (kept consistent with init) |
| `plugins/agent-sync/README.md` | Update CI/migration section for auto-vendoring |
| `plugins/agent-sync/.claude-plugin/plugin.json` | Version 0.1.0 → 0.2.0 |
| `.claude-plugin/marketplace.json` | agent-sync version 0.1.0 → 0.2.0 (kept in sync) |

## Testing

- **Hook, no config:** run `check-source-edit.sh` with a stdin payload editing an arbitrary file
  in a dir with no `sources.json` → expect empty output, exit 0.
- **Hook, config + tracked file:** payload editing a file listed in `.files` → expect the single
  reminder line.
- **Hook, config + untracked file:** payload editing a file not in `.files` → expect empty
  output, exit 0.
- **Hook, malformed stdin / missing jq:** → expect empty output, exit 0 (no error surfaced).
- **Vendoring:** run `/agent-sync:init` flow in a scratch repo → `tools/agent-sync/generate.sh`
  exists, is executable, carries the version stamp, and `bash tools/agent-sync/generate.sh --check`
  runs without the plugin path.
- **CI template parity:** the workflow in `init.md` and `references/` are byte-identical (or
  init references the canonical file).

## Acceptance criteria

1. Editing files in a repo with no `sources.json` produces **zero** agent-sync hook output.
2. Editing a tracked source file in a configured repo produces exactly one reminder line.
3. After `/agent-sync:init`, the scaffolded CI workflow runs `--check` successfully without the
   plugin installed, because `generate.sh` is vendored.
4. Only one CI template definition exists in the plugin.
5. Plugin version is 0.2.0 in both `plugin.json` and `marketplace.json`.
