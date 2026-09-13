# Leg liveness

Liveness is transcript/output mtime plus an exit marker. A process-list snapshot is not a liveness check; never `pgrep` a pattern to decide if a leg is live (paid for twice: a guard matched its own `run-grok` shell; a repo-scoped guard matched another session's leg).

## Exit marker

- Path: the leg `--out` path with `.exit` appended (example: `--out out` → `out.exit`). Record it on the handoff in-flight leg as `exit marker path`.
- Writer: the dispatch wrapper that launches the leg (including tmux-detach hosts without Claude `run_in_background` task-notification) must finish with `echo $? > <exit-marker-path>` so the marker appears only after the runner exits.
- **Live:** output mtime still advancing and exit marker absent.
- **Done:** exit marker present (contents = numeric exit code) — done regardless of any process list.
- **Not done:** marker absent (even if mtime stopped) — stalled/unknown; do not invent liveness from `pgrep`/`ps`.
- Before dispatching the next worker, wait until the prior leg is **done** (marker present).
