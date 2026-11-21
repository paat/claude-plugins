---
name: silent-failure-scanner
description: "Use to find swallowed errors, ghost transactions, empty catches, missing awaits, fire-and-forget calls, and false-success paths."
---

# silent-failure-scanner

Deterministic, diff-time detector for the "silent failure": error handling is broadened or removed
and the code keeps returning success while data silently fails to persist (the classic "ghost
transaction"). Scans **added** lines of a `git diff` across TS/JS, Python, C#, PHP. Reports only —
never edits code.

## Invoke

Resolve `SCAN_ROOT` from `PLUGIN_ROOT`, `CLAUDE_PLUGIN_ROOT`, `CODEX_PLUGIN_ROOT`, `GROK_PLUGIN_ROOT`, or `MUSE_PLUGIN_ROOT` — or, when all are unset, set it to the directory two levels above this loaded `SKILL.md` (never `.`, which is the target repository) and verify `$SCAN_ROOT/scripts/scan.sh` exists:

```bash
SCAN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-${MUSE_PLUGIN_ROOT:-}}}}}"
# If SCAN_ROOT is empty, set it to the installed plugin root (two dirs above this SKILL.md).
test -f "$SCAN_ROOT/scripts/scan.sh" || { echo "silent-failure-scanner plugin root required" >&2; exit 1; }
# uncommitted changes (default)
bash "$SCAN_ROOT/scripts/scan.sh"
# branch vs base, machine-readable
bash "$SCAN_ROOT/scripts/scan.sh" --base origin/main --format json
```

Or the command: `/silent-failure-scanner:scan [--staged | --base <ref> | <rev-range>]`

A `PreToolUse` commit gate also runs `scan.sh --staged` before every `git commit` you make through
Claude Code, Codex, Antigravity (`agy`), Grok, or Muse; on findings it denies the commit and hands them back to arbitrate — fix the swallowed
error, or re-run the same commit prefixed with `SILENT_FAILURE_ACK="<reason>"` to record a
justification and proceed.

## Exit codes (`scan.sh`)

- `0` — clean, no findings
- `1` — findings present (text lists them; json emits `{findings, summary}`)
- `>1` — usage / internal error (the gate treats this as fail-open)

## More

Flag reference, finding codes + severities, detection internals, limitations, and dependencies
(including **jq**, required at runtime by the commit-gate hook) live in the plugin **README**.
