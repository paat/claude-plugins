# Maintain v2 contract (superseded by v3)

WIP-first, no claims, auto-merge when gates pass. Implemented by **maintain-v3**
(`maintain-v3.md`, `scripts/maintain-v3.sh`). Primary-only leases, self-heal foreign
worktree removal, and claim ownership are deleted (#389).

- Linked worktrees coexist.
- Short scheduler / issue / release locks only.
- claim comments as ownership are forbidden.
- Auto-merge when gates pass via release-facts + exact-head merge.
