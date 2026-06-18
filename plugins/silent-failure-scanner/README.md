# silent-failure-scanner

A deterministic, diff-time detector for **silent failures** — the most-cited "quiet AI bug",
where an agent broadens or removes error handling and the code keeps returning success while data
silently fails to persist. These slip past green test suites and ship to production unnoticed.

The canonical case is the **ghost transaction**: a legacy PDO wrapper gets "simplified", swallows
its exceptions, and thousands of requests return HTTP 200 without ever persisting data.

**Reports only — it never edits code.** There is no LLM in the detection path: matching is pure
regex over a `git diff`, so it is fast, deterministic, and safe to wire into a pre-commit hook or CI.

## Install

Add the `paat-plugins` marketplace and install `silent-failure-scanner`, or point Claude Code at
this repo. After cloning the repo for development:

```bash
git config core.hooksPath .githooks   # enables the version-sync pre-push check
```

## Usage

```bash
# scan uncommitted changes (git diff HEAD)
bash scripts/scan.sh

# staged changes only
bash scripts/scan.sh --staged

# a branch against its base
bash scripts/scan.sh --base origin/main

# any rev-range
bash scripts/scan.sh HEAD~3..HEAD

# machine-readable report
bash scripts/scan.sh --format json --base origin/main

# pipe a diff in
git diff | bash scripts/scan.sh
```

Or from inside Claude Code: `/silent-failure-scanner:scan [--staged | --base <ref> | <rev-range>]`

`scan.sh` exits **non-zero when findings exist**, so it gates cleanly:

```bash
bash scripts/scan.sh --base origin/main || { echo "Review silent-failure findings."; exit 1; }
```

## What it flags

On **added** diff lines, across TS/JS, Python, C#, and PHP:

| Code | Severity | Signal |
|---|---|---|
| `swallowed-exception` | high | empty `catch {}` / `except: pass` / broadened-then-discarded handler (single- and two-line forms) |
| `unawaited-promise` | high | an `await` (or coroutine `yield`) removed from an otherwise-identical line — now fire-and-forget |
| `dropped-error-response` | medium | a non-2xx / error response path removed with no replacement |
| `narrative-replacement` | low | a prose comment added where real logic was removed |

The two **high** codes are structural matches with near-zero false positives. The **medium/low**
codes are heuristics — prompts to look, not verdicts.

## Languages

`.ts .tsx .mts .cts .js .jsx .mjs .cjs` · `.py` · `.cs` · `.php`. Other files are ignored.
For PHP, the "unawaited" analog is a removed coroutine `yield` (Amp / ReactPHP).

## Output

**text** (default) — one finding per line, `file:line  [SEV] code: snippet`, with a summary on stderr.

**json** — `{ "version", "findings": [{file, line, code, severity, lang, snippet}], "summary": {total, high, medium, low} }`

## Dependencies

- bash 4+
- `awk` (gawk, mawk, or busybox awk — POSIX features only)
- `git`
- `jq` (only for running the test suite)

## Testing

```bash
bash tests/run-tests.sh
```

Covers empty-catch + unawaited-promise across all four languages, zero-false-positive clean diffs,
and the two heuristic detectors.

## Relationship to tribunal-review

This is the fast deterministic **first pass**. The `tribunal-review` plugin provides multi-model
*judgement* on the same risk class. Catch obvious structural regressions cheaply here on every
diff; escalate ambiguous cases to tribunal-review.

## License

MIT — see [LICENSE](LICENSE).
