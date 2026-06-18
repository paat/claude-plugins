# payment-contract-tester — Handoff for Plans 2 & 3

> **Purpose:** Everything a fresh session needs to write and execute Plan 2 (xUnit fixtures) and
> Plan 3 (`/scaffold` generator + CI/hook harness) for the `payment-contract-tester` plugin,
> without re-deriving the research or the architecture. Read this first, then the spec.

## Status (as of 2026-06-18)

- **Plan 1 is SHIPPED to `main`** (commit `e037a53`, pushed to origin). Issue #53.
- Plugin lives at `plugins/payment-contract-tester/`, version **0.1.0** (synced in
  `.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json`).
- Plan 1 delivered: packaging, README (3 install scopes), the skill + 4 reference docs, the
  **pytest** reference fixture (correct handler + 10 traps), and the self-test orchestrator.
  `bash plugins/payment-contract-tester/tests/run-tests.sh` → `ALL SELF-TESTS PASSED`, exit 0.

## Canonical source documents (read these)

- **Design spec:** `docs/superpowers/specs/2026-06-18-payment-contract-tester-design.md`
  — §3 is the grounded research (universal invariants + Montonio/Stripe/Mollie), §4 the
  architecture (4.2 `/scaffold`, 4.3 enforcement, 4.4 fixtures), §8 the scope boundary.
- **Plan 1:** `docs/superpowers/plans/2026-06-18-payment-contract-tester-plan1-foundation.md`
  — its "Carry-forward to Plan 2" section is authoritative for the runner-hardening work below.
- **Knowledge base (the invariant vocabulary all tasks share):**
  `plugins/payment-contract-tester/skills/payment-contract-tester/` — `SKILL.md` +
  `references/{invariants,montonio,stripe,mollie}.md`. Seven invariant names:
  `idempotent-effects`, `webhook-authenticity`, `money-minor-units`, `terminal-state-ordering`,
  `reconciliation`, `reference-uniqueness`, `durability-before-ack`.
- **The pytest exemplar to mirror:** `plugins/payment-contract-tester/reference/pytest/`
  (`jwtmini.py`, `handler.py`, `test_contract.py`, `trap_01..10`, `run.sh`).

## Execution method (same as Plan 1)

Use `superpowers:writing-plans` to author each plan, then `superpowers:subagent-driven-development`
to execute (fresh implementer subagent per task → task review → whole-branch review →
`superpowers:finishing-a-development-branch`). Branch off `main` first (don't implement on `main`).
Skill scripts: `…/subagent-driven-development/scripts/{task-brief,review-package}`. Keep a ledger at
`$(git rev-parse --git-path sdd)/progress.md`. Commit trailer:
`Claude-Session: <session-url>`. Repo rule: bump version in BOTH plugin.json AND marketplace.json.

---

## Plan 2 — xUnit reference fixtures (.NET) + runner hardening

**Goal:** Mirror the pytest proof in xUnit so the plugin's acceptance criterion (green-vs-correct,
red-vs-each-trap) is proven for the .NET stack too, and harden both runners' trap-isolation check.

**Why .NET:** Varustame (the live-keys-gated target repo) is .NET 9 / ASP.NET Core, xUnit +
`WebApplicationFactory`. See spec §3.5 for its real seams (`MontonioPaymentService.cs`,
`DecodeOrderToken`, route `api/public/annetused/montonio-webhook`, money `long SummaSentides`).

**Deliverables:**
- `plugins/payment-contract-tester/reference/xunit/` — a self-contained .NET test project mirroring
  the pytest fixture: a correct mock handler (HS256 JWT via `System.IdentityModel.Tokens.Jwt` or a
  stdlib-equivalent; **no third-party gateway SDK**), a contract test class with the same 10 test
  intents, and the same 10 one-edit trap variants selected at run time (e.g. via an env var the
  test reads to pick the handler-under-test, mirroring `PCT_HANDLER`). Plus `run.sh` using
  `dotnet test --filter …`.
- Extend `tests/run-tests.sh` to call `reference/xunit/run.sh` (the commented placeholder is already
  there) — must skip cleanly if `dotnet` is absent (no false green), exactly like the pytest guard.
- **Runner hardening (carry-forward from Plan 1 final review — apply to BOTH stacks):** today
  `run.sh` only asserts each trap reddens its *mapped* test. Add: non-foundational traps (03–10)
  must additionally leave the *other* tests GREEN (so a trap that reddens its target for an
  unrelated reason is caught). **Exempt the foundational claim traps** `trap_01_claim_shape` and
  `trap_02_missing_claim_guard` with a comment — a broken claim shape is inherently caught across
  the whole suite, and there is NO clean single-test isolation for it (verified: moving the break to
  the receiver side does not isolate it either, because every webhook-processing test needs a
  well-formed claim).

**The 10 trap → invariant mapping (keep identical across stacks):**
`trap_01` claim-shape (camelCase→snake_case key) · `trap_02` missing-required-claim guard removed ·
`trap_03` reference-reuse guard removed · `trap_04` float money (not integer-cents string) ·
`trap_05` no webhook dedupe · `trap_06` skip signature verification · `trap_07` trust body status
not verified-token status · `trap_08` no recency/tolerance window · `trap_09` terminal-state
downgrade allowed · `trap_10` concurrency race (remove lock + widen window).

**Watch:** .NET money is `long` cents → decimal `grandTotal` only at the JWT boundary; the
money trap is "use float/double" or culture-sensitive `ToString()` emitting `25,00`. The
concurrency trap needs a real race (the pytest version uses 8 threads + a 1ms sleep; in C# use
`Parallel.For`/tasks + a barrier).

**Out of scope for Plan 2:** `/scaffold`, CI/hook harness, gateways beyond the three.

---

## Plan 3 — `/scaffold` generator + CI/hook enforcement harness

**Goal:** A `/payment-contract-tester:scaffold` command that detects a target repo's stack + gateway,
drafts repo-adapted contract tests using the skill knowledge + the reference fixtures as few-shot
exemplars, **self-verifies** the drafts, and wires enforcement. See spec §4.2 (generator flow) and
§4.3 (enforcement) — implement them as written; they already incorporate the codex-review fixes.

**Deliverables:**
- `commands/scaffold.md` — the generator, documented as instructions for Claude (not a rigid
  script). Flow (spec §4.2): detect stack (xUnit/pytest are first-class; others → "no first-class
  support yet"); detect gateway(s) by grep heuristic as a **user-confirmed proposal**; locate seams
  (webhook entry, money field, existing tests to imitate-not-duplicate) and **report a needed seam**
  rather than emit a superficial test if none exists; draft tests (prefer official SDK helpers, e.g.
  Stripe `construct_event`; respect verified/unverified tags — comment uncertain ones
  `TODO-verify-against-sandbox`); **self-verify** (green on current source, red on a deliberately
  broken handler copy — a test that can't go red is rejected); wire enforcement; report.
- `harness/ci/` — GitHub Actions + GitLab CI snippets (the **authoritative** gate: versioned,
  team-propagated, present in CI, not `--no-verify`-bypassable). Run the generated payment-test
  subset on push/PR.
- `harness/pre-push.sh` + `harness/README.md` — the **optional** local fast-feedback hook
  (pre-push, not pre-commit — runners too slow per-commit). MUST: detect existing hook managers
  (Husky / lefthook / pre-commit framework / `core.hooksPath`) and emit the integration for that
  manager instead of clobbering `.git/hooks/pre-push`; if installing directly, use a clearly-
  delimited managed block, preserve the executable bit, support clean removal; if anything is
  ambiguous, print instructions instead of modifying. `--no-verify` is the documented escape hatch;
  the hook is explicitly NOT the security boundary.
- Update README to document `/scaffold` and the harness (remove the "arrives in a later version"
  qualifiers; also clean up the SKILL.md/invariants.md present-tense forward-references noted in the
  Plan 1 carry-forward).

**Critical framing (do not regress — from the codex review of the spec):**
- Enforcement = **CI is authoritative**, local hook is convenience. Never claim "automatic
  correctness" from a local hook alone.
- Webhook authenticity is **per-gateway**: signed-payload-authoritative for Stripe/Montonio;
  re-fetch from `GET /v2/payments/{id}` forced for Mollie (legacy webhooks are unsigned). NOT
  universal re-fetch.
- `reconciliation` is **skill-knowledge only** — `/scaffold` does NOT auto-generate reconciliation
  tests (needs a job + alerting; can't be generically contract-tested). Documented manual shape
  only.
- Generated tests need a human skim — the self-verify step + the `TODO-verify` flags + the
  generation report are the honesty mechanisms; say so in the report, don't overclaim.

**Out of scope (v0.1.x, spec §8):** standalone static scanner; live-sandbox tests; JS/other stacks
as first-class *fixtures*; multi-tenant / Stripe Connect / multiple-webhook-secret / Mollie-profile
edge cases; gateways beyond Montonio/Stripe/Mollie.

---

## Decisions already made (don't relitigate)

- **trap_01 breadth:** accepted as-is for Plan 1; the runner-isolation refinement is deferred to
  Plan 2 (above). Rationale: claim-shape is foundational; spec §4.4 allows "test(s)" (plural).
- **Delivery model:** research-grounded skill + `/scaffold` *generator* (not static copy-paste
  templates) + auto-wired enforcement. This was the user's explicit steer.
- **Gateways:** Montonio + Stripe + Mollie, all three.
- **Process Q&A style:** the user prefers conversational prose + sensible defaults over
  AskUserQuestion option cards during design.

## Target-repo grounding (for realistic exemplars / scaffold testing)

- **Varustame** `/mnt/data/ai/varustame.ee/` — .NET 9, xUnit, Montonio + Mollie, money
  `long SummaSentides`. Already has `MontonioPaymentServiceTests.cs` (don't duplicate; imitate).
- **Aruannik** `/mnt/data/ai/est-biz-aruannik/` — Python/FastAPI, pytest, Montonio + Stripe, money
  `amount_cents`, file-JSON store, `threading.Lock` dedupe. Already has `test_montonio_webhook.py`
  (incl. a `threading.Barrier` race test). Target `backend/`, ignore `worktrees/`.
