# reachability.md — convention

A per-repo file at the **consumer repo root** (NOT shipped with this plugin)
that states deployment facts a diff cannot reveal, so the tribunal can judge
whether a finding is reachable in production. Injected into reviewers and the
arbiter (capped at 8 KB).

## Required shape

```
# Reachability
last-verified: 2026-06-24 (commit <sha>)

## Process model
- e.g. "production runs N gunicorn workers" / "single uvicorn worker"

## Concurrency
- e.g. "a session/cid is single-user; the same cid is never finalized
  concurrently" — state what CANNOT happen, so theoretical races are not
  rated high.

## Money / data-loss paths
- list the endpoints/flows that are genuinely money- or data-loss-bearing.
```

## Upkeep (definition-of-done)

Whenever a change touches the deployment, concurrency, or session model,
update `reachability.md` and refresh `last-verified:` in the same PR — same
discipline as the invariant-map rule. A stale file does not silently suppress
findings (the arbiter cross-checks and the blocking-finding standard still
requires an independently proven reachable path), but keeping it current keeps
reviewer noise down.
