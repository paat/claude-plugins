---
name: silent-failure-scanner
description: "Use to find swallowed errors, ghost transactions, empty catches, missing awaits, fire-and-forget calls, and false-success paths."
---

# silent-failure-scanner

A deterministic, diff-time detector for the most-cited "quiet AI bug": the **silent failure** —
an agent broadens or removes error handling and the code keeps returning success while data
silently fails to persist. These pass green test suites and ship unnoticed (the classic
"ghost transaction": a swallowed PDO exception so thousands of requests return HTTP 200 without
persisting anything).

It reports findings only. It never edits code.

## Quick start

```bash
# scan uncommitted changes
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh"

# scan a branch against its base, machine-readable
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh" --base origin/main --format json
```

Or use the command: `/silent-failure-scanner:scan [--staged | --base <ref> | <rev-range>]`

## What it flags

The scanner walks a unified `git diff` and matches the agentic-slop silent-failure signature on
**added** lines:

| Code | Severity | Signal |
|---|---|---|
| `swallowed-exception` | high | empty `catch {}` / `except: pass` / broadened-then-discarded handler |
| `unawaited-promise` | high | an `await` (or coroutine `yield`) was removed from an otherwise-identical line — the call now runs fire-and-forget |
| `dropped-error-response` | medium | a non-2xx / error response path was removed and nothing replaces it |
| `narrative-replacement` | low | a prose comment ("handled elsewhere now…") was added where real logic was removed |

High-confidence codes are structural regex matches. The medium/low codes are heuristics —
confirm by reading surrounding code before acting.

## Languages

TS/JS (`.ts .tsx .js .jsx .mjs .cjs`), Python (`.py`), C# (`.cs`), PHP (`.php`). Other files are
ignored. For PHP, the "unawaited" analog is a removed coroutine `yield` (Amp/ReactPHP).

## How detection works

- **Empty-catch** matches both single-line (`} catch (e) {}`, `except: pass`) and two-line forms
  (a `catch (...) {` / `except:` opener immediately followed by a `}`-only / `pass`-only line).
- **Unawaited-promise** pairs removals with additions: if a removed line carries `await`/`yield`
  and an added line is byte-identical *minus* that marker, the marker was dropped. This makes it
  near-zero false-positive — a clean diff has no such pair.
- All matching is on diff lines only, so it is fast and deterministic. There is no LLM in the
  detection path.

## Commit gate (built-in hook)

The plugin ships a `PreToolUse` hook (`hooks/pre-commit-gate.sh`) that activates in **every
session once the plugin is enabled — no per-repo setup**. Before any `git commit` you run through
Claude Code, it scans the **staged** diff; on findings it **denies** the commit and returns them
to Claude to arbitrate:

- **Real swallowed error / ghost transaction** → fix it (rethrow or handle, restore the `await`,
  surface the dropped response), then commit again.
- **Genuinely benign** → re-run the same commit prefixed with `SILENT_FAILURE_ACK="<reason>"`.
  The ack requires a reason, so every dismissal is recorded — and there is no re-flag loop.

The hook is deterministic (it just runs `scan.sh --staged`); the **arbiter is the Claude already
in your session** — no extra model call, no cost. It fails open: any scan/usage error allows the
commit. It only gates commits made *through Claude Code* (a raw-terminal commit has no in-session
arbiter); for a terminal backstop, vendor `scan.sh`/`scan.awk` into a real git `pre-commit` hook.

> Hooks load at session start — after enabling the plugin (or editing the hook), restart Claude
> Code for it to take effect.

## Wiring into other gates

`scan.sh` exits non-zero when findings exist, so it also drops into a vendored git hook or CI:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh" --base origin/main || {
  echo "Silent-failure signatures found — review before merging." >&2
  exit 1
}
```

## Relationship to tribunal-review

This is the **fast deterministic first pass**. The `tribunal-review` plugin provides the
multi-model *judgement* on the same risk class. Use this to catch the obvious structural
regressions cheaply on every diff; escalate ambiguous cases to tribunal-review.

## Limitations

- Detects the structural *signature*, not semantic intent — a deliberately empty catch with a
  real reason will still be flagged (review and dismiss).
- The medium/low heuristics trade precision for recall; treat them as prompts to look, not verdicts.
- Empty-catch detection covers re-added empty handlers and handlers *emptied by deletion* (the body
  removed while the `catch`/`except` line stays as context). The one known gap is an Allman-brace C#
  catch emptied purely by deletion (`catch (...)` and `{` on separate unchanged lines); re-added
  empty catches are still caught.
- Only the four languages above are scanned.

## Testing

```bash
bash "${CLAUDE_PLUGIN_ROOT}/tests/run-tests.sh"
```

Covers empty-catch + unawaited-promise across all four languages, zero-false-positive clean
diffs, and the two heuristic detectors.
