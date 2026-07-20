# Maintain v2 contract (WIP-first, no claims)

This is the binding product contract for the maintain loop. Older claim/receipt
ceremony is not the unit of work. Issues on `main` via **auto-merge** are.

## Actors

| Actor | Directory | Merge |
|---|---|---|
| Maintain agent | Primary checkout only | **Auto-merge** when gates green |
| Investor | Same tree after portfolio pause | Human merge |

**Hard gate: primary working dir only. No linked git worktrees.**

**Pause / resume (temporal ownership, not spatial):**
- Loop owns the tree while maintain is active (`guard-active.sh` `*.active` markers stand down background hooks).
- Human work requires pausing the portfolio; the primary tree may then be dirty.
- Loop resumes only on a clean primary (dirty product tree stops maintain).

## Unit of work

One open GitHub issue until it is on default branch and deploy is green, **or**
parked as needs-human (then take next eligible work).

Wall-clock envelopes are **preemption**, not “throw away work.” On timeout: push
commits, leave PR open; next tick resumes.

## Selection order (always prefer unmerged WIP)

Run `bash maintain-wip.sh inventory --repo-root …` **before greenfield**.  
**Never start a new issue while any WIP item remains unhandled.**

WIP is broader than open PRs. Inventory includes:

1. **Dirty primary tree** (uncommitted/untracked) — `action=resume`  
   Commit, finish, or discard intentionally; never ignore dirty state.  
2. **Open PRs** — `action=resume` → continue toward auto-merge  
3. **Remote/local branches with commits not on default** (including post-squash
   leftovers that are not ancestors of `main`):  
   - open issue → `action=resume` (checkout on the primary tree, fix, PR, merge)  
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

## Needs-human / partially-fixable (does not stall the slot)

1. **No split-marker, no child issue for partials.** Deliver the machine-fixable part on
   the **same** issue; park residual judgment on that issue as `needs-human`.  
2. Machine part merged to main → **next issue** (WIP-first).  
3. Push PR / bot comment if it helps the human residual; escalate to MC digest.  
4. **Filing new issues** (re-occurrence, monitor, source-repo escalate) is a separate
   reusable skill (#326): always **duplicate pre-check before create**; no post-create
   search fail-closed. Maintain delivery does not invent issue-create ceremony.

## Soft-blocks

Only true external holds. Never multi-hour soft-block for claim/receipt
bookkeeping (`receipt_conflict`, stale claims after issue closed on main).

## Resume after kill

Next dispatch **must** prefer the same unmerged PR/branch/commits before any
greenfield issue.
