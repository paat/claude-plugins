# Maintain v2 contract (WIP-first, no claims)

This is the binding product contract for the maintain loop. Older claim/receipt
ceremony is not the unit of work. Issues on `main` via **auto-merge** are.

## Actors

| Actor | Directory | Merge |
|---|---|---|
| Maintain agent | `.worktrees/maintain` | **Auto-merge** when gates green |
| Investor (outside loop) | main repo (`/workspace`) | Human merge only for investor main-dir work |

Keep the maintain worktree. Do not require the investor to use it.

## Unit of work

One open GitHub issue until it is on default branch and deploy is green, **or**
parked as needs-human (then take next eligible work).

Wall-clock envelopes are **preemption**, not “throw away work.” On timeout: push
commits, leave PR open; next tick resumes.

## Selection order (always prefer unmerged WIP)

Run `maintain-wip.sh inventory` and/or treat `maintain-queue.sh` `.resumable` as
WIP. **Never start a new issue while unmerged WIP exists** that can still advance.

1. Open PR for an open issue  
2. Remote branch with commits for an open issue (no PR yet)  
3. Local branch with commits in maintain worktree  
4. Else: next eligible open issue from the queue (severity, not claims)

Closed / already on `main` → drop that WIP; do not soft-block.

## No claims

Do **not** use `maintain:claimed`, claim comments, or claim-receipt ownership as
locks. Open PR / branch **is** the in-flight lock.

## Auto-merge

Maintain-loop PRs merge via helper-authorized auto-merge when quality gates pass.
Do not wait for investor merge of maintain PRs.

## Needs-human (does not stall the slot)

1. Prefer **split**: new GH issue for the human-decision slice.  
2. Push PR if code context helps; **PR comment** with the exact decision ask.  
3. Escalate to mission-control / steering digest.  
4. **Take next eligible** work (still WIP-first among remaining items).

## Soft-blocks

Only true external holds. Never multi-hour soft-block for claim/receipt
bookkeeping (`receipt_conflict`, stale claims after issue closed on main).

## Resume after kill

Next dispatch **must** prefer the same unmerged PR/branch/commits before any
greenfield issue.
