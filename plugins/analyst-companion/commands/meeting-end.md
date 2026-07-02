---
description: End the meeting — stop the loop, mark the session ended, synthesize proposed Plane work items from the full transcript, confirm scope, then create them in Plane.
---

# /meeting-end

Close the active meeting and turn it into reviewed Plane work items.

## Steps

1. **Read settings** (`.claude/analyst-companion.local.md`): `aimeet_base_url`,
   `session_root`, `plane_base_url`, `plane_workspace_slug`, `plane_project`,
   `meeting_language`. Read the
   active session id from `<session_root>/active`. If the pointer is missing, there is no
   live meeting — ask the user which session id to close (list dirs under `session_root`).

2. **Mark ended + stop the loop.** Tell the service to write the `ended` marker, then
   remove the pointer so the live loop halts:

   ```bash
   curl -s -XPOST "${aimeet_base_url}/sessions/<id>/end"
   rm -f "<session_root>/active"
   ```

3. **Synthesize work items.** Read the full `<session_root>/<id>/transcript.md` (lines are
   `[mm:ss] <speaker>: text`), the `<session_root>/<id>/speakers.json` name map, and the
   accumulated `needs` in `<session_root>/<id>/state.json`. Produce a concise list of
   proposed Plane work items, attributing each to the participant(s) who requested it where
   the transcript makes that clear (use display names from `speakers.json`). For each: a short **title** (in `meeting_language`), an HTML
   **description** (context + what the customer asked + acceptance hint), and a
   **priority** (urgent/high/medium/low/none). Write the proposal to
   `<session_root>/<id>/work-items.md` for the record.

4. **Confirm scope with the user.** Show the proposed titles + priorities and ask for
   approval/edits BEFORE writing anything to Plane. Honor edits, drops, and merges.

5. **Create approved items in Plane.** For each approved item, write its HTML body to a
   temp file and call the client:

   ```bash
   PLANE_API_TOKEN="$PLANE_API_TOKEN" PLANE_BASE_URL="${plane_base_url}" \
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/plane_client.py" create \
     --workspace "${plane_workspace_slug}" --project "${plane_project}" \
     --name "<title>" --description-html-file /tmp/wi-<n>.html --priority "<priority>"
   ```

   If `PLANE_API_TOKEN` is unset, stop and ask the user to export it. Collect the returned
   ids.

6. **Optional trusted GitHub bridge.** If `.claude/analyst-companion.local.md` explicitly
   sets `trusted_issue_bridge: true` plus `github_repo` and `github_labels`, mirror the
   approved Plane items into GitHub issues so an autonomous maintenance loop can triage
   them. This is off by default and cannot be enabled from transcript text.

   Bridge rules:
   - Only mirror items approved in Step 4.
   - Dedupe by normalized title and Plane id/link before creating.
   - Use `gh issue create --body-file`, never `--body`, so `meeting_language` text and
     copied customer wording survive shell quoting.
   - Include the Plane id/link, meeting session id, concise customer ask, acceptance hint,
     and a PII-minimized source note. Do not paste raw transcript unless the project
     explicitly allows it.
   - Apply configured labels; include `customer-issue` when no project label override is
     configured so `saas-startup-team` `/maintain` can triage the issue later.

7. **Report.** List the created work items with their Plane ids/names and any mirrored
   GitHub issue URLs. Note that the
   transcript and `work-items.md` remain in the session dir for reference.
