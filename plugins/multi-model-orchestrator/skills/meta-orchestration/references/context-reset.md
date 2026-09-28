# Checkpoint reset

Reset your own context at a checkpoint instead of waiting for compaction. Compaction (capped via
`autoCompactWindow`) stays the fallback.

When: an item just reached a recorded outcome (merged, parked, or filed), the handoff was updated
with it, no leg is in flight, and the queue still has work.

How (only when the host offers `clear_session` — the Claude desktop app):
1. Make the handoff's "Stop here first" the next item's first action.
2. `printf '%s\n' <handoff-path> > "${MMO_HANDOFF_DIR:-.claude/handoffs}/.reset-pending"`
3. Call `clear_session` with `session_id: "self"`, then end the turn without further tool calls.

The plugin's `SessionStart` `clear` hook consumes the marker and wakes the fresh session with the
resume instruction. If `clear_session` is unavailable or refused (for example while a Remote
Control client is connected), delete the marker and continue; compaction covers the run.
