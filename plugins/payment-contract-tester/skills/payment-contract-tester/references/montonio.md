# Montonio Stargate — Gateway Reference

Retrieval date: 2026-06-18. Primary sources: docs.montonio.com and help.montonio.com.

---

## Verified/Unverified claim table

| Claim | Status | Note |
|---|---|---|
| Stargate JWT HS256, `POST /orders` body `{"data":"<jwt>"}` | VERIFIED | docs.montonio.com/api/stargate/reference |
| camelCase claims (`merchantReference`, `grandTotal`, …) | VERIFIED | docs.montonio.com/api/stargate/guides/orders |
| `grandTotal` decimal at JSON level | VERIFIED | docs.montonio.com/api/stargate/guides/orders |
| `iat` independently required | UNVERIFIED | only `exp` is doc-required; treat `iat` as defensive, not a documented hard rule |
| `409 ALREADY_PAID_FOR` literal | UNVERIFIED | docs show `Order_already_paid_for`; only `401 STORE_NOT_FOUND` confirmed verbatim — do NOT assert `409`/`ALREADY_PAID_FOR` |
| `EXPIRED` / `FAILED` statuses | UNVERIFIED | real drop status is `ABANDONED`; confirmed statuses: `PENDING`, `AUTHORIZED`, `PAID`, `ABANDONED`, `PARTIALLY_REFUNDED`, `REFUNDED`, `VOIDED` |
| reuse `merchantReference` on PENDING retry | VERIFIED | help.montonio.com PENDING handling — uniqueness only for fresh orders |
| webhook is source of truth, retried 13× over 48h | VERIFIED | help.montonio.com webhook notifications |
| webhook token as `?order-token=` and `{"orderToken":…}` | VERIFIED | docs.montonio.com/api/stargate/reference |
| `localhost` `notificationUrl` rejected at create | UNVERIFIED | only reachability guidance confirmed; exact rejection behavior not documented |

---

## JWT structure

The Stargate order payload is a HS256 JWT signed with the store's secret key. Required JWT claims
(VERIFIED — docs.montonio.com/api/stargate/guides/orders, 2026-06-18):

- `exp` — expiry timestamp (UNIX seconds); doc-required.
- `merchantReference` — your order ID; must be stable for the same intent (see PENDING retry rule
  below); must be unique across distinct orders.
- `grandTotal` — decimal number at JSON level (e.g. `10.50`), NOT a string, NOT integer cents.
- `currency` — ISO 4217 (e.g. `"EUR"`).
- `returnUrl` — redirect URL after payment.
- `notificationUrl` — webhook URL; must be publicly reachable (not `localhost`).
- `lineItems` — array of line item objects.
- `payment` — payment method configuration object.

`iat` (UNVERIFIED — only `exp` is doc-required): include as defensive practice but do NOT assert
failure on its absence in contract tests.

---

## Webhook verification

The Montonio webhook is a signed JWT (HS256) delivered as the `orderToken` field in the JSON body
(or as the `order-token` query parameter). Verification steps (VERIFIED —
docs.montonio.com/api/stargate/reference, 2026-06-18):

1. Extract the JWT from `orderToken` (body) or `?order-token=` (query).
2. Verify the JWT signature with the store secret (HS256). Reject on invalid signature.
3. Check `exp` — reject expired tokens.
4. Extract `merchantReference` and `paymentStatus` from the verified claims.
5. Only branch on `paymentStatus` after signature is verified.

---

## Order status values

Confirmed statuses (VERIFIED — docs.montonio.com, 2026-06-18):
`PENDING`, `AUTHORIZED`, `PAID`, `ABANDONED`, `PARTIALLY_REFUNDED`, `REFUNDED`, `VOIDED`

Do NOT assert or branch on `EXPIRED` or `FAILED` — these are NOT documented statuses. The real
drop/abandonment status is `ABANDONED`.

---

## Hardening entries

### Amount boundary (money-minor-units applied to Montonio)

**Rule:** `grandTotal` is a decimal at the JSON level (e.g. `10.50`), not integer cents. Do not
divide or multiply by 100 when constructing the JWT; the conversion boundary is at the
application-layer money field, not at JWT serialization.

**Why it's a silent trap:** An app that stores money as integer cents and blindly passes the
integer to `grandTotal` charges 100× the intended amount (1050 cents → `1050.00 EUR`).

**Contract-test shape:**
- GREEN: `amount_cents = 1050` → JWT `grandTotal = 10.50` → gateway receives `10.50`.
- RED: pass `1050` directly → gateway receives `1050.00 EUR`.

### merchantReference + PENDING retry (reference-uniqueness applied to Montonio)

**Rule (VERIFIED — help.montonio.com, 2026-06-18):** When retrying a still-`PENDING` Montonio
order, reuse the *same* `merchantReference`. The handler must look up current order state before
assigning a reference:
- Order state `PENDING` → reuse existing `merchantReference`.
- No existing order, or existing order in a terminal state → generate a fresh `merchantReference`.

Never append a timestamp/UUID suffix on every retry. Uniqueness applies only to distinct (fresh)
orders — a retry of the same intent with a new reference risks a double-charge because Montonio
treats it as a new order.

**Contract-test shape:**
- GREEN: first attempt creates order with `merchantReference = "order-123"`; retry while PENDING
  reuses `"order-123"` → gateway dedupes → one charge.
- RED: retry generates `"order-123-retry-1"` → gateway creates a second charge → double-charge.

### Webhook signature guard (webhook-authenticity applied to Montonio)

**Rule:** Verify the JWT signature over the raw `orderToken` string before reading any claims.
Never read `paymentStatus` or `merchantReference` from an unverified JWT.

**Why it's a silent trap:** A forged POST with a crafted `{"orderToken":"<unsigned.payload.>"}` can
set any `paymentStatus` value in the claims if the handler decodes without verifying.

**Contract-test shape:**
- GREEN: valid HS256 JWT with correct secret → handler processes.
- RED: JWT signed with wrong secret (or unsigned) → handler rejects with 4xx; no state change.

### Status-transition guard (terminal-state-ordering applied to Montonio)

**Rule:** Once an order reaches a terminal status (`PAID`, `ABANDONED`, `REFUNDED`, `VOIDED`,
`PARTIALLY_REFUNDED`), do not allow a later webhook to overwrite it. Webhooks are retried 13× over
48h and can arrive out of order.

**Contract-test shape:**
- GREEN: `PAID` webhook received → status `PAID`; subsequent `ABANDONED` webhook → status remains
  `PAID`.
- RED: no terminal guard → stale `ABANDONED` overwrites `PAID`.
