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
- agy: `usage.sh` asks its local `/usage` command (free) and prints one window per quota pool:
  `5h_flash`/`7d_flash` (Gemini), `5h_claude`/`7d_claude` (Claude), `7d_argon` (Argon).
- Grok, Muse, or any provider printing `unknown`: no constraint; exit 75 handling in
  `leg-liveness.md` still applies. When the operator knows a window (the provider's account
  page), append it to the saved file in the same format, e.g. `grok 7d 40% resets
  2026-10-16T09:00Z`; `pool.sh` reads it like `usage.sh`'s own lines (`in`/`as-of` optional).

Save the `usage.sh` output to a file in the run directory and record one `Usage:` line in the
handoff State (per provider: tightest window %, its reset UTC, as-of).

For `claude-api` eligibility, authentication, identity, and credit policy, see [README routing policy](../../../README.md#routing-policy).

## Act

A window is **tight** at ≥ 90% used when it resets after the leg would finish (its timeout).

- Pass the saved file to every `pool.sh pick|run` as `--usage <file>`; the pool skips tight
  provider-wide windows and tight per-model windows (Claude `7d_opus` binds Opus only; agy
  `5h_claude` binds agy's Claude models only). A Claude
  window seen only through `get_usage` goes into the saved file as a line in that format (e.g.
  `claude 7d_opus 95% resets <UTC>`). A fix-cycle
  delta stays with the SAME reviewer; if that reviewer is tight, finish the cycle and let exit 75
  route the fallback.
- A window is **spare** when a weekly `7d` (or per-model `7d_<x>`) window is ≤ 60% used and resets
  within 24h (use it or lose it): `pool.sh` moves the rows it binds to the front of each tier, after any `--prefer` rows,
  and prints `use it or lose it: ...` on stderr. It never changes which tiers are tried.
- `pool.sh` exits 75 with no worker left for a role a queued item needs: park only the items
  needing that role, with the printed earliest reset as their unblock condition, and keep routing
  items that are still routable elsewhere. Stop the run only once no queued item is routable.
- The host running you is tight (≥ 95% for the orchestrator itself): finish the current gate, write
  the handoff with "Stop here first: resume after <reset UTC>", and stop at this item boundary
  rather than dying mid-leg. Recurrence belongs to the caller (`/loop`, cron).
- Report each routing change and stop caused by usage in the handoff's Judgment calls decided.
