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
- Codex: `usage.sh` reads the newest Codex session log (free). Its `as-of` may be hours old; a
  window whose reset passed since then reads 0%.
- Grok, or any provider printing `unknown`: no constraint; exit 75 handling in
  `leg-liveness.md` still applies.

Record one `Usage:` line in the handoff State (per provider: tightest window %, its reset UTC, as-of).

## Act

A window is **tight** at ≥ 90% used when it resets after the leg would finish (its timeout).

- Tight provider-wide window: route the item's new legs to another allowed provider as if that
  provider were denied (`route-model-task` hard constraint). A fix-cycle delta stays with the SAME
  reviewer; if that reviewer is tight, finish the cycle and let exit 75 route the fallback.
- Tight per-model window (for example `Weekly · Fable`): avoid that model only.
- Every allowed route for a required role is tight: park the remaining items with the earliest
  reset as the unblock condition, write the handoff, and stop the run.
- The host running you is tight (≥ 95% for the orchestrator itself): finish the current gate, write
  the handoff with "Stop here first: resume after <reset UTC>", and stop at this item boundary
  rather than dying mid-leg. Recurrence belongs to the caller (`/loop`, cron).
- Report each routing change and stop caused by usage in the handoff's Judgment calls decided.
