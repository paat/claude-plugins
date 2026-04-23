# Manual Integration Scenarios

Prerequisites: a scratch startup project initialised via `/startup`, a real
GitHub remote, `gh auth login` completed, `EST_DATALAKE_API_KEY` exported,
datalake reachable.

## Scenario 1: Happy path end-to-end

1. In the project, run `/lawyer register consent-lawful-basis 104052024010 "§ 10 lõige 2" "Lawful basis for signup consent"`. Expect success message and a `// LAW: consent-lawful-basis` suggestion.
2. Add a `// LAW: consent-lawful-basis` comment somewhere in `src/`.
3. Run `/lawyer status`. Expect: 1 total, 0 flagged.
4. Run `/lawyer check`. Expect: "Feed check complete." and no flags.
5. Fabricate a change: manually edit the index entry's `needs_review` to `true`, `change_detected_at` to today, `change` to a test object.
6. Run `/lawyer analyze consent flow`. Expect:
   - Review doc written at `docs/legal/õiguslik-muudatused-<date>.md` with a fix plan.
   - AskUserQuestion prompt: "Jah, loo issue" / "Ei, jäta hiljemaks".
7. Answer "Jah". Expect:
   - gh issue created with the fix plan as body.
   - Index entry: `gh_issue_url` set; `needs_review` still true; `.txt` unchanged; `verified_at` unchanged.
   - The topic "analyze consent flow" runs after issue creation, with a pending-fix note in its output.

## Scenario 2: PR-owned ack

1. Continuing from Scenario 1, create a branch: `git checkout -b fix/consent-amendment`.
2. Edit `src/auth/consent.ts` (the file marked with `LAW: consent-lawful-basis`) to apply the fix plan.
3. Run `/lawyer ack consent-lawful-basis`. Expect:
   - `.startup/laws/consent-lawful-basis.txt` overwritten with fresh datalake text.
   - Index entry: `needs_review=false`, `change=null`, `verified_at=<now>`, `redaktsioon_id=<from response>`, `gh_issue_url` still set.
4. `git add src/ .startup/` and commit. Expect both code and registry changes in one commit.
5. Push the branch and open a PR. Expect the diff to show both sets of changes together.

## Scenario 3: Leave-for-later path

1. Fabricate another needs_review state on a second slug.
2. Run `/lawyer analyze something else`. Expect the prompt.
3. Answer "Ei, jäta hiljemaks". Expect: exit without running the topic; reminder message about the flag staying up; no gh call.
4. Re-run `/lawyer status`. Confirm flag is still there, `gh_issue_url` is still null.

## Scenario 4: No-GitHub-remote hard-fail

1. In a project directory with no GitHub remote, fabricate a flagged entry.
2. Run `/lawyer analyze X`. Expect hard-fail during conditional gh pre-flight: "this directory is not a GitHub-backed repository."
3. Verify no partial state changes: `.txt` unchanged, `needs_review` still true, `gh_issue_url` still null.

## Scenario 5: Re-detection while issue is open

1. Continuing from Scenario 1 (with `gh_issue_url` set on an entry), fabricate a second feed event for the same `act_id` by running `/lawyer check` against a datalake where another amendment now exists (or by manipulating the registry to simulate it: set `last_feed_check_at` back and trigger detection).
2. Run `/lawyer <topic>`. Expect:
   - No new fix plan prompt for that slug.
   - Reminder at top: "Lahtised seadusemuudatuste issue'd: <url> — ootavad PR-i."
   - `change` field updated to the latest event on the existing entry.
   - The investor's topic runs normally.
