---
name: payment-contract-tester
description: "Use when hardening payment integrations, writing or reviewing webhook handlers, checking for double-charge risks, verifying idempotency, testing signature validation, or generating contract tests. Triggers: 'payment', 'webhook', 'contract test', 'idempotency', 'signature verification', 'double charge', 'silent webhook failure', 'Montonio', 'Stripe', 'Mollie', 'HMAC', 'webhook authenticity', 'replay attack', 'at-least-once delivery', 'order status', 'refund reconciliation'."
---

# payment-contract-tester

Encodes research-grounded knowledge for hardening payment integrations against the class of silent
bugs that pass every single-delivery test — double-charges, forged-webhook fulfillment, and lost
payment state — and gives the GREEN/RED contract-test shape to catch them before prod.

The `/payment-contract-tester:scaffold` command uses this knowledge to draft, self-verify, and wire
contract tests adapted to the target repo. This SKILL.md is the entry point; all gateway detail and
per-invariant verification status live in `references/` (progressive disclosure).

---

## Universal invariants

Seven gateway-agnostic correctness invariants confirmed across Stripe, Montonio, and Mollie.
Full rule + silent-trap explanation + static signature + GREEN/RED shape: see
[`references/invariants.md`](references/invariants.md).

| # | Name | One-line summary |
|---|---|---|
| 1 | `idempotent-effects` | At-least-once delivery — re-delivery must yield one financial transition; dedupe via durable DB unique constraint, not check-then-act |
| 2 | `webhook-authenticity` | Per-gateway model: signed-payload authoritative (Stripe/Montonio); re-fetch forced (Mollie). NOT universal re-fetch. |
| 3 | `money-minor-units` | Never binary floats; integer minor units or exact decimal string; honor zero-decimal currencies (JPY) |
| 4 | `terminal-state-ordering` | Delivery order not guaranteed; never downgrade a terminal state; persist a distinct terminal-failure status |
| 5 | `reconciliation` | Gateway is source of truth; delivery can be permanently exhausted — skill-knowledge only, manual test shape |
| 6 | `reference-uniqueness` | Stable key per intent, unique across distinct intents; **reuse on PENDING retry (Montonio)** |
| 7 | `durability-before-ack` | Persist before returning 2xx; acking before durable write permanently loses state on crash |

---

## Gateway specifics

Claim-level VERIFIED / PARTIALLY VERIFIED / UNVERIFIED tags, corrected literals, and hardening
entries for each gateway:

- **Montonio Stargate** — [`references/montonio.md`](references/montonio.md)
  Key corrections: `EXPIRED`/`FAILED` NOT documented (real drop: `ABANDONED`);
  do NOT assert `409 ALREADY_PAID_FOR` (UNVERIFIED literal); reuse merchantReference on PENDING retry.
- **Stripe** — [`references/stripe.md`](references/stripe.md)
  Key: `Stripe-Signature` HMAC-SHA256; 300 s tolerance (never 0); raw bytes; SDK `construct_event`.
- **Mollie** — [`references/mollie.md`](references/mollie.md)
  Key: webhook body is id-only (`id=tr_…`) → mandatory re-fetch; legacy webhooks unsigned.

---

## How to write a payment contract test

### GREEN/RED method

For each invariant write two test shapes:

- **GREEN** — the correct handler satisfies the invariant; the test passes.
- **RED** — a deliberately-broken handler (one seeded trap) violates the invariant; the test fails.
  A test that cannot go RED is worthless — it is not a contract test, it is noise.

### Workflow

1. Identify which invariants apply to the target webhook handler.
2. Find the testable seam (injectable secret, raw-body access, fake gateway client, durable store).
   If no seam exists, report the seam the repo needs before generating tests.
3. Draft GREEN first; assert the correct behavior with specific, documented values.
4. Seed one trap per RED case; assert the test fails for the right reason.
5. Run self-verify: GREEN suite must pass against current source; RED suite must fail. A trap that
   does not turn a test RED is a broken trap, not a green invariant.
6. Wire enforcement: CI snippet (`harness/ci/`) is the authoritative gate; optional pre-push hook
   (`harness/pre-push.sh`) is fast-feedback convenience only.

### Stack-specific exemplars

- **pytest** — `reference/pytest/` (correct handler + trap variants + `test_contract.py`)
- **xUnit (.NET)** — `reference/xunit/` (correct handler + trap variants + `ContractTests.cs`)

---

## Verified/unverified policy

Every concrete gateway claim in this skill and its references carries one of:

- **VERIFIED** — confirmed in primary documentation with URL + retrieval date 2026-06-18.
- **PARTIALLY VERIFIED** — confirmed in one source; other sources ambiguous or absent.
- **UNVERIFIED** — stated in secondary/community sources, or assumed from behavior, not in official docs.

Rules:
- Only assert documented (VERIFIED) behavior in generated tests.
- Uncertain assertions must be commented `TODO-verify-against-sandbox` — never silently included.
- do NOT assert corrected-away literals (e.g. `ALREADY_PAID_FOR` is UNVERIFIED; `EXPIRED`/`FAILED` for Montonio)
  even if they appeared in crib-sheets or secondary sources.
- Prefer gateway SDK helpers (e.g. Stripe `construct_event`) over hand-rolled HMAC.
