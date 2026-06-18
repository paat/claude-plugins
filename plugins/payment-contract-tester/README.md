# Payment Contract Tester

A plugin for hardening payment integrations against silent failure traps common in Montonio, Stripe, and Mollie webhooks. It encodes research-grounded knowledge of webhook idempotency, signature verification, money-as-integer semantics, terminal-state transitions, and replay attack prevention — and provides runnable contract-test reference fixtures that validate correct handlers while catching seeded trap patterns.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install payment-contract-tester@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this repository, via `.claude/settings.local.json`.

## What it provides

**Skill:** A payment-integration auditing skill that teaches best practices for webhook handling and payment data safety.

**Reference fixtures:** Suites of contract tests — **Python + pytest** and **.NET + xUnit** — that run green against correct payment handlers and red against each seeded trap pattern (idempotency violations, signature failures, money-as-string, terminal-state errors, replay acceptance). Each stack mirrors the same 10 traps. Use these to validate your own payment code.

**Note:** The `/scaffold` generator and CI/hook harness for automated fixture integration arrive in a later version.

## Dependencies

- `python3` — required to run the reference contract-test fixtures
- `pytest` — required to execute the test suite
- `dotnet` (.NET 9 SDK) — required to run the xUnit reference fixtures; the self-test skips this stack cleanly if absent
- `bash 4+` — required by the plugin harness

## Verified-vs-unverified policy

The skill provides auditing guidance for Estonia-focused SaaS integrations. Reference fixtures are designed against published API documentation for Montonio, Stripe, and Mollie and tested against common handler patterns; however, no guarantee of completeness is made. Always verify the fixtures against your own production environment and payment provider's current API behavior before relying on them.
