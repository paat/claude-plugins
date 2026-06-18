# Universal Payment Invariants

Gateway-agnostic correctness invariants confirmed across Stripe, Adyen, Montonio, and Mollie.
Each entry: **Rule** → **Why it's a silent trap** → **Static signature** → **Contract-test shape**.

Retrieval date: 2026-06-18. Tags apply to the invariant framing (universally confirmed);
gateway-specific evidence is tagged in the per-gateway reference files.

---

## idempotent-effects

**Rule:** Webhooks are delivered *at least once*. Re-delivery must yield a single financial
transition. Keep three idempotency contracts separate: outbound create (stable Idempotency-Key
across retries), webhook event dedupe (on the provider's event id), and fulfillment. Dedupe via a
durable DB unique constraint (`INSERT … ON CONFLICT DO NOTHING`), never check-then-act, never a
process-local lock.

**Why it's a silent trap:** A naive `credit(); return 200` passes every single-delivery test and
works in dev where retries never fire. In prod a timeout → gateway retry → double-credit. The
check-then-act variant passes single-threaded tests but races under concurrent redelivery.

**Static signature:** webhook handler mutates balance/order state with no prior lookup against a
processed-events store keyed on the *provider's* event id; dedup as SELECT-then-conditional-INSERT
rather than a unique constraint.

**Contract-test shape:**
- GREEN: POST the same event id twice → effect applied once; both responses 2xx.
- RED: no dedupe → second POST doubles the effect. Stronger: fire two deliveries concurrently;
  correct nets one effect via the unique constraint.

---

## webhook-authenticity

**Rule:** Per-gateway model — NOT universal re-fetch.
- **Signed-payload gateways (Stripe, Montonio):** the signed payload is authoritative. Verify over
  the *raw* body (not parsed/re-serialized), constant-time compare, enforce recency/tolerance window,
  before any state change. Re-fetch only for current state on ordering-sensitive flows.
- **Mollie (legacy):** payload is id-only and unsigned. Re-fetch `GET /v2/payments/{id}` with the
  API key is the authenticity model — a forged body can never mark paid.
- **Mollie (next-gen):** `X-Mollie-Signature` header (HMAC-SHA256, `sha256=` prefix) — see
  `mollie.md` for UNVERIFIED-as-MUST status.

**Why it's a silent trap:** Fulfilling from the webhook body without re-fetch (Mollie) or
signature verification (Stripe/Montonio) allows a forged POST to mark any order paid. The test
suite for a dev integration that never sends forged requests will never catch this.

**Static signature:** webhook handler reads `status` or `amount` directly from `request.body`
without either (a) verifying the signature over raw bytes, or (b) re-fetching the resource from
the gateway API. Also: parsed body passed to signature verify function rather than raw bytes.

**Contract-test shape:**
- GREEN: valid signed webhook (Stripe/Montonio) → handler processes; Mollie id-only → handler
  re-fetches and processes.
- RED: forged/unsigned POST → handler rejects (Stripe/Montonio); Mollie handler that reads status
  from body without re-fetch → fulfills forged payload (the trap).

---

## money-minor-units

**Rule:** Never represent money as binary floats. Use integer minor units (e.g. cents as `int`) or
an exact decimal type / decimal string. Honor the currency exponent: zero-decimal currencies (JPY,
KRW) have no minor-unit subdivision — `100 JPY` is 100, not 10000. Watch the cents↔decimal
boundary on every conversion.

**Why it's a silent trap:** `0.1 + 0.2 ≠ 0.3` in IEEE-754 float. A webhook round-trip that
serializes `10.00` as a float and compares to a stored float can silently mismatch on the penny,
producing incorrect partial-payment decisions or double-charges after rounding.

**Static signature:** payment amount stored or compared as `float`/`double`; currency-agnostic
division by 100 (breaks JPY/KRW); `==` comparison of floats across serialization boundary.

**Contract-test shape:**
- GREEN: amount `1050` (cents) stored, retrieved, compared as integer; `EUR 10.50` ↔ `1050` round-
  trips exactly; JPY `100` stored as `100` (not `10000`).
- RED: store as float → `10.1 + 0.2` serializes to `10.299999…`; comparison fails or rounds wrong.

---

## terminal-state-ordering

**Rule:** Webhook delivery order is NOT guaranteed. A stale event must never downgrade a terminal
state (e.g. `PAID → ABANDONED` when an earlier `ABANDONED` event arrives after `PAID`). Persist a
distinct terminal failure status so that "no event yet received" is distinguishable from "payment
failed".

**Why it's a silent trap:** A developer testing against a well-behaved gateway always sees
in-order delivery; out-of-order events only emerge under retry storms or network reorderings in
prod. A handler that blindly sets `status = event.status` can silently downgrade a completed
payment and trigger a duplicate fulfillment on the next reconciliation run.

**Static signature:** handler unconditionally overwrites order status from webhook payload with no
check whether current DB status is terminal; no distinct terminal-failure value (e.g. using `null`
for "failed" conflated with "not yet received").

**Contract-test shape:**
- GREEN: POST `PAID` webhook → status `PAID`; then POST stale `ABANDONED` webhook → status remains
  `PAID`.
- RED: no terminal-state guard → stale `ABANDONED` overwrites `PAID`.

---

## reconciliation

**Rule:** The gateway, not the local DB, is the source of truth. Webhook delivery can be
permanently exhausted (e.g. Stripe retries ~72h then stops; Montonio retries 13× over 48h). A
payment that the gateway considers complete but for which no webhook was ever processed must be
detected and flagged by a periodic reconciliation job, not by waiting for a webhook that will never
arrive.

**Why it's a silent trap:** Assuming webhook delivery is sufficient for payment accounting means
permanently-lost events silently leave orders in `PENDING` state indefinitely. No single-delivery
test exercises the exhausted-retry path.

**Static signature:** no periodic reconciliation job (or alerting on stale-pending orders); sole
payment state update path is the webhook handler.

**Contract-test shape (skill-knowledge only — NOT auto-generated by `/scaffold`):**
This invariant requires a reconciliation job and alerting that are too repo-specific to
auto-generate. The manual test shape is:
- Seed a gateway-side charge (or mock) with no corresponding local record.
- Run the reconciliation job.
- Assert: the stale-pending order is flagged/alerted.
The `/scaffold` command documents this shape but does not emit runnable tests for it.

---

## reference-uniqueness

**Rule:** A request idempotency key or `merchantReference` must be stable across retries of one
payment intent, and unique across distinct intents. Both failure modes are silent:
- **No key:** gateway creates a new charge on every retry → double-charge.
- **Reused key across distinct payments:** gateway dedupes to one charge → one payment, two
  fulfillments.

**Montonio PENDING-retry exception (VERIFIED — help.montonio.com, 2026-06-18):** When retrying a
still-`PENDING` Montonio order, reuse the *same* `merchantReference`. Generating a fresh suffix on
retry risks a double-charge. The handler must branch on current order state: if the existing order
is still `PENDING`, reuse the reference; only generate a new one for a fresh/post-terminal attempt.

**Why it's a silent trap:** Both mis-uses produce plausible-looking responses with no error. The
double-charge case requires a real retry; the reuse-across-intents case requires two concurrent
payments to race through the same reference.

**Static signature:** idempotency key generated fresh on each retry; `merchantReference` always
suffixed with a timestamp/UUID regardless of current order state; no state lookup before reference
assignment.

**Contract-test shape:**
- GREEN: two retries of the same intent share one reference → one charge.
- GREEN (PENDING): retry of a PENDING Montonio order reuses reference → no double-charge.
- RED: fresh key on each retry → gateway creates two charges.
- RED: same reference for two distinct payments → one charge, two fulfillments.

---

## durability-before-ack

**Rule:** The payment event and its effect must be persisted (durably committed to the DB) *before*
returning `2xx` to the gateway. Returning `2xx` before a durable write acks the webhook; if the
process dies after the ack but before the write, the gateway considers delivery complete and will
not retry — the payment state is permanently lost.

**Why it's a silent trap:** In happy-path testing the write always completes before the response
returns. The failure is only observable when the process crashes between `return 200` and the write
completing, which is a rare production event that no standard test exercises.

**Static signature:** `return 200 OK` before `await db.save(event)` / `commit()` / `flush()`; fire-
and-forget DB write (unawaited async call) before response.

**Contract-test shape:**
- GREEN: DB write committed → then 2xx returned; on simulated crash-after-ack the state is present
  in DB.
- RED: 2xx returned before write committed → on simulated crash (raise after return, or kill process
  mid-write) the payment state is absent from DB.
