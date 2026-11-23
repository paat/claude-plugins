---
name: closing-tribunal-loop
description: "PR-only close-out after tribunal-loop: triage findings, fix or file follow-ups, revalidate the changed diff, and document every round as a PR comment."
---

# Closing the Tribunal Loop

`tribunal-loop` is one review round; **closing the loop is iterative and PR-only**. Every code change changes the diff, so re-run until the arbiter returns **zero `critical` and zero `high` findings** on the latest diff (medium/low go to YAGNI triage) **and** CI is proven green on `LOCAL_HEAD`. Every round is documented as a PR comment — session chat is not the audit trail. Be token-frugal: read only cited files and exit early if the latest diff already has a posted closing comment and green CI. Applicability & mistakes: `references/loop-playbook.md`.

## PR prerequisite (hard)

This skill **requires an open GitHub PR** for the current branch (no local-only close-out). Before every round: `git push`, refresh `gh pr view --json number,url,headRefOid,baseRefName,headRefName,state`, and require `state == OPEN` and `LOCAL_HEAD` (`git rev-parse HEAD`) == `PR_HEAD` (`headRefOid`). Stop and push/open a PR if they diverge. The round comment's **HEAD** must be this full sha (`references/loop-playbook.md`).

## Frozen Delivery Contract

Before triage, freeze the original task outcome, acceptance checks, preserved invariants, and exclusions using only explicit user, issue, PR, or plan text. Never invent missing acceptance criteria, invariants, or exclusions. Findings may prove the diff violates that contract; they do not redefine the task. Expand the PR only for a verified defect caused/exposed by the diff required by the frozen acceptance checks or removing a material regression. Do not expand investigation for adjacent concerns beyond evidence already present — file a follow-up only with sufficient evidence, else record or drop it in **the round PR comment**.

## The Loop

Flow: Resolve open PR → `tribunal-loop` on PR HEAD → Post round PR comment → zero critical & high? (no → triage → fix + tests → push → repeat; yes → `required-checks.sh on LOCAL_HEAD` → `ok=true` or recorded `ci="none"` → **DONE**, else refuse to merge). Default panel: 3 legs from `scripts/review-panel.tsv` (`TRIBUNAL_MIN_OK_LEGS` floor default 2).

### Round number (resume-safe)

Never hardcode round 1 on a PR with prior comments. Before each round, derive `PRIOR_MAX` from existing `<!-- tribunal-round:N -->` markers across all PR comments (`references/loop-playbook.md`) and set `ROUND=$((PRIOR_MAX + 1))`. Reject duplicate `(round, HEAD)` posts. The ceiling is **cumulative on the PR**, not per session: if `PRIOR_MAX >= 5` with critical/high remaining, stop and escalate.

### Round lifecycle (order is mandatory)

Before each re-collection, carry earlier entries in `$PRIOR_REJECTIONS` (initially `[]`), and save rejected/dropped conflicts or triage outcomes as `{title,file,reason}` in `$ROUND_REJECTIONS`:
```bash
jq -s '.[2] + [.[1].provider_assessment[].false_positives[] | select(length > 0) | {title:.,file:"",reason:.}] + .[0] | reduce .[] as $r ([]; if index($r) then . else . + [$r] end)' "$PRIOR_REJECTIONS" "$PREVIOUS_ARBITRATION" "$ROUND_REJECTIONS" > "$NEXT_REJECTIONS"
```
Resolve original titles/files from retained provider findings where possible (leave unknown files empty), pass `--prior-rejections "$NEXT_REJECTIONS"` to `collect`, and retain it for the next round. Accepted conflicts must never enter it.

After each `tribunal-loop` (including the final close):
1. **Triage** findings (verify; decide fix-in-PR / follow-up / reject; file follow-ups and record rejects).
2. **Post and verify** the round PR comment for `(ROUND, LOCAL_HEAD)` **before** applying code fixes for that verdict (use `will-fix` for uncommitted fixes; never reverse to fix-before-comment). Use `references/round-comment.md` (`<!-- tribunal-round:N -->`, `gh pr comment --body-file`), including a **CI:** line from `required-checks.sh` JSON.
3. If critical/high remain: apply fixes + tests, **push**, re-check `LOCAL_HEAD == PR_HEAD`, run next round.
4. If zero critical/high: run CI-proven green on `LOCAL_HEAD` below; stop at **DONE — ready to merge / hand off** only when it passes.

### CI-proven green (refuse-to-merge)

Before declaring **DONE**, evaluate CI on `LOCAL_HEAD` (do not rely on `gh pr checks` alone — the script queries REST check-runs for the exact sha):
```bash
OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
PLUGIN_ROOT="${TRIBUNAL_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-${MUSE_PLUGIN_ROOT:-}}}}}}"
[ -f "${PLUGIN_ROOT}/scripts/required-checks.sh" ] || { echo "Set PLUGIN_ROOT to tribunal-review dir" >&2; exit 1; }
CI_EC=0; PR_BASE="$(printf '%s' "$PR_JSON" | jq -er .baseRefName)"
CI_JSON="$(bash "${PLUGIN_ROOT}/scripts/required-checks.sh" --repo "$OWNER_REPO" --sha "$LOCAL_HEAD" --base "$PR_BASE")" || CI_EC=$?
```
Repos using external CI check apps that post later must configure required checks (`ci="none"` cannot see unposted checks).
- Exit 0 (`ok=true`): proceed to **DONE — ready to merge / hand off**.
- Exit 1 ONLY when `ok=false`, `ci="none"`, and `reason="no CI configured"`: copy **no CI configured** verbatim into the **CI:** line, include full `CI_JSON`, and post/verify the comment for `LOCAL_HEAD` before allowing merge (records absent CI, not green).
- Any other non-zero exit or `ok=false` (missing/pending/failed checks or unreadable requirements): **refuse to merge**; record full `CI_JSON` and **CI:** summary in the round PR comment and stop.

## Per-Finding Triage

Triage the arbiter's deduplicated findings (`T-001`, …) against actual code (or a 30s repro; never trust consensus alone) and record one outcome per finding in the round PR comment:

| Outcome | When |
|---|---|
| **Fix in this PR** | Verified bug caused/exposed by this diff, required by frozen acceptance checks or removing a material regression |
| **File follow-up issue** | Verified, actionable bug that is pre-existing or out of PR scope (`references/follow-up-issue.md`, cross-link PR ↔ issue) |
| **Reject** | Verified false positive |

Before filing a product-code follow-up, run `work-item-triage`'s proposed-item check when installed (else comment on a covering open issue, or skip when filing is not the smallest adequate response); the round comment records the covering-issue link or the skip reason as the outcome. Note: tribunal/review-machinery follow-ups bypass that gate (biased toward filing; still dedupe). Use the smallest causal fix consistent with the existing architecture; validate the reproduced finding and original acceptance checks only. Use one commit per finding (or related cluster) tagged `tribunal T-001` in the message body.

## Stop Condition

Closes on **zero `critical` and zero `high`** on the latest diff **and** the CI gate above passing for `LOCAL_HEAD` (green or recorded `ci="none"`). Refuse to merge when required checks are missing, pending, or failed. A `high` is cleared when fixed, re-rated below high by the arbiter (failed 3b-0), or descoped (mechanism removed + follow-up or covering issue linked). Always post a final round comment on close (even round 1) with the **CI:** line.

- **YAGNI triage (leftover medium/low at close):** File a follow-up only if reachable/real and worth acting on; otherwise drop it in the **closing round PR comment** (never silent; optional PR-body mirror `Tribunal: N low findings dropped (YAGNI) — <reason>`).
- **Retry:** While any critical/high remains (never YAGNI-drop them).
- **Round 3 — checkpoint:** Post PR comment + progress note to caller; do not stop.
- **Round 5 — hard ceiling:** STOP, post ceiling PR comment, escalate with standing finding.

## Step-back workflow (anti-spiral)

- **Rounds 1–2:** Address findings directly.
- **Round 3+ while gate open:** Enter step-back mode — stop adding guards; if findings share a *class* (design problem), choose one and record it in the round PR comment:
  - **Simplify** within original acceptance criteria and existing architecture so the class disappears (broader redesign → descope or escalate).
  - **Descope** — remove contested mechanism + file follow-up or link covering issue.
  - **Confirm-unreachable** — arbiter down-rates under 3b-0 / `reachability.md`.
- **Falsifiable output:** Must produce (a) collapsed class with no-net-increase in defensive mechanisms (added ≤ removed), (b) descope + linked follow-up or covering issue, or (c) arbiter ruling the class fails 3b-0. Stay in step-back on later stalled rounds.

## Related

`tribunal-loop` | `scripts/required-checks.sh` | `references/loop-playbook.md` | `references/round-comment.md` | `references/follow-up-issue.md` | `superpowers:receiving-code-review`
