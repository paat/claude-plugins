# payment-contract-tester — Design Spec

**Issue:** #53 — New plugin: payment-contract-tester
**Date:** 2026-06-18
**Status:** Approved design, pre-implementation

## 1. Problem

Payment-integration correctness lives as tribal folklore rather than executable contract
tests. The traps are silent: a request looks fine, the gateway rejects or double-charges, and
nothing fails loudly ("silent webhook failure" is the single most-cited quiet AI bug). Estonian
SaaS teams integrate Montonio, Stripe, and Mollie by hand (often no SDK), and the crib-sheet
knowledge that prevents double-charges and forged-webhook fulfillment is captured as prose, not
as tests that run.

## 2. Goal

Ship a generic, project-agnostic Claude Code plugin that:

1. Encodes **research-grounded payment-hardening knowledge** (a skill) covering the universal
   correctness invariants plus Montonio / Stripe / Mollie specifics, each with the static
   signature and the GREEN-vs-RED contract-test shape, every claim tagged verified-vs-unverified.
2. Provides a **`/scaffold` command** that detects the target repo's stack, locates its payment
   handler, **drafts contract tests adapted to that repo**, **self-verifies** them (red against a
   deliberately-broken handler, green against current), and **wires enforcement** — a CI snippet as
   the authoritative gate plus an optional local pre-push hook for fast feedback. It never silently
   edits payment source; where a repo lacks a testable seam it *reports* the needed seam.
3. Proves the **contract-test patterns** catch the canonical traps via **self-test fixtures**
   (pytest + xUnit): a correct mock handler that runs green and seeded traps that each turn it red.
   (This validates the patterns and the generator's exemplars — not that generated tests are
   correct for every arbitrary repo, which still needs a human skim.)

Non-goals: a standalone diff/awk static scanner (that overlaps `silent-failure-scanner`; the
static signatures live as skill knowledge here, and enforcement comes from running the generated
tests). Live-gateway/sandbox integration testing. Gateways beyond Montonio/Stripe/Mollie.

## 3. Background research (grounding)

Four research streams (full reports in the issue thread / session). Key load-bearing findings:

### 3.1 Universal invariants (gateway-agnostic, confirmed across Stripe/Adyen/Montonio/Mollie)

1. **Idempotent effects (at-least-once delivery)** — webhooks are delivered *at least once*, never
   exactly once; the contract is that re-delivery yields a **single financial transition**, not that
   the gateway delivers once. Three *distinct* idempotency contracts, kept separate: (a) outbound
   **order/charge creation** (stable Idempotency-Key across retries), (b) **webhook event dedupe**
   (on the provider's event id), (c) **fulfillment** idempotency. Dedupe via a **durable DB unique
   constraint** (`ON CONFLICT DO NOTHING`), not check-then-act and not a process-local lock (which
   silently fails across processes/restarts/instances).
2. **Webhook authenticity (per-gateway model)** — *not* universal re-fetch. For **signed-payload**
   gateways (Stripe `Stripe-Signature`, Montonio JWT) the signed payload is authoritative: verify
   over the *raw* body, constant-time compare, recency/tolerance window, before any state change;
   re-fetch only for current state on ordering-sensitive flows. For **Mollie** the payload is
   id-only and (legacy) unsigned, so re-fetch from the API *is* the authenticity model (see 3.3).
3. **Money as integer minor units** (or exact decimal); never binary floats; honor the currency
   exponent (zero-decimal currencies like JPY). Watch the cents↔decimal boundary.
4. **Out-of-order & terminal-state handling** — delivery order is not guaranteed; never let a
   stale event downgrade a terminal state (e.g. PAID→ABANDONED); persist a distinct terminal
   failure status so "no event yet" ≠ "failed".
5. **Reconciliation** — the gateway, not the local DB, is the source of truth; webhook delivery can
   be permanently exhausted (Stripe retries ~3 days then stops). *Skill-knowledge only* in v0.1.0
   (a periodic-reconciliation job + alerting can't be generically auto-contract-tested); the skill
   ships a documented manual test shape (seed a gateway-side charge with no local record → job flags
   it), but `/scaffold` does not auto-generate it.
6. **Request idempotency-key / reference uniqueness** — stable key across retries of one intent,
   unique across distinct intents. Both "no key" (double-charge on retry) and "reused key across
   distinct payments" (one charge, two fulfillments) are silent.
7. **Durability before acknowledgement** — the event/effect must be persisted *before* returning
   `2xx`; acking before a durable write can permanently lose payment state when the process dies.

### 3.2 Montonio Stargate — corrections to the starting crib-sheet (these were WRONG)

- **`iat` required:** UNVERIFIED. Only `exp` is doc-required. Treat `iat` as defensive, not a
  documented hard rule.
- **`409 ALREADY_PAID_FOR`:** wrong literal. Docs show `Order_already_paid_for`; only
  `401 STORE_NOT_FOUND` confirmed verbatim. Do not assert the 409 literal.
- **`EXPIRED` / `FAILED` statuses:** not documented. The real drop status is `ABANDONED`. Confirmed
  statuses: `PENDING`, `AUTHORIZED`, `PAID`, `ABANDONED`, `PARTIALLY_REFUNDED`, `REFUNDED`, `VOIDED`.
- **"Always add a unique merchantReference suffix":** DANGEROUS. Montonio says to **reuse** the
  same reference when retrying a still-`PENDING` order, or you risk a double-charge. Uniqueness is
  for *fresh* orders only; the handler must branch on current order state.
- **Confirmed:** Stargate JWT HS256, `POST /orders` with `{"data":"<jwt>"}`, camelCase claims,
  decimal `grandTotal` at JSON level, webhook token both as `?order-token=` and `{"orderToken":…}`,
  webhook is source of truth, retried 13×/48h.

### 3.3 Mollie — different webhook model (the reason it must be a first-class gateway)

- **Webhook body carries only the `id`** (`id=tr_…`), no status, no signature. Handler MUST
  re-fetch `GET /v2/payments/{id}` with the API key and branch on the *fetched* status. A forged
  body can never mark paid — re-fetch is the security model.
- **Legacy webhooks are unauthenticated** (no signature); **next-gen** adds `X-Mollie-Signature`
  (HMAC-SHA256 of raw body, `sha256=` prefix). The generated test must branch on which model the
  integration uses — asserting a signature on a legacy webhook is wrong.
- **Amounts are an object** `{"currency":"EUR","value":"10.00"}` — `value` is a decimal *string*
  with currency-exact decimals (`"10.00"`, never `"10"`/`10.0`; JPY `"100"`).
- **Idempotency-Key** POST-only, **1h** retention (vs Stripe 24h), `Idempotent-Replayed` header.
- Refunds/chargebacks fire the *same payment webhook*; status stays `paid`; reconcile via
  `amountRefunded` / `amountChargedBack`. `authorized` ≠ collected (needs capture).
- Recurring: `sequenceType:"first"` creates a mandate; `recurring` requires a `valid` mandate +
  `customerId`.

### 3.4 Stripe

- `Stripe-Signature` (`t=`,`v1=`), HMAC-SHA256 over `t.body`, signing secret `whsec_…`, default
  tolerance 300s (never 0), constant-time compare, raw bytes. Idempotency-Key 24h, params-mismatch
  errors. Webhook event dedupe by `event.id`. Amounts integer minor units, zero-decimal caveat.
  Ordering not guaranteed → re-fetch object state. Testing via Stripe CLI `trigger`/`listen`, test
  clocks.

### 3.5 Target-repo grounding (feasibility confirmed)

- **Varustame** `/mnt/data/ai/varustame.ee/` — .NET 9, xUnit + `WebApplicationFactory`. Money
  `long SummaSentides` (cents). Montonio (`MontonioPaymentService.cs`, route
  `api/public/annetused/montonio-webhook`) **and** Mollie recurring rail. Already has a thorough
  `MontonioPaymentServiceTests.cs`. Clean DI seams (`DelegatingTestHandler`, `VarustameApiFactory`,
  `WithFakeMontonio()`).
- **Aruannik** `/mnt/data/ai/est-biz-aruannik/` — Python/FastAPI, pytest. Money `amount_cents`.
  Montonio **and** Stripe rails; file-JSON store; `threading.Lock` dedupe; already has
  `test_montonio_webhook.py` (incl. a `threading.Barrier` race test). Seam: `TestClient(app)` +
  `monkeypatch` of module-level secrets/dirs.
- **Implication:** both already have strong suites → the generator must *imitate existing seams and
  not duplicate*; these suites are the few-shot exemplars, not the target.

## 4. Architecture

A standard Claude Code plugin under `plugins/payment-contract-tester/`:

```
plugins/payment-contract-tester/
├── .claude-plugin/plugin.json
├── README.md
├── LICENSE
├── skills/payment-contract-tester/
│   ├── SKILL.md                      # entry: how to harden + how to generate tests
│   └── references/
│       ├── invariants.md             # the universal invariants (rule/why/signature/GREEN-RED), URL+date pinned
│       ├── montonio.md               # gateway specifics + verified/unverified table
│       ├── stripe.md
│       └── mollie.md
├── commands/
│   └── scaffold.md                   # /payment-contract-tester:scaffold
├── reference/                        # golden fixture projects (AC proof + generation exemplars)
│   ├── pytest/   { handler_correct + traps/* + test_contract.py + run.sh }
│   └── xunit/    { HandlerCorrect + Traps/* + ContractTests.cs + run.sh }
├── harness/
│   ├── ci/                           # CI snippets (authoritative gate): github-actions.yml, gitlab-ci.yml
│   ├── pre-push.sh                   # optional local fast-feedback hook the scaffold installs
│   └── README.md                     # CI + hook install/uninstall + config notes
└── tests/
    └── run-tests.sh                  # runs both reference suites, asserts green/red
```

### 4.1 Skill (knowledge base)

`SKILL.md` is the entry point with a tight description triggering on payment/webhook/contract-test
contexts. It teaches two things: (a) the hardening invariants, (b) the procedure the `/scaffold`
command follows. The four `references/*.md` hold the detail (progressive disclosure). Every concrete
claim carries a **VERIFIED / PARTIALLY VERIFIED / UNVERIFIED** tag with a primary-source URL **and
retrieval date (2026-06-18)**, so Claude never emits an unverified literal (e.g. Montonio
`409 ALREADY_PAID_FOR`, Mollie legacy signature). Each invariant entry has four fields: **Rule**,
**Why it's a silent trap**, **Static signature** (diff smell), **Contract-test shape** (GREEN vs RED).

### 4.2 `/scaffold` command

Generator flow (documented as command instructions for Claude, not a rigid script):

1. **Detect stack** — `*.csproj`+`xunit` → xUnit; `pyproject.toml`/`requirements.txt`+`pytest.ini`
   → pytest. These two are first-class (golden fixtures back them). Other stacks (JS, etc.) are
   *not* auto-targeted in v0.1.0 — if detected, report "no first-class support yet" rather than
   emit an unbacked low-quality path.
2. **Detect gateway(s)** — grep heuristics for Montonio (`stargate`, `merchantReference`), Stripe
   (`stripe`, `whsec_`, `construct_event`), Mollie (`mollie`, `X-Mollie-Signature`, `tr_`).
   Detection is a **proposal the user confirms**, not an automatic decision — grep is brittle
   (wrapped clients, env-configured keys, false hits in docs/tests).
3. **Locate seams** — webhook entry point(s), order-creation, money field/type, existing payment
   tests (to imitate, not duplicate), the test-invocation pattern (factory / TestClient / DI fake).
   If no testable seam exists (no injectable clock, raw-body access, fake gateway client, or durable
   store), **report the seam the repo needs** instead of emitting a superficial test.
4. **Draft contract tests** — for each confirmed gateway, emit tests for the applicable invariants
   using the skill's GREEN/RED shapes, adapted to the repo's idioms and the discovered seam. Use
   `reference/<stack>/` as the few-shot exemplar. Respect verified/unverified tags — only assert
   documented behavior; comment uncertain ones as `TODO-verify-against-sandbox`. Prefer the gateway's
   **official SDK helpers** (e.g. Stripe `construct_event`) and assert raw-body preservation, rather
   than hand-rolling HMAC unless the repo itself verifies manually.
5. **Self-verify the drafts** — run them against current source (expect green) and against a
   deliberately-broken copy of the handler (expect red). Report any test that doesn't move — a test
   that can't go red is worthless. This is the honesty check on generation quality.
6. **Wire enforcement** — write a **CI snippet** (`harness/ci/*`) as the *authoritative* gate (runs
   the payment-test subset on every push/PR; propagated to all collaborators, present in CI,
   not `--no-verify`-bypassable). Additionally offer to install the **optional local pre-push hook**
   for fast feedback (see 4.3). CI is the durable boundary; the hook is convenience.
7. **Report** — generated files, the CI snippet added, whether the local hook was installed, every
   `TODO-verify` assertion, and any seam the repo still needs.

The command never edits payment *source* — it writes tests, the CI snippet, and (optionally) the hook.

### 4.3 Enforcement: CI (authoritative) + optional local hook

**CI snippet (primary).** `harness/ci/` ships GitHub Actions + GitLab CI templates that run the
generated payment-test subset on push/PR. This is the real enforcement boundary: versioned,
team-propagated, present in CI, not locally bypassable. The scaffold adapts the runner command
(`dotnet test --filter …` / `pytest -k …`) to the repo.

**Local pre-push hook (optional, fast feedback).** `harness/pre-push.sh` runs the same subset and
blocks the push on red, for developers who want the signal before CI. Pre-push (not pre-commit)
because full runners are too slow per-commit. Risks codex flagged, handled explicitly:
- **Detect existing hook managers** (Husky, lefthook, pre-commit framework, `core.hooksPath`). If one
  is present, emit the integration for *that* manager rather than writing `.git/hooks/pre-push`.
- If installing directly, write a **clearly-delimited managed block** that composes with existing
  hook content, **preserve the executable bit**, and support clean removal. Never clobber.
- If anything is ambiguous, **print instructions instead of modifying** — fail safe, don't surprise.
- `--no-verify` is the documented escape hatch; the hook is explicitly *not* the security boundary.

### 4.4 Self-test fixtures (acceptance criteria)

`reference/pytest/` and `reference/xunit/` each contain a **correct mock handler** and the seeded
trap variants, plus the contract tests. `tests/run-tests.sh`:

- runs the suite against the correct handler → asserts **all green**;
- runs it against each trap → asserts the **specific** expected test(s) **fail** (red), so a trap
  that fails for the wrong reason is caught.

Seeded traps against the mock handler. Two groups — request-shape (the issue's canonical five) and,
per codex review, **webhook-security & state** traps that are the higher-stakes silent failures:

| # | Trap | Invariant exercised |
|---|---|---|
| 1 | Wrong claim shape (snake_case / lowercased required claim) | claim-shape / signature decode |
| 2 | Missing required claim | request well-formedness |
| 3 | Duplicate reference reused across distinct intents | reference uniqueness |
| 4 | Money as float / wrong-scale | money-as-integer-minor-units |
| 5 | Replayed webhook (non-idempotent) | idempotent effects (event dedupe) |
| 6 | Forged/unsigned webhook accepted | webhook authenticity |
| 7 | Raw body mutated/parsed before signature verify | webhook authenticity |
| 8 | Stale-timestamp webhook accepted (tolerance disabled) | replay/recency window |
| 9 | Stale event downgrades terminal state (PAID→ABANDONED) | out-of-order / terminal-state |
| 10 | Concurrent duplicate delivery double-applies (race) | durable dedupe vs check-then-act |
| 11 | Ack `2xx` returned before durable write | durability-before-ack |

Trap 10 must be a genuine concurrency test (two deliveries racing, as Aruannik's `threading.Barrier`
test does) — a sequential replay won't catch check-then-act. Gateway-specific traps (Mollie
fulfill-from-body / no-re-fetch / amount-as-string; Stripe SDK `construct_event` bypass) ship as
documented GREEN/RED examples in the skill references. **Stretch goal:** one runnable Mollie re-fetch
fixture proving the id-only model.

## 5. Testing strategy

- Plugin self-tests (`tests/run-tests.sh`) prove the AC on every change and run in the repo's
  existing test flow. Pure bash + the two language runners; document `dotnet` + `pytest` as dev
  dependencies in README. If a runner is absent, the suite skips that stack with a clear message
  (never a false green).
- Fixtures are minimal and self-contained (no network, no real gateway).

## 6. Versioning / release

- New plugin → `version: 0.1.0` in **both** `.claude-plugin/plugin.json` and root
  `.claude-plugin/marketplace.json` (kept in sync per repo rule).
- Category `testing`. README documents external deps (bash 4+, and per-stack `dotnet`/`pytest` for
  the self-tests), the three gateways, and the verified/unverified policy.
- README MUST include the standard **Installation** section with the three scopes (user / project /
  local), per the repo CLAUDE.md rule.

## 7. Open questions / risks

- **Generator quality is model-dependent** — the command guides Claude but generated tests need a
  human skim. Mitigated by strong exemplars, verified/unverified tags, the step-5 self-verify (a
  test that can't go red is rejected), and a report that flags every `TODO-verify` assertion.
- **CI vs hook framing** — CI is the authoritative gate; the local hook is fast-feedback convenience
  only. The spec no longer claims "automatic correctness" from a local hook (per codex P0).
- **Mollie next-gen webhook surface is new** — header name/format pinned by WebFetch, flagged
  UNVERIFIED-as-MUST; kept out of generator assertions except behind re-verification at codegen.
- **Source pinning** — every gateway claim in `references/*.md` stores the exact primary-doc URL and
  retrieval date (2026-06-18) so Claude can't resurrect corrected-away literals (e.g.
  `ALREADY_PAID_FOR`). Prefer fewer, stronger, source-backed assertions over a padded knowledge base.

## 8. Scope boundary (YAGNI)

**In:** skill (3 gateways + universal invariants, URL+date pinned), `/scaffold` generator with
self-verify, CI snippets (authoritative) + optional pre-push hook, pytest+xUnit self-test fixtures
with the 11-trap matrix.

**Out (v0.1.0):** standalone static scanner (silent-failure-scanner's territory); live-sandbox tests;
auto-generated reconciliation tests (skill-knowledge + manual shape only — needs a job + alerting);
JS/other stacks as first-class *fixtures* (no golden backing yet → not auto-targeted); multi-tenant /
Stripe Connect / multiple-webhook-secret / Mollie-profile edge cases; gateways beyond the three.
