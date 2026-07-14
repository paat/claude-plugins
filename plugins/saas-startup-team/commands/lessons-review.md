---
name: lessons-review
description: "The single human gate of the self-improvement loop. Lists open `lesson-candidate` issues in the pinned plugin repo and lets the investor approve (mark ready for /lessons-deliver) or close (not generic) each one, before any implementation. Usage: /lessons-review"
allowed-tools: Bash, Read
user_invocable: true
---

# /lessons-review — the human gate

Part of the self-improvement loop (see `docs/design/self-improvement-loop.md`).
The harvester files **de-identified, PII-gated** generic improvements as
`lesson-candidate` issues in the pinned plugin repo. This command is the **one
human step** in the whole loop: the investor reviews that queue and decides, per
issue, **approve** (it is a genuine generic lesson → implement) or **close** (not
generic / not wanted). Nothing is implemented until it is approved here.

This is a deliberate, per-issue human action, so it is **not** gated behind
`SAAS_LESSON_SYNC_ENABLED` (that flag guards *automated* filing). The safety rails
are: a repo must be pinned, mutations act only on a verified `lesson-candidate`
issue, and you must see the repo + issue before deciding.

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

## 3. Present each candidate to the investor

For every candidate, show a compact card:

- **`#<number>` — <title>**  (`<url>`)
- **Recommendation:** the `## Recommendation` line(s) from the body.
- **Evidence:** the occurrence count + refs from `## Evidence`.
- **Domain:** the non-`lesson-candidate` label, if any.

Then ask the investor, for each: **approve**, **close**, or **skip** (leave it
pending for a later pass). Do not decide genericity yourself — that judgement is
exactly what this gate exists to capture from the human.

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
