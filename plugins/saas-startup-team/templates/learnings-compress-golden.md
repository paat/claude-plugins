# /learnings-compress Golden Sample

Approved before→after transformations. A compression pass MUST reproduce these
shapes and MUST NOT drop the marked semantic elements. See `learnings-style.md`.

## Transformation 1 — emphasis stripped, label added
BEFORE:
- ALWAYS catch `httpx.HTTPError` (parent of all RequestError subclasses) as last clause when wrapping httpx calls — narrow handlers leak Bearer tokens via APM serialization
AFTER:
- Token hygiene: catch `httpx.HTTPError` (parent of all RequestError subclasses) as the last clause when wrapping httpx calls — narrow handlers leak Bearer tokens via APM serialization. Fix: broad catch + sanitize before reporting.
PRESERVED: scope (last clause), trigger (wrapping httpx), prohibited outcome (token leak), mechanism (APM serialization).

## Transformation 2 — landmine routed, not deleted
BEFORE:
- NEVER retry non-idempotent HTTP methods (POST/PATCH/DELETE) on 5xx or ReadTimeout — server may have already enacted the request; only ConnectError is safe
AFTER (goes under `## Critical Landmines`):
- Idempotency: never retry POST/PATCH/DELETE on 5xx or ReadTimeout — server may have already committed; only ConnectError (no bytes sent) is retry-safe. Fix: method-aware retry gate.
PRESERVED: exact methods, exact triggers (5xx, ReadTimeout), the ConnectError exception, the reason.

## Transformation 3 — DELETE: pure ingrained knowledge (novelty gate)
BEFORE:
- ALWAYS validate user input before using it in a database query to prevent injection
AFTER:
- (deleted) — general best-practice the model already applies; ~0 bits, no project/library/version specificity, no provenance. Recording it only dilutes the real rules.
RULE: drop textbook best-practice with no delta.

## Transformation 4 — KEEP: looks obvious, is library-version-specific (calibration guard)
BEFORE:
- `httpx.ConnectTimeout` does NOT inherit from `httpx.ConnectError` — both inherit separately from `TransportError`; verify with issubclass() before grouping
AFTER:
- Exception taxonomy: `httpx.ConnectTimeout` does NOT subclass `httpx.ConnectError` — both descend from `TransportError`; group via `issubclass()`, not assumption.
RULE: KEEP — exact library-version-specific inheritance fact the model is overconfident about; high surprise, confident-but-wrong risk. Never delete as "obvious."

## Transformation 5 — TOCTOU/race condition kept intact
BEFORE:
- NEVER check file existence then open separately — check-then-act is a TOCTOU race; use atomic open with O_CREAT|O_EXCL or try/except FileExistsError instead
AFTER:
- TOCTOU race: never os.path.exists()-then-open() as two steps — the file can change in the window between check and use. Fix: atomic open(path, "x") (O_CREAT|O_EXCL), or catch FileExistsError.
PRESERVED: the specific check-existence-then-open pattern, the race window between check and use, and the atomic-open fix via O_CREAT|O_EXCL or FileExistsError.

## Transformation 6 — cache-stampede landmine routed
BEFORE:
- NEVER invalidate a shared cache key without a lock — concurrent misses will all recompute and write back simultaneously (thundering-herd / cache stampede)
AFTER (goes under `## Critical Landmines`):
- Cache stampede: on cache miss, don't let every concurrent request recompute — single-flight the rebuild behind a per-key lock so one recomputes while others wait. Fix: per-key lock / single-flight guard.
PRESERVED: the thundering-herd / stampede framing, the concurrent-miss mechanism, the single-recompute constraint.

## Transformation 7 — overloaded term must stay spelled out
BEFORE:
- "Timeout" in requests means connect+read by default; setting `timeout=5` applies to each phase, not the total round-trip
AFTER:
- Timeout semantics: in requests, timeout=5 applies per phase (connect and read separately), NOT the total round-trip — use timeout=(2, 10) for separate connect/read limits.
PRESERVED: the overloaded qualifier is kept spelled out because "timeout" means different things in connect vs. read context; silently collapsing it loses the warning.
RULE: overloaded terms MUST stay spelled out — dropping the qualifier silently changes meaning.

## Transformation 8 — duplicate lines MERGED
BEFORE (two separate lines):
- Always close database connections in a `finally` block — unclosed connections exhaust the pool under error paths
- Ensure DB connections are released in finally — pool exhaustion happens when exceptions bypass cleanup
AFTER (single merged line):
- Connection hygiene: always release DB connections in a `finally` block — exceptions that bypass cleanup exhaust the pool. Fix: use context manager (`with conn:`) to guarantee release. (MERGED from two duplicate observations)
RULE: MERGED — both lines carried the same mechanism (pool exhaustion via exception bypass) and the same fix; collapsing to one line with a MERGED tag preserves provenance.

## Reviewer checklist (per changed line)
- [ ] Scope unchanged (not silently broadened)
- [ ] All exception cases kept
- [ ] Trigger condition kept
- [ ] Prohibited behavior kept
- [ ] Required fix kept (or intentionally dropped as vague)
- [ ] Overloaded terms still spelled out
- [ ] If DROPPED as obvious: line has NO project/library/version specificity, NO provenance tag, NO counterintuitive claim (else keep)
