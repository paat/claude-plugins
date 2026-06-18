---
allowed-tools: Bash, Read
description: Scan a git diff for silent-failure signatures (swallowed errors, ghost transactions)
---

# /silent-failure-scanner:scan

Run the deterministic silent-failure scanner over a git diff and report any swallowed-error /
ghost-transaction signatures it finds. **Reports only — never edits code.**

## Arguments

`$ARGUMENTS` may contain:
- nothing → scan uncommitted changes (`git diff HEAD`)
- `--staged` → scan staged changes only
- `--base <ref>` → scan the branch against a base (e.g. `--base origin/main`)
- a rev-range (e.g. `HEAD~3..HEAD`) → passed to `git diff` verbatim

## What to do

1. Run the scanner in JSON mode so you can reason over the findings:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh" --format json $ARGUMENTS
   ```

2. If `summary.total` is `0`, tell the user the diff is clean of silent-failure signatures and stop.

3. Otherwise, present each finding grouped by file. For every finding give:
   - `file:line` and the finding **code** (`swallowed-exception`, `unawaited-promise`,
     `dropped-error-response`, `narrative-replacement`) with its severity.
   - The offending snippet.
   - One sentence on *why it is a silent-failure risk* — e.g. an empty `catch` makes the code
     return success while the operation actually failed (the "ghost transaction"); a removed
     `await` lets a write run fire-and-forget so failures are never observed.

4. Note the confidence levels so the user can triage:
   - `swallowed-exception` and `unawaited-promise` are **high-confidence** structural matches.
   - `dropped-error-response` (medium) and `narrative-replacement` (low) are **heuristics** —
     confirm them by reading the surrounding code before acting.

5. Do **not** fix anything. Suggest the fix in prose only (e.g. "rethrow or log-and-handle in the
   catch", "restore the `await`") and let the user decide.

## Notes

- Languages: TS/JS, Python, C#, PHP. Other files are ignored.
- The scanner is deterministic (regex matchers), so it is safe to wire into a pre-commit hook or
  CI: `scan.sh --base origin/main` exits non-zero when findings exist.
- For multi-model *judgement* on the same risk class, see the `tribunal-review` plugin's
  silent-failure lens — this scanner is the fast deterministic first pass.
