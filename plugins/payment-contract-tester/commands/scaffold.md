---
description: Detect a repo's payment stack + gateway, draft repo-adapted contract tests using the payment-contract-tester skill, self-verify them (green on current source, red on a broken copy), and wire CI + an optional pre-push hook. Never edits payment source.
---

# /payment-contract-tester:scaffold

You are generating payment **contract tests** for the current repository and wiring enforcement.
First invoke the **payment-contract-tester skill** (`skills/payment-contract-tester/SKILL.md` and its
`references/`) — it holds the invariants, the per-gateway verified/unverified tables, and the
GREEN/RED test shapes you will adapt. Follow this flow. It is instructions for you (Claude), not a
rigid script — adapt to the repo, but never skip the honesty checks.

**Non-negotiable framing (do not regress):**
- The skill's non-negotiables bind here too — apply them, don't restate them: **CI is the
  authoritative gate** (the pre-push hook is bypassable convenience), and **a test that cannot go RED
  is worthless**. See the skill's *How to write* → GREEN/RED method and workflow §6.
- **Never edit payment source.** You write tests, the CI snippet, and (optionally) the hook — nothing else.
- **Webhook authenticity is per-gateway:** signed-payload is authoritative for Stripe/Montonio;
  for **Mollie** the webhook body is id-only and (legacy) unsigned, so the handler MUST re-fetch
  `GET /v2/payments/{id}` and branch on the fetched status — re-fetch IS the security model. Not universal re-fetch.
- **Generated tests need a human skim.** The self-verify step, the `TODO-verify-against-sandbox`
  flags, and the final report are the honesty mechanisms. Do not overclaim.

## 1. Detect stack

- `*.csproj` referencing `xunit` → **xUnit** (.NET).
- `pyproject.toml` / `requirements.txt` with `pytest.ini` (or `[tool.pytest]`) → **pytest** (Python).

These two are first-class — the golden fixtures under `reference/xunit/` and `reference/pytest/`
back them. For any other stack (JS, Go, …), **report "no first-class support yet"** and stop rather
than emit an unbacked, low-quality path.

## 2. Detect gateway(s) — propose, do not decide

Grep heuristics (brittle: wrapped clients, env-configured keys, false hits in docs/tests):
- **Montonio:** `stargate`, `merchantReference`
- **Stripe:** `stripe`, `whsec_`, `construct_event`
- **Mollie:** `mollie`, `X-Mollie-Signature`, `tr_`

Present the detected gateways as a **proposal the user confirms**. Do not proceed on a guess.

## 3. Locate seams

Find: the webhook entry point(s); order/charge creation; the money field + its type; existing payment
tests (to **imitate, not duplicate**); and the test-invocation pattern (xUnit `WebApplicationFactory`
+ DI fake, or pytest `TestClient` + `monkeypatch`). If there is **no testable seam** (no injectable
clock, no raw-body access, no fake gateway client, no durable store), **report the seam the repo
needs** instead of emitting a superficial test.

## 4. Draft contract tests

For each confirmed gateway, emit tests for the applicable invariants using the skill's GREEN/RED
shapes, adapted to the repo's idioms and the discovered seam. Use `reference/<stack>/` as the
**few-shot exemplar** (e.g. `reference/pytest/test_contract.py` + `handler.py`, or
`reference/xunit/ContractTests.cs` + `CorrectHandler.cs`).

- Only assert **VERIFIED** behavior. Comment uncertain assertions `TODO-verify-against-sandbox` —
  never silently include them. Never assert corrected-away literals (Montonio `409 ALREADY_PAID_FOR`,
  `EXPIRED`/`FAILED`; the real drop status is `ABANDONED`).
- Prefer the gateway's **official SDK helper** (e.g. Stripe `construct_event`) over hand-rolled HMAC,
  unless the repo verifies signatures manually — then assert raw-body preservation + constant-time
  compare + a recency window.
- **`reconciliation` is NOT auto-generated** — it needs a job + alerting and can't be generically
  contract-tested. Point the user to the skill's documented manual shape; do not emit a runnable test.

## 5. Self-verify the drafts (the honesty check)

- Run the drafts against the **current source** → expect **green**.
- Run them against a **deliberately-broken copy** of the handler (seed one trap per invariant, mirroring
  `reference/<stack>/` traps) → expect **red**.
- **Report any test that does not move** — reject it (a test that cannot go RED is not a contract test).

## 6. Wire enforcement

- **CI (authoritative):** copy the matching `harness/ci/` snippet into the repo
  (`.github/workflows/…` or `.gitlab-ci.yml`), set the payment-test **subset** selector
  (`pytest -k "…"` / `dotnet test --filter "…"`), and delete the other stack's block.
- **Optional pre-push hook (convenience):** offer to run
  `harness/install-pre-push.sh --test-cmd '<subset command>'`. It detects existing hook managers and
  fails safe; see `harness/README.md`.

## 7. Report

Summarize: the generated test files; the CI snippet added; whether the local hook was installed;
**every** `TODO-verify-against-sandbox` assertion; and any seam the repo still needs. State plainly
that the generated tests need a human skim — do not overclaim correctness.
