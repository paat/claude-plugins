# Checkpoint reset

Reset your own context at a checkpoint instead of waiting for compaction. Compaction (capped via
`autoCompactWindow`) stays the fallback.

When: the current queue item reached a terminal outcome (merged, or parked with its gate state
recorded) and every gate for it completed; the handoff records that outcome and its `Brief` section
holds the verbatim brief plus every override in force; no leg is in flight; the queue still has
work. Filing a follow-up item is not a boundary.

How (only when the host offers `clear_session` — the Claude desktop app):
1. Make the handoff's "Stop here first" the next item's first action.
2. Write the marker where the hook reads it — `$MMO_HANDOFF_DIR` as-is when absolute, else
   `<session start dir>/${MMO_HANDOFF_DIR:-.claude/handoffs}`:
   `printf '%s\n' "$(realpath "$HANDOFF")" > "$DIR/.reset-pending"`
3. Call `clear_session` with `session_id: "self"`, then end the turn without further tool calls.

The plugin's `SessionStart` `clear` hook claims a marker younger than 5 minutes and wakes the fresh
session with the resume instruction. If `clear_session` is unavailable or refused (for example
while a Remote Control client is connected), delete the marker and continue; compaction covers the run.
