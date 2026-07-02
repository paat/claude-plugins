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

```bash
# uncommitted changes (default)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh"
# branch vs base, machine-readable
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh" --base origin/main --format json
```

Or the command: `/silent-failure-scanner:scan [--staged | --base <ref> | <rev-range>]`

A `PreToolUse` commit gate also runs `scan.sh --staged` before every `git commit` you make through
Claude Code; on findings it denies the commit and hands them back to arbitrate — fix the swallowed
error, or re-run the same commit prefixed with `SILENT_FAILURE_ACK="<reason>"` to record a
justification and proceed.

## Exit codes (`scan.sh`)

- `0` — clean, no findings
- `1` — findings present (text lists them; json emits `{findings, summary}`)
- `>1` — usage / internal error (the gate treats this as fail-open)

## More

Flag reference, finding codes + severities, detection internals, limitations, and dependencies
(including **jq**, required at runtime by the commit-gate hook) live in the plugin **README**.
