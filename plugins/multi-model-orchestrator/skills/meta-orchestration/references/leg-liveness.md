# Leg liveness

Liveness is transcript/output mtime plus an exit marker. A process-list snapshot is not a liveness check; never `pgrep` a pattern to decide if a leg is live (paid for twice: a guard matched its own `run-grok` shell; a repo-scoped guard matched another session's leg).

## Exit marker

- Path: the leg `--out` path with `.exit` appended (example: `--out out` → `out.exit`). Record it on the handoff in-flight leg as `exit marker path`.
- Keep every leg's `--out` outside the repository or in an excluded directory (the handoff directory is one): a review leg folds every other untracked file into its diff, so an earlier leg's report there would reach the next reviewer.
- Writer: the dispatch wrapper that launches the leg (including tmux-detach hosts without Claude `run_in_background` task-notification) must finish with `echo $? > <exit-marker-path>` so the marker appears only after the runner exits.
- **Live:** output mtime still advancing and exit marker absent.
- **Done:** exit marker present (contents = numeric exit code) — done regardless of any process list.
- **Not done:** marker absent (even if mtime stopped) — stalled/unknown; do not invent liveness from `pgrep`/`ps`.
- **Dead:** marker still absent 60s after the leg's deadline (dispatch time + `--timeout`, times the workers a `pool.sh run` could try): the runner enforces its timeout, so the dispatch wrapper died. Treat it as exit 124.
- Before dispatching the next worker, wait until the prior leg is **done** (marker present).

## Provider failure exits

Runners reclassify from each CLI's own error line only (Codex final `ERROR:` line, ignoring a trailing `tokens used` summary, sans Reconnecting; Claude `api_error_status` / text `API Error:`; Grok stderr; Muse failed-run `reason` and stderr; agy result `error` and stderr) as:

- **75 (EX_TEMPFAIL):** transient (429/529/503, overloaded, rate limit, temporarily unavailable) or, with `failure=limit` on the exit line, a plan limit (402, usage limit, quota, resource/balance/credits exhausted) — skip the wait and retry for a limit. Wait at least 60s, retry the same route once; if it fails 75 again, dispatch the route card's allowed `Fallback`; with no allowed fallback, park the item as blocked and continue with the next item.
  A `failure=limit` line may carry `resets=` — Codex: the provider's text verbatim (local time, no zone); Muse: a UTC timestamp the orchestrator can append to its usage file.
  Exception — local Qwen (`run-qwen-local.sh`): its 75 means the one GPU slot is unavailable, so
  substitute the fallback immediately. Do not wait and do not retry the same route in this pass;
  waiting only re-contends for the same slot.
  `pool.sh run` already moved past every unavailable worker in the tier chain: its 75 parks the
  item until the earliest reset it printed, with no wait-and-retry.
- **77 (EX_NOPERM):** auth (401, unauthorized, not logged in, login required, expired/invalid token or API key). Do not retry; queue re-authentication under the handoff's `OPERATOR ACTIONS REQUIRED` and continue with the next item that does not need that provider.

Exit 7 from an advise, review, probe, or research leg means the leg changed the repository (or, for Muse, ran another model): its report is not a verdict. Inspect `git status`, revert what the leg wrote, add a harmless test artifact to the exclude file, then rerun the leg.

Exits 8 (edit outside `--allow-paths`), 9 (`--verify-cmd` failed, timed out, or missed `--verify-pattern`) and 10 (no change) come from `leg-check.sh` after a worker exit 0: the leg ran but is not accepted; treat it as a NEEDS_WORK fix cycle with the printed paths or test tail, never as provider unavailability. Before retrying an implement leg, inspect `git status` and salvage or reset partial edits on evidence (same principle as exit 124; exit 76 = Grok max turns or Muse step cap, same salvage rule). Exit 78 (a Grok or Muse non-implement leg hit its turn or step cap without a report) leaves no partial edits; rerun with a larger `--max-turns` / `--max-steps` or a narrower packet.
