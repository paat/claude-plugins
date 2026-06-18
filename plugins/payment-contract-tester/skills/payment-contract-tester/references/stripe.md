# Stripe — Gateway Reference

Retrieval date: 2026-06-18. Primary sources: docs.stripe.com.

---

## Verified/Unverified claim table

| Claim | Status | Note |
|---|---|---|
| `Stripe-Signature` header format: `t=<timestamp>,v1=<hmac>` | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |
| HMAC-SHA256 over `<t>.<raw_body>` (literal dot-concatenation) | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |
| Signing secret prefix `whsec_` | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |
| Default tolerance: 300 seconds | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |
| Constant-time compare required | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |
| Verify over raw bytes (not parsed/re-serialized body) | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |
| `Idempotency-Key` header: 24h retention | VERIFIED | docs.stripe.com/api/idempotent_requests, 2026-06-18 |
| Params-mismatch on `Idempotency-Key` reuse with different params | VERIFIED | docs.stripe.com/api/idempotent_requests, 2026-06-18 |
| Webhook event dedupe by `event.id` | VERIFIED | docs.stripe.com/webhooks/best-practices, 2026-06-18 |
| Amounts as integer minor units (e.g. cents) | VERIFIED | docs.stripe.com/currencies, 2026-06-18 |
| Zero-decimal currencies (JPY, KRW, …): amount is units, not cents | VERIFIED | docs.stripe.com/currencies#zero-decimal, 2026-06-18 |
| Delivery order not guaranteed → re-fetch object state | VERIFIED | docs.stripe.com/webhooks/best-practices, 2026-06-18 |
| `stripe-mock` maintenance status | UNVERIFIED | current maintenance/deprecation status not confirmed in official docs as of 2026-06-18 |
| Stripe CLI `stripe trigger` / `stripe listen` for testing | VERIFIED | docs.stripe.com/stripe-cli, 2026-06-18 |
| Test clocks for time-sensitive flows | VERIFIED | docs.stripe.com/billing/testing/test-clocks, 2026-06-18 |
| SDK `stripe.webhooks.construct_event()` preferred over hand-rolled HMAC | VERIFIED | docs.stripe.com/webhooks/signatures, 2026-06-18 |

---

## Webhook signature verification

The `Stripe-Signature` header contains a comma-separated list of `key=value` pairs
(VERIFIED — docs.stripe.com/webhooks/signatures, 2026-06-18):

```
Stripe-Signature: t=1492774577,v1=5257a869e7ecebeda32affa62cdca3fa51cad7e77a05bd539313b26f23a4c7bb
```

Verification algorithm:
1. Split on `,` to extract `t` (Unix timestamp) and `v1` (HMAC digest).
2. Compute `HMAC-SHA256(key=signing_secret, msg=t + "." + raw_body)` over raw bytes.
3. Constant-time compare the computed digest to `v1`.
4. Check that `abs(now - t) <= tolerance` (default 300s; **never set tolerance to 0**).
5. All four steps must pass before reading any payload fields.

**Raw body requirement (VERIFIED):** The HMAC covers the raw request body as bytes. Any JSON
parse-then-re-serialize will alter whitespace/key order and break the signature. Assert raw-body
preservation in tests and prefer the SDK `construct_event` helper which enforces this.

**Preferred approach:** Use `stripe.webhooks.construct_event(payload, sig_header, secret)` (or
language-equivalent). This enforces raw bytes, tolerance, and constant-time compare in one call.
Avoid hand-rolling the HMAC unless the repo does not use the Stripe SDK.

---

## Idempotency-Key (outbound requests)

(VERIFIED — docs.stripe.com/api/idempotent_requests, 2026-06-18)

- Include `Idempotency-Key` on every charge-creation and mutation request.
- The key is retained for 24 hours; within that window a duplicate key with identical params
  returns the cached response without a new charge.
- A duplicate key with **different params** returns an error (`idempotency_key_in_use` or
  `parameters_mismatch`) — do not reuse a key across distinct payment intents.

---

## Webhook event dedupe

(VERIFIED — docs.stripe.com/webhooks/best-practices, 2026-06-18)

Stripe delivers webhooks at-least-once. Dedupe by `event.id` via a durable DB unique constraint
(`INSERT … ON CONFLICT DO NOTHING`) before applying any state change. `event.id` is stable across
retry deliveries of the same event.

---

## Amounts

(VERIFIED — docs.stripe.com/currencies, 2026-06-18)

All Stripe amount fields use integer minor units:
- `EUR 10.50` → `1050` (cents)
- `USD 9.99` → `999` (cents)
- `JPY 100` → `100` (JPY is zero-decimal; NOT `10000`)

Always check the currency before dividing/multiplying. Use the Stripe currencies reference for the
complete zero-decimal list.

---

## Delivery ordering

(VERIFIED — docs.stripe.com/webhooks/best-practices, 2026-06-18)

Stripe does NOT guarantee webhook delivery order. On any ordering-sensitive flow, re-fetch the
object (`GET /v1/payment_intents/{id}`) for current state after signature verification. Never
assume the webhook payload reflects the latest state.

---

## Testing

**Stripe CLI (VERIFIED — docs.stripe.com/stripe-cli, 2026-06-18):**
- `stripe listen --forward-to localhost:4000/webhook` — forward live/test events to a local server.
- `stripe trigger payment_intent.succeeded` — fire a specific event type.
- Both respect the signing secret so signature verification passes under test.

**Test clocks (VERIFIED — docs.stripe.com/billing/testing/test-clocks, 2026-06-18):**
Advance time programmatically for subscription and trial-period flows.

**stripe-mock (UNVERIFIED — maintenance status not confirmed as of 2026-06-18):**
Check the GitHub repo for current maintenance status before adding a dependency on stripe-mock in
CI. `stripe-mock` may not reflect latest API additions. Prefer Stripe CLI or the Stripe test mode
API for integration tests.

---

## Hardening entries

### Tolerance window must not be zero (webhook-authenticity applied to Stripe)

**Rule:** Never set the timestamp tolerance to 0. A tolerance of 0 makes tests fragile (any
clock skew rejects the webhook) and provides no real security benefit over the minimum meaningful
value. The documented default is 300s.

**Contract-test shape:**
- GREEN: webhook with `t` = now → accepted.
- RED (security): webhook with `t` = 10 minutes ago (> 300s) → rejected.
- RED (config): tolerance set to 0 → even a valid webhook with a 1s clock skew is rejected
  (fragile, not secure).

### Raw-body preservation (webhook-authenticity applied to Stripe)

**Rule:** The raw request body must reach the HMAC computation unchanged. Common failure: a body-
parsing middleware (JSON, form, gzip-decompress) consumes the raw stream before the webhook handler
reads it. Use framework-specific raw-body capture and assert it in tests.

**Contract-test shape:**
- GREEN: raw body sent → `construct_event` succeeds.
- RED: body parsed-then-re-serialized before verification → HMAC mismatch → verification fails
  (the correct behavior; the trap is accepting it anyway by disabling verification).

### Event dedupe via unique constraint (idempotent-effects applied to Stripe)

**Rule:** Dedupe on `event.id` using a DB unique constraint, not a SELECT-then-INSERT guard.

**Contract-test shape:**
- GREEN: POST same event id twice → one effect; both return 2xx.
- RED (race): two concurrent POSTs of the same event id → check-then-act allows both through →
  double-effect.
