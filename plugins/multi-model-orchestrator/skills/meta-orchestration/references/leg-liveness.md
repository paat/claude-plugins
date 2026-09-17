# Leg liveness

Liveness is transcript/output mtime plus an exit marker. A process-list snapshot is not a liveness check; never `pgrep` a pattern to decide if a leg is live (paid for twice: a guard matched its own `run-grok` shell; a repo-scoped guard matched another session's leg).

## Exit marker

- Path: the leg `--out` path with `.exit` appended (example: `--out out` → `out.exit`). Record it on the handoff in-flight leg as `exit marker path`.
- Writer: the dispatch wrapper that launches the leg (including tmux-detach hosts without Claude `run_in_background` task-notification) must finish with `echo $? > <exit-marker-path>` so the marker appears only after the runner exits.
- **Live:** output mtime still advancing and exit marker absent.
- **Done:** exit marker present (contents = numeric exit code) — done regardless of any process list.
- **Not done:** marker absent (even if mtime stopped) — stalled/unknown; do not invent liveness from `pgrep`/`ps`.
- Before dispatching the next worker, wait until the prior leg is **done** (marker present).

## Provider failure exits

Runners reclassify from each CLI's own error line only (Codex last `ERROR:` sans Reconnecting; Claude `api_error_status` / text `API Error:`; Grok stderr) as:

- **75 (EX_TEMPFAIL):** transient (429/529/503, overloaded, rate limit, temporarily unavailable). Wait at least 60s, retry the same route once; if it fails 75 again, dispatch the route card's allowed `Fallback`; with no allowed fallback, park the item as blocked and continue with the next item.
  Exception — local Qwen (`run-qwen-local.sh`): its 75 means the one GPU slot is unavailable, so
  substitute the fallback immediately. Do not wait and do not retry the same route in this pass;
  waiting only re-contends for the same slot.
- **77 (EX_NOPERM):** auth (401, unauthorized, not logged in, login required, expired/invalid token or API key). Do not retry; queue re-authentication under the handoff's `OPERATOR ACTIONS REQUIRED` and continue with the next item that does not need that provider.

Before retrying an implement leg, inspect `git status` and salvage or reset partial edits on evidence (same principle as exit 124).
