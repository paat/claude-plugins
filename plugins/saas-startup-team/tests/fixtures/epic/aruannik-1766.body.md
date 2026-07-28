## Why this epic

A 2026-07-28 review of all 62 open issues found foreign-currency/report
integrity to be the highest-impact unresolved coherent group.

The group crosses two trust boundaries:

- customer financials: #1749 can silently feed zeroed values into VAT, P&L,
  or projection consumers after a transient rate-provider failure, while #1748
  can finalize a plausible, balanced, but incomplete report after skipping a
  period-end revaluation;
- detection integrity: #1755 and #1756 can create or suppress high-severity
  source-reconciliation findings by comparing unlike currency units or using
  an FX-wide tolerance where no conversion occurs.

The common invariant is simple: **a monetary comparison must use like units,
and an unavailable conversion must become a durable blocking/no-signal outcome,
never a plausible value or silently omitted posting.**

## Relationship to existing epics

- #1740 owned the original boundary fixes #1585 and #1586. Those fixes are
  merged; this epic owns the four residual defects discovered during their
  tribunal reviews.
- #1209 owns the replay architecture and its children #1482–#1485. Those remain
  owned by #1209. This epic may depend on or coordinate with that work, but must
  not duplicate or re-scope it.
- Do not run the reconciler children concurrently with #1484: both edit
  `scripts/replay/reconcile_source_docs.py`. Land them before #1484 or rebase
  them after it.

## Delivery order

### Track A — customer-report correctness

- [ ] #1749 — make every upfront conversion failure reach the same durable,
  customer-visible blocking signal; no consumer may inherit a silent zero.
  **Highest priority. Accounting invariant map required before coding.**
- [ ] #1748 — record a skipped period-end revaluation through the same shared
  FX-failure/discrepancy mechanism. Prefer reusing #1749's mechanism; do not
  create a second error channel. **Accounting invariant map required before
  coding.**

### Track B — source-reconciler precision

- [ ] #1756 — same-currency invoice/bank comparisons use the ordinary
  fee/rounding tolerance, regardless of whether the currency is EUR.
- [ ] #1755 — remove the legacy raw-face cross-currency comparison: compare
  EUR with EUR using reliable persisted/rate evidence, otherwise leave the
  candidate unmatched. Lock both the false-positive and false-negative
  directions already recorded on the issue.

Track A and Track B may proceed independently. Within each track, deliver
top-to-bottom because the children share mechanisms/files. Each child gets its
own branch and PR; do not bundle #1209 work.

## Epic acceptance

- Every child is closed by a locking regression test that is red on the old
  behavior and green on the fix.
- No FX-provider exception can produce a zeroed row or skipped revaluation
  without a blocking discrepancy or an explicit fail-quiet/no-signal verdict.
- Same-currency comparisons never receive an FX-conversion tolerance.
- Cross-currency comparisons never compare foreign face amounts directly with
  EUR amounts.
- #1749 and #1748 include the required accounting invariant map in the handoff
  and PR body, covering the engine, finalize/aggregator, projection, discrepancy
  surface, and tests; tribunal reviews the map before the diff.
- Each PR passes `./check.sh`, tribunal with zero critical/high findings, and
  required CI.
- After Track B is deployed, name and inspect one clean scheduled
  source-reconciler/monitor run before closing the epic.

## Business outcome

Customers are blocked with a clear retry/review outcome instead of receiving a
plausible but wrong annual report, and the monitoring channel can again be
trusted to detect settlement mistakes without manufacturing or hiding them.

