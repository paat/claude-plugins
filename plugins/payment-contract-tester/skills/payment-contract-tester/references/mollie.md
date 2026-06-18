# Mollie — Gateway Reference

Retrieval date: 2026-06-18. Primary sources: docs.mollie.com.

Mollie uses a fundamentally different webhook model from Stripe and Montonio — understand this
before generating any contract tests.

---

## Verified/Unverified claim table

| Claim | Status | Note |
|---|---|---|
| Webhook body is id-only: `id=tr_…` (form-encoded) | VERIFIED | docs.mollie.com/reference/v2/payments-api/get-payment, 2026-06-18 |
| Handler MUST re-fetch `GET /v2/payments/{id}` with API key | VERIFIED | docs.mollie.com/guides/webhooks, 2026-06-18 |
| Legacy webhooks are unsigned (no signature header) | VERIFIED | docs.mollie.com/guides/webhooks, 2026-06-18 |
| `X-Mollie-Signature` header (next-gen): HMAC-SHA256, `sha256=` prefix | UNVERIFIED as MUST | header name and format observed in next-gen docs but not confirmed as a hard requirement; do NOT generate assertions on this header without re-verification against sandbox |
| Amount is an object `{"currency":"EUR","value":"10.00"}` | VERIFIED | docs.mollie.com/reference/v2/payments-api/get-payment, 2026-06-18 |
| `value` is a decimal string with currency-exact decimals | VERIFIED | docs.mollie.com/reference/v2/payments-api/get-payment, 2026-06-18 |
| `Idempotency-Key` (POST-only), 1h retention | VERIFIED | docs.mollie.com/reference/idempotency, 2026-06-18 |
| `Idempotent-Replayed: true` header on replayed response | VERIFIED | docs.mollie.com/reference/idempotency, 2026-06-18 |
| Refunds/chargebacks fire the same payment webhook | VERIFIED | docs.mollie.com/guides/webhooks, 2026-06-18 |
| Refunded payment status stays `paid`; reconcile via `amountRefunded` | VERIFIED | docs.mollie.com/reference/v2/payments-api/get-payment, 2026-06-18 |
| `authorized` ≠ collected (needs capture for card payments) | VERIFIED | docs.mollie.com/payments/status-changes, 2026-06-18 |
| Recurring: `sequenceType:"first"` creates mandate | VERIFIED | docs.mollie.com/payments/recurring, 2026-06-18 |
| Recurring: subsequent charges require valid mandate + `customerId` | VERIFIED | docs.mollie.com/payments/recurring, 2026-06-18 |

---

## The Mollie webhook model (the key difference)

Mollie's webhook body carries **only the payment id** — no status, no amount, no signature
(legacy). The handler MUST:

1. Parse the `id` from the form-encoded body (e.g. `id=tr_WDqYK6vllg`).
2. Re-fetch `GET /v2/payments/{id}` using the API key.
3. Branch on the **fetched** `status`, `amount`, and `amountRefunded`/`amountChargedBack`.

A forged POST with a crafted `id` can only trigger a re-fetch — the re-fetch uses the real API key
and returns the real state. A forged body can NEVER mark a payment as paid. Security comes from the
combination of an unguessable id and the authenticated re-fetch.

**Do NOT** read `status` or `amount` from the webhook body — the body contains only `id`.
**Do NOT** fulfill based on the id alone without re-fetching.

---

## Webhook authenticity model

### Legacy (current default — VERIFIED)

Legacy Mollie webhooks carry no signature header. The security model is:
- The payment `id` is unguessable.
- The handler re-fetches with an authenticated API call → gateway returns real state.
- A forged POST with a guessed id still results in a legitimate API call that returns the real
  payment state (which may not be `paid`).

**Asserting a signature on a legacy Mollie webhook is wrong.** Do not add a signature check to a
legacy integration — there is no signature to check.

### Next-gen (`X-Mollie-Signature` — UNVERIFIED as MUST)

The next-gen webhook API adds an `X-Mollie-Signature` header containing an HMAC-SHA256 of the raw
body with a `sha256=` prefix. The generated test must branch on which model the integration uses:
- **Legacy integration:** no signature header; re-fetch is the only auth.
- **Next-gen integration:** verify `X-Mollie-Signature` AND re-fetch.

**UNVERIFIED:** The `X-Mollie-Signature` header name and format are not confirmed as a hard
documented requirement as of 2026-06-18. Do not generate assertions on this header without
re-verification against a Mollie sandbox. Mark any such assertion:
`# TODO-verify-against-sandbox: X-Mollie-Signature HMAC requirement not confirmed in primary docs`

---

## Amount format

(VERIFIED — docs.mollie.com/reference/v2/payments-api/get-payment, 2026-06-18)

Mollie amounts are objects with a decimal string `value` and ISO 4217 `currency`:

```json
{"currency": "EUR", "value": "10.00"}
```

Rules:
- `value` is always a string, never a number.
- Include the currency-exact number of decimal places: `"10.00"` (EUR, 2 decimals), NOT `"10"` or
  `10.0`.
- Zero-decimal currencies (e.g. JPY): `"100"` (no decimal point).
- Never compare `value` as a float. Parse with `Decimal` (Python) or `decimal` (C#/Java).

---

## Idempotency-Key

(VERIFIED — docs.mollie.com/reference/idempotency, 2026-06-18)

- Include `Idempotency-Key` on POST requests only (not GET).
- Retention: **1 hour** (shorter than Stripe's 24h — adjust retry windows accordingly).
- A replayed response includes `Idempotent-Replayed: true` in the response headers.
- Do not reuse a key across distinct payment intents.

---

## Refunds, chargebacks, and reconciliation

(VERIFIED — docs.mollie.com/guides/webhooks, docs.mollie.com/reference/v2/payments-api/get-payment, 2026-06-18)

Refunds and chargebacks fire the **same payment webhook** as status changes. After re-fetching:
- Status may still be `paid` even after a refund.
- Check `amountRefunded` to determine how much has been refunded.
- Check `amountChargedBack` to determine how much has been charged back.
- Do not assume `paid` = no-refund. Reconcile against `amountRefunded` / `amountChargedBack`.

---

## Payment status: `authorized` ≠ collected

(VERIFIED — docs.mollie.com/payments/status-changes, 2026-06-18)

For card payments, `authorized` means the card has been authorized but funds have NOT yet been
captured. Only `paid` confirms collected funds. Do not fulfill on `authorized` unless the
integration explicitly captures at fulfillment time.

---

## Recurring payments

(VERIFIED — docs.mollie.com/payments/recurring, 2026-06-18)

1. First payment with `sequenceType: "first"` → creates a mandate.
2. Subsequent charges require:
   - `sequenceType: "recurring"`
   - A `valid` mandate linked to the `customerId`
   - `customerId` present on the payment request
3. A recurring charge attempted without a valid mandate returns an error. Test the mandate-validity
   guard explicitly.

---

## Hardening entries

### Re-fetch is mandatory (webhook-authenticity applied to Mollie)

**Rule:** Never branch on data from the webhook body other than the `id`. Re-fetch
`GET /v2/payments/{id}` before any state change.

**Why it's a silent trap:** A handler that reads `status` from the webhook body (which only
contains `id`) will either always crash (field absent) or be vulnerable to a crafted POST that
injects extra fields into the form body — both are incorrect. The real trap is a handler that was
designed for a signed-payload gateway and incorrectly applied to Mollie.

**Contract-test shape:**
- GREEN: POST `id=tr_abc` → handler re-fetches → status from API → processes correctly.
- RED: handler reads a `status` field from the request body without re-fetching → silently accepts
  forged `status=paid` in body.

### Amount as decimal string (money-minor-units applied to Mollie)

**Rule:** Parse Mollie `amount.value` as a `Decimal`, never as a float. Validate that the string
has the correct number of decimal places for the currency before storing.

**Contract-test shape:**
- GREEN: API returns `{"currency":"EUR","value":"10.00"}` → stored as `Decimal("10.00")` or
  `1000` cents (after explicit conversion) → comparison exact.
- RED: parsed as `float(10.00)` → `10.0` stored → potential mismatch on penny-level comparisons.

### Refund/chargeback reconciliation (reconciliation applied to Mollie)

**Rule:** After a payment webhook, re-fetch and check `amountRefunded` and `amountChargedBack`,
not just `status`. A `paid` payment with a refund is not a clean paid order.

**Contract-test shape:**
- GREEN: mock API returns `{"status":"paid","amountRefunded":{"currency":"EUR","value":"10.00"}}`
  → handler flags as fully refunded, not fulfilled.
- RED: handler checks `status == "paid"` only → marks as fulfilled despite full refund.
