# Usage limits

Plan limits are rolling windows (5-hour, weekly, per-model weekly) reported as percent used plus a
reset time; no provider exposes an absolute token balance. Read them so the run spends headroom
deliberately instead of discovering a wall through exit 75.

## Read

At fresh start, on resume, and at every item boundary before routing the next item — plus after any
exit 75. Not before every leg.

- Claude, in the Claude desktop app: the `get_usage` session tool (includes per-model windows, free).
- Claude elsewhere: `${CLAUDE_PLUGIN_ROOT}/scripts/usage.sh --claude-log <newest run-claude.sh
  --stream-log>` (free); with no such log and Claude legs allowed or Claude as host, add
  `--probe-claude` (one tiny call).
- Codex: `usage.sh` reads the newest `rate_limits` event among the 20 newest session logs from
  the last 8 days (free). `as-of` is that event's timestamp and may be hours old; a window whose
  reset passed since then reads 0%.
- agy: `usage.sh` asks its local `/usage` command (free).
- Grok, or any provider printing `unknown`: no constraint; exit 75 handling in
  `leg-liveness.md` still applies.

Save the `usage.sh` output to a file in the run directory and record one `Usage:` line in the
handoff State (per provider: tightest window %, its reset UTC, as-of).

## Act

A window is **tight** at ≥ 90% used when it resets after the leg would finish (its timeout).

- Pass the saved file to every `pool.sh pick|run` as `--usage <file>`; the pool skips tight
  provider-wide windows and tight per-model windows (Claude `7d_opus` binds Opus only). A Claude
  window seen only through `get_usage` goes in as `--deny claude` or `--deny <model>`. A fix-cycle
  delta stays with the SAME reviewer; if that reviewer is tight, finish the cycle and let exit 75
  route the fallback.
- `pool.sh` exits 75 with no worker left for a role a queued item needs: park only the items
  needing that role, with the printed earliest reset as their unblock condition, and keep routing
  items that are still routable elsewhere. Stop the run only once no queued item is routable.
- The host running you is tight (≥ 95% for the orchestrator itself): finish the current gate, write
  the handoff with "Stop here first: resume after <reset UTC>", and stop at this item boundary
  rather than dying mid-leg. This stop replaces the checkpoint reset (`context-reset.md`) — do not
  call `clear_session`, so no successor wakes before the reset. Recurrence belongs to the caller
  (`/loop`, cron).
- Report each routing change and stop caused by usage in the handoff's Judgment calls decided.
