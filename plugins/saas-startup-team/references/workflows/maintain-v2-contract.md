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

Run `bash maintain-wip.sh inventory --repo-root …` **before greenfield**.  
**Never start a new issue while any WIP item remains unhandled.**

WIP is broader than open PRs. Inventory includes:

1. **Dirty maintain worktree** (uncommitted/untracked) — `action=resume`  
   Commit, finish, or discard intentionally; never ignore dirty state.  
2. **Open PRs** — `action=resume` → continue toward auto-merge  
3. **Remote/local branches with commits not on default** (including post-squash
   leftovers that are not ancestors of `main`):  
   - open issue → `action=resume` (checkout in maintain worktree, fix, PR, merge)  
   - **closed issue** → `action=delete` (stale branch; delete local + remote if safe)  
   - no issue / needs-human / epic → `action=inspect` then delete or escalate  

Handle **delete** items mechanically before or alongside resume (do not leave a
graveyard of AHEAD branches). Prefer one resume delivery per pass after cleaning
obvious `delete` leftovers.

Only when inventory `summary.resume == 0` and dirty is clean: pick next queue issue.

## No claims

Do **not** use `maintain:claimed`, claim comments, or claim-receipt ownership as
locks. Open PR / branch **is** the in-flight lock.

## Auto-merge

Maintain-loop PRs merge via helper-authorized auto-merge when quality gates pass.
Do not wait for investor merge of maintain PRs.

## Needs-human (does not stall the slot)

1. Prefer **split** when machine work can ship alone (child issue **or** residual on parent).  
2. **Duplicate pre-check always before filing any issue** (splits, re-occurrence, monitor).
   Search/list first; create only if zero matches — that pre-check **is** re-occurrence
   detection.  
3. After successful create, take the number from create output / direct `gh issue view`.
   **Never** fail-closed solely because a post-create search is empty (index lag).  
4. Machine part merged to main → next issue (WIP-first).  
5. Push PR / comment if it helps the human residual; escalate to MC digest.  
6. **Take next eligible** work (still WIP-first among remaining items).

## Soft-blocks

Only true external holds. Never multi-hour soft-block for claim/receipt
bookkeeping (`receipt_conflict`, stale claims after issue closed on main).

## Resume after kill

Next dispatch **must** prefer the same unmerged PR/branch/commits before any
greenfield issue.
