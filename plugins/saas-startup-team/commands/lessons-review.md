---
name: lessons-review
description: "Optional manual inspection and override for the automated lesson-review queue. Lists verified `lesson-candidate` issues and can approve, close, or quarantine one; normal candidates are reviewed by lesson-auto-review.sh. Usage: /lessons-review"
allowed-tools: Bash, Read
user_invocable: true
---

# /lessons-review — Manual Lesson Inspection and Override

Part of the self-improvement loop (see `docs/design/self-improvement-loop.md`).
The harvester files **de-identified, PII-gated** generic improvements as
`lesson-candidate` issues in the pinned plugin repo. The normal path runs
`lesson-auto-review.sh`: one fresh isolated Opus/xhigh verdict, followed only when
unresolved by independent GPT-5.6 Sol/xhigh arbitration. High-confidence decisions
approve or reject automatically; an unresolved pair is quarantined. Transport or
timeout failures stay queued for retry. A zero-exit malformed Opus verdict invokes Sol;
a zero-exit malformed final Sol verdict is unresolved and quarantined. Each pass reviews
at most three candidates.

Use this command only when the investor wants to inspect or override that state. It is
not a prerequisite for `/lessons-deliver` and is not gated behind
`SAAS_LESSON_SYNC_ENABLED` (that exact flag guards public filing). The repo must be
pinned and every mutation still acts only on a freshly verified lesson issue.

## 1. Confirm the target repo

The pinned plugin repo comes from `$SAAS_PLUGIN_REPO` (or `--repo OWNER/REPO`).
All actions below require it — the script refuses if it is missing or malformed.

## 2. List the pending queue

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lesson-review.sh" --list --json
```

`--json` returns the raw issue records (`number`, `title`, `labels`, `url`,
`body`). The body is the filed markdown — `## Observation / ## Recommendation /
## Evidence`. Read it directly; do not scrape a table. (Drop `--json` for a quick
human-readable summary instead.)

If the queue is empty, say so and stop — there is nothing to review.

## 3. Present candidates when manual inspection was requested

For every candidate, show a compact card:

- **`#<number>` — <title>**  (`<url>`)
- **Recommendation:** the `## Recommendation` line(s) from the body.
- **Evidence:** the occurrence count + refs from `## Evidence`.
- **Domain:** the non-`lesson-candidate` label, if any.

Then ask the investor, for each: **approve**, **close**, **quarantine**, or **skip**.
This is an explicit override of the automatic queue, so do not infer a mutation from
merely listing it.

## 4. Apply the decision

**Approve** — marks the issue ready for implementation (swaps
`lesson-candidate` → `lesson-approved` in one atomic relabel):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lesson-review.sh" --approve <number> --note "<why, optional>"
```

**Close** — rejects the candidate (closed as *not planned*; an open-state listing
will no longer surface it):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lesson-review.sh" --close <number> --note "<why, optional>"
```

**Quarantine** — removes an unresolved candidate from the active queue without
approving or closing it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lesson-review.sh" --quarantine <number> --note "<why, optional>"
```

The script verifies the issue is genuinely a lesson issue before touching it,
refuses to approve a closed issue, is idempotent (re-approving / re-closing is a
no-op), and **fails closed** on any `gh` error — it never reports a success it did
not make.

## 5. Hand off approved lessons to implementation

Approved issues carry `lesson-approved`. In this plugin repository they are picked up by
the plugin-native autonomous implementer:

```
/lessons-deliver --once --repo <OWNER/REPO>
```

Do not route approved plugin lessons to `/goal-deliver`; that playbook targets finished
SaaS product repos with `.startup/go-live/solution-signoff.md`. `/lessons-deliver` turns
approved lessons into plugin code / prompt / hook changes with the plugin-specific test,
version-bump, PR, review, and merge gates.
