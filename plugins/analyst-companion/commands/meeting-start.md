---
description: Start a live meeting analyst session — mints an aimeet session, prints the console URL to open on the laptop, and starts the companion loop.
---

# /meeting-start

Start an in-person customer meeting analyst session.

## Steps

1. **Read settings** from `.claude/analyst-companion.local.md` frontmatter:
   `aimeet_base_url`, `session_root`, `loop_interval_seconds`, `meeting_language`. If the
   file is missing, tell the user to copy `analyst-companion.local.md.example` and stop.

2. **Mint a session** — POST to the capture service:

   ```bash
   curl -s -XPOST "${aimeet_base_url}/sessions"
   ```

   Parse `{"id": "..."}`. (The service creates the session dir under `session_root`.)

3. **Write the active-session pointer and initialize state.** In `<session_root>/`:
   - Write the session id (one line, no newline needed) to `<session_root>/active`.
   - Write `<session_root>/<id>/state.json`:

     ```json
     { "transcript_offset": 0, "commands_offset": 0,
       "needs": {}, "last_question_refresh": 0 }
     ```

4. **Tell the user to open the console** on the meeting laptop (Tailscale required).
   Write the message in `meeting_language`, covering: open the console at
   `<aimeet_base_url>/r/<id>`, press the record button and allow the mic, say
   "Claude, …" to talk to you. E.g. for Estonian:

   > Ava koosoleku konsool: `<aimeet_base_url>/r/<id>`
   > Vajuta **● Salvesta** ja luba mikrofon. Ütle "Claude, …" et minuga rääkida.

5. **Start the loop.** Invoke the `loop` skill to run the `meeting-companion` skill every
   `loop_interval_seconds`. The loop resolves the session from `<session_root>/active`,
   reacts to transcript/command files, and writes the question/response feeds until the
   `active` pointer is removed (by `/meeting-end`) or the `ended` marker appears.
