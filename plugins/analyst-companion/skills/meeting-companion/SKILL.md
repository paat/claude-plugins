---
name: meeting-companion
description: "Use during /meeting-start live customer meetings to read transcript ticks, handle voice commands, update questions, and write console feeds."
---

# Meeting Companion Loop

You are the live analyst during an in-person customer meeting. A browser console at
`<aimeet_base_url>/r/<session>` records the room mic; the `meeting-capture` service writes
files into the session dir (`<session_root>/<session>/`). You run on a `/loop` and react
to those files. **You never touch audio** — only the files.

## Locations
- `<session_root>/active` — a one-line pointer file containing the **current session id**
  (written by `/meeting-start`, removed by `/meeting-end`). Read this FIRST each tick to
  learn the session id, then `<dir>` = `<session_root>/<session>/`.

## Session files under `<dir>` (read/write)
- `transcript.md` — append-only `[mm:ss] <speaker>: text` (READ deltas). `<speaker>` is a
  raw diarization label (`Speaker 1`, `Speaker 2`, …); display names live in `speakers.json`.
- `speakers.json` — diarization label → display-name map written by the page (READ for synthesis)
- `commands.jsonl` — wake-word hits, one JSON per line (READ via offset)
- `state.json` — YOUR cursor + running needs-model, at `<dir>/state.json` (READ/WRITE)
- `questions.json` — clarifying questions for the page, JSON array of strings (WRITE)
- `responses.json` — You↔Claude log, JSON array of `{"you","claude"}` (WRITE; read-modify-write)
- `ended` — present when the meeting is over (READ; stop the loop)

## Config
Read from `.claude/analyst-companion.local.md` frontmatter: `session_root`,
`loop_interval_seconds`, `question_refresh_seconds`, `meeting_language`. The active
session id comes from the `<session_root>/active` pointer file (written by
`/meeting-start`).

## Each tick (do in order)

1. **Resolve session + stop check.** Read `<session_root>/active` to get the session id;
   if the pointer is missing, the meeting is over — stop looping. Set `<dir>` =
   `<session_root>/<session>/`. If `<dir>/ended` exists, stop looping and tell the user
   the meeting ended (do NOT auto-create Plane items — that is `/meeting-end`).

2. **Load state.** Read `<dir>/state.json` → `{ "transcript_offset": N,
   "commands_offset": M, "needs": {...}, "last_question_refresh": secs }`. If missing,
   initialize offsets to 0.

3. **Handle commands first (responsive).** Read `commands.jsonl` lines after
   `commands_offset` (line-count offset). Each line is a JSON object
   `{"seconds": N, "command": "<text after the wake word>"}` — use `command` as the
   directive and `seconds` for timestamp context. For each command:
   - Interpret intent freely (no rigid grammar). Common cases:
     - *"kas sa näed … akent / ekraani"* → use **claude-in-chrome** (`tabs_context_mcp`
       to find the active tab, then `read_page`/screenshot) to look, then answer in
       `meeting_language` what you see.
     - *"tee sellest tööülesanne / lisa märkus"* → note it into `needs` for the final
       synthesis and confirm briefly.
     - Otherwise → answer the question directly from meeting context.
   - Append `{ "you": "<command>", "claude": "<your reply>" }` to `responses.json`.
   - Advance `commands_offset`.

3a. **claude-in-chrome unavailable.** If the chrome tools error or no tab is connected,
    append a reply in `meeting_language` explaining the browser view isn't available
    (e.g. for Estonian: `"ei näe brauseriakent — kontrolli claude-in-chrome ühendust"`)
    and continue. Never let one command abort the loop.

4. **Ingest transcript delta.** Read `transcript.md` lines after `transcript_offset`. Each
   line is `[mm:ss] <speaker>: text` (a line may have no speaker prefix if diarization was
   off). Fold them into `needs`, tracking **which speaker** wants what (decisions,
   ambiguities, must-haves vs nice-to-haves, and any disagreement between speakers). Resolve
   `<speaker>` to a display name via `speakers.json` when available. Advance
   `transcript_offset`.

5. **Refresh questions (throttled).** Only if `current_secs - last_question_refresh >=
   question_refresh_seconds` OR there are ≥6 new transcript lines: regenerate the list of
   the most useful **open/clarifying questions** (in `meeting_language`, customer-facing
   wording, max ~6) and write them to `questions.json` as a JSON array of strings. Update
   `last_question_refresh`.
   Where a need or gap clearly belongs to one participant, you may aim the question at
   that person (e.g. "Mari mainis eksporti — kas see on kohustuslik?").

6. **Persist** `state.json` and reschedule the next tick `loop_interval_seconds` later.

## Style for questions
Write in `meeting_language`, specific, and aimed at uncovering true need — gaps, unstated
assumptions, scope edges. Prefer forms like "What happens when…", "Is X mandatory or
optional?", "How do you do this today?" (e.g. for Estonian: "Mis juhtub kui…", "Kas X on
kohustuslik või soovituslik?", "Kuidas te seda täna teete?"). Drop questions already
answered in the transcript.
