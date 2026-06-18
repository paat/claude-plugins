---
name: silent-failure-scanner
description: "Use when reviewing a diff or change for swallowed errors, ghost transactions, or silent failures — code that keeps returning success while an operation actually failed. Triggers: 'silent failure', 'ghost transaction', 'swallowed exception', 'empty catch', 'except pass', 'unawaited promise', 'removed await', 'fire and forget', 'why did this fail silently', reviewing error-handling changes, pre-commit error-handling check."
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

## Wiring into a gate

`scan.sh` exits non-zero when findings exist, so it drops into pre-commit or CI:

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
- Only the four languages above are scanned.

## Testing

```bash
bash "${CLAUDE_PLUGIN_ROOT}/tests/run-tests.sh"
```

Covers empty-catch + unawaited-promise across all four languages, zero-false-positive clean
diffs, and the two heuristic detectors.
