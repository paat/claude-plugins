# payment-contract-tester — Handoff for Plan 3 (`/scaffold` + CI/hook harness)

> **Purpose:** Everything a fresh session needs to write and execute **Plan 3** (the
> `/payment-contract-tester:scaffold` generator + CI/hook enforcement harness) without re-deriving
> the research, architecture, or what Plans 1–2 already shipped. Read this first, then the spec.

## Status (as of 2026-06-18)

- **Plans 1 and 2 are SHIPPED to `main`** (Plan 2 merge commit `3658022`, pushed to origin). Issue #53.
- Plugin lives at `plugins/payment-contract-tester/`, version **0.1.1** (synced in
  `.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json`).
- **Self-test is green on both stacks:** `bash plugins/payment-contract-tester/tests/run-tests.sh`
  → `ALL SELF-TESTS PASSED`, exit 0 (pytest always runs; xunit runs if a .NET SDK is present, else
  SKIPs cleanly — no false green).

### What already exists (Plan 3 builds on this, does NOT rebuild it)

- **Skill knowledge base** — `plugins/payment-contract-tester/skills/payment-contract-tester/`:
  `SKILL.md` + `references/{invariants,montonio,stripe,mollie}.md`. Seven invariant names:
  `idempotent-effects`, `webhook-authenticity`, `money-minor-units`, `terminal-state-ordering`,
  `reconciliation`, `reference-uniqueness`, `durability-before-ack`. Every concrete claim carries a
  VERIFIED / PARTIALLY VERIFIED / UNVERIFIED tag with a primary-source URL + retrieval date.
- **Two golden reference fixtures** (the `/scaffold` few-shot exemplars + the AC proof):
  - `reference/pytest/` — `jwtmini.py`, `handler.py` (correct), `trap_01..10`, `test_contract.py`, `run.sh`.
  - `reference/xunit/` — `JwtMini.cs`, `Interfaces.cs` (`IPaymentHandler`/`IStore`), `CorrectHandler.cs`,
    `HandlerFactory.cs` (env-selected handler via `PCT_HANDLER`), `ContractTests.cs`, `Traps/Trap01..10`, `run.sh`.
  - Both stacks mirror each other line-for-line: a correct mock webhook handler + 10 one-edit seeded
    traps, handler-under-test selected at runtime by the `PCT_HANDLER` env var.
- **Self-test orchestrator** — `tests/run-tests.sh` runs both `run.sh` scripts and asserts, per stack:
  correct handler all-green; each trap reddens its **mapped** test; and (for non-foundational traps)
  leaves the **other** tests green, minus a documented per-trap also-red allowlist.

### The 10 trap → invariant mapping (identical across both stacks — reuse verbatim in scaffold docs)

`trap_01` claim-shape (camelCase→snake_case key) · `trap_02` missing-required-claim guard removed ·
`trap_03` reference-reuse guard removed · `trap_04` float money (not integer-cents string) ·
`trap_05` no webhook dedupe · `trap_06` skip signature verification · `trap_07` trust body status
not verified-token status · `trap_08` no recency/tolerance window · `trap_09` terminal-state
downgrade allowed · `trap_10` concurrency race (remove lock + widen window).

The required-claim guard validates **merchantReference + paymentStatus + uuid** (all three → 400);
status is always taken from the **verified token**, never the request body.

## Canonical source documents (read these)

- **Design spec:** `docs/superpowers/specs/2026-06-18-payment-contract-tester-design.md`
  — **§4.2** `/scaffold` generator flow (7 steps), **§4.3** enforcement (CI authoritative + optional
  hook), **§3.1–3.4** gateway specifics, **§8** scope boundary. Implement §4.2/§4.3 as written —
  they already incorporate the codex-review fixes.
- **The original Plans 2&3 handoff:** `docs/superpowers/plans/2026-06-18-payment-contract-tester-HANDOFF-plans-2-3.md`
  — its "Plan 3" section is the source of the deliverables below; this doc refines it post-Plan-2.
- **Plan 2 plan (as an execution-style exemplar):**
  `docs/superpowers/plans/2026-06-18-payment-contract-tester-plan2-xunit.md`.
- **The reference fixtures themselves** (see paths above) — the scaffold's few-shot exemplars.

## Execution method (same as Plans 1 & 2)

Use `superpowers:writing-plans` to author the plan, then `superpowers:subagent-driven-development`
to execute (fresh implementer subagent per task → review → whole-branch review →
`superpowers:finishing-a-development-branch`). **Branch off `main` first** (don't implement on `main`).
Skill scripts: `…/subagent-driven-development/scripts/{task-brief,review-package}`. Keep a ledger at
`$(git rev-parse --git-path sdd)/progress.md` (it currently holds the Plan 2 ledger — start a fresh
Plan 3 section). Commit trailer: `Claude-Session: <session-url>`. Repo rule: bump version in BOTH
`plugin.json` AND `marketplace.json` (recommend **0.1.1 → 0.2.0** — `/scaffold` is the headline feature).

**Review with codex** (the user's established preference this project). In this container `codex review`
fails on bwrap — pipe the diff on stdin instead:
`{ echo "<review instructions>"; cat <diff-file>; } | codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check - 2>/dev/null`.
Generate the diff with the skill's `scripts/review-package BASE HEAD`.

**Environment note:** there is no system `dotnet`; provision the .NET 9 SDK once (no sudo) when a task
needs to actually run xUnit-related verification:
`curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 9.0 --install-dir "$HOME/.dotnet"`
then `export PATH="$HOME/.dotnet:$PATH"`. The runners SKIP cleanly without it (by design). Most of
Plan 3 is markdown + bash, so dotnet is only needed if a task self-verifies generated xUnit output.

---

## Plan 3 — `/scaffold` generator + CI/hook enforcement harness

**Goal:** A `/payment-contract-tester:scaffold` command that detects a target repo's stack + gateway,
drafts repo-adapted contract tests using the skill knowledge + the reference fixtures as few-shot
exemplars, **self-verifies** the drafts, and wires enforcement. Implement spec §4.2 (generator flow)
and §4.3 (enforcement) as written.

**Deliverables:**

- `commands/scaffold.md` — the generator, documented as **instructions for Claude** (not a rigid
  script). Flow (spec §4.2):
  1. **Detect stack** — `*.csproj`+xunit → xUnit; `pyproject.toml`/`requirements.txt`+`pytest.ini` →
     pytest. These two are first-class (golden fixtures back them). Other stacks (JS, etc.) → report
     "no first-class support yet" rather than emit an unbacked low-quality path.
  2. **Detect gateway(s)** by grep heuristic (Montonio: `stargate`, `merchantReference`; Stripe:
     `stripe`, `whsec_`, `construct_event`; Mollie: `mollie`, `X-Mollie-Signature`, `tr_`) — present
     as a **user-confirmed proposal**, not an automatic decision (grep is brittle).
  3. **Locate seams** — webhook entry point(s), order-creation, money field/type, existing payment
     tests (to imitate, not duplicate), the test-invocation pattern (factory / TestClient / DI fake).
     If no testable seam exists, **report the seam the repo needs** instead of emitting a superficial test.
  4. **Draft contract tests** — for each confirmed gateway, emit tests for the applicable invariants
     using the skill's GREEN/RED shapes, adapted to the repo's idioms + discovered seam. Use
     `reference/<stack>/` as the few-shot exemplar. Prefer the gateway's **official SDK helpers**
     (e.g. Stripe `construct_event`) over hand-rolled HMAC unless the repo verifies manually. Respect
     verified/unverified tags — comment uncertain assertions `TODO-verify-against-sandbox`.
  5. **Self-verify the drafts** — run them against current source (expect green) and against a
     deliberately-broken copy of the handler (expect red). Report any test that doesn't move — a test
     that can't go red is rejected. This is the honesty check on generation quality.
  6. **Wire enforcement** — write a **CI snippet** (authoritative gate) + offer to install the
     **optional local pre-push hook** (convenience).
  7. **Report** — generated files, the CI snippet added, whether the hook was installed, every
     `TODO-verify` assertion, and any seam the repo still needs.

  The command **never edits payment source** — it writes tests, the CI snippet, and (optionally) the hook.

- `harness/ci/` — GitHub Actions + GitLab CI snippets (the **authoritative** gate: versioned,
  team-propagated, present in CI, not `--no-verify`-bypassable). Run the generated payment-test
  subset on push/PR; adapt the runner command (`dotnet test --filter …` / `pytest -k …`) to the repo.

- `harness/pre-push.sh` + `harness/README.md` — the **optional** local fast-feedback hook (pre-push,
  not pre-commit — runners too slow per-commit). MUST: detect existing hook managers (Husky /
  lefthook / pre-commit framework / `core.hooksPath`) and emit the integration for that manager
  instead of clobbering `.git/hooks/pre-push`; if installing directly, use a clearly-delimited managed
  block, preserve the executable bit, support clean removal; if anything is ambiguous, print
  instructions instead of modifying. `--no-verify` is the documented escape hatch; the hook is
  explicitly NOT the security boundary.

- **Update README** — document `/scaffold` and the harness; remove the "arrives in a later version"
  qualifier (README.md line ~20). Also clean up the SKILL.md / invariants.md present-tense
  forward-references to scaffold/harness noted in the Plan 1 carry-forward (they currently describe
  not-yet-shipped features in present tense).

**Critical framing (do not regress — from the codex review of the spec):**
- Enforcement = **CI is authoritative**, local hook is convenience. Never claim "automatic
  correctness" from a local hook alone.
- Webhook authenticity is **per-gateway**: signed-payload-authoritative for Stripe/Montonio;
  re-fetch from `GET /v2/payments/{id}` forced for Mollie (legacy webhooks are unsigned). NOT universal re-fetch.
- `reconciliation` is **skill-knowledge only** — `/scaffold` does NOT auto-generate reconciliation
  tests (needs a job + alerting; can't be generically contract-tested). Documented manual shape only.
- Generated tests need a human skim — the self-verify step + the `TODO-verify` flags + the generation
  report are the honesty mechanisms. Say so in the report; don't overclaim.

**Out of scope (v0.x, spec §8):** standalone static scanner; live-sandbox tests; JS/other stacks as
first-class *fixtures*; multi-tenant / Stripe Connect / multiple-webhook-secret / Mollie-profile edge
cases; gateways beyond Montonio/Stripe/Mollie.

---

## Decisions already made (don't relitigate)

- **Delivery model:** research-grounded skill + `/scaffold` *generator* (not static copy-paste
  templates) + auto-wired enforcement. The user's explicit steer.
- **Gateways:** Montonio + Stripe + Mollie, all three.
- **Trap-isolation hardening (settled in Plan 2):** non-foundational traps must redden their mapped
  test AND leave the others green (per-trap also-red allowlist). **Only `trap_01` is exempt** —
  live-verified that it cross-reddens 5/10 tests with no clean isolation, whereas `trap_02` isolates
  to 1 test and IS checked. `trap_05`'s allowlist is the concurrency test. If `/scaffold`-generated
  suites grow a similar self-test, mirror this contract.
- **Process Q&A style:** the user prefers conversational prose + sensible defaults over
  AskUserQuestion option cards during *design/brainstorming* (option cards are fine for crisp
  execution-time decisions).
- **Reviews via codex** (see Execution method).

## Target-repo grounding (for realistic exemplars / scaffold testing)

- **Varustame** `/mnt/data/ai/varustame.ee/` — .NET 9, xUnit + `WebApplicationFactory`. Money
  `long SummaSentides` (cents). Montonio (`MontonioPaymentService.cs`, `DecodeOrderToken`, route
  `api/public/annetused/montonio-webhook`) **and** Mollie recurring rail. Already has a thorough
  `MontonioPaymentServiceTests.cs` + clean DI seams (`DelegatingTestHandler`, `VarustameApiFactory`,
  `WithFakeMontonio()`). **Imitate these seams; do not duplicate the existing suite.**
- **Aruannik** `/mnt/data/ai/est-biz-aruannik/` — Python/FastAPI, pytest. Money `amount_cents`.
  Montonio **and** Stripe rails; file-JSON store; `threading.Lock` dedupe; already has
  `test_montonio_webhook.py` (incl. a `threading.Barrier` race test). Seam: `TestClient(app)` +
  `monkeypatch` of module-level secrets/dirs. Target `backend/`, ignore `worktrees/`.
- **Implication:** both targets already have strong suites → the generator must imitate existing
  seams and **not duplicate**; these suites are the few-shot exemplars, not the target.

## Lessons from Plans 1–2 execution (save yourself the rediscovery)

- The xUnit fixture's runtime handler-selection pattern (env var → `HandlerFactory.FromEnv()` →
  `IPaymentHandler`) and the BCL-only `JwtMini` are good models for what "adapted to the repo's
  idioms" means when scaffolding xUnit tests — but the **scaffold targets the repo's real seams**
  (DI fakes, `WebApplicationFactory`), not this fixture's mock-handler shape.
- `dotnet test --filter "FullyQualifiedName~Name"` (and `!~` for exclusion, `&`-combined) is how the
  xUnit runner selects/excludes individual tests — reuse this for the CI/hook "payment-test subset"
  command on xUnit repos. pytest uses `-k "expr"`.
- Keep generated/self-test temp files namespaced (`mktemp`), and make any SKIP guard require the
  actual toolchain (e.g. `dotnet --list-sdks` non-empty, not just `command -v dotnet`) — both were
  Plan 2 review findings worth not repeating.
