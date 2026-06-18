# payment-contract-tester — Plan 1: Foundation + Skill + Python Proof

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an installable `payment-contract-tester` plugin whose skill encodes research-grounded payment-hardening knowledge (Montonio/Stripe/Mollie) and whose pytest reference fixtures prove the contract-test patterns run GREEN against a correct mock handler and RED against each seeded trap.

**Architecture:** A standard Claude Code plugin under `plugins/payment-contract-tester/`. This plan delivers everything except the xUnit fixtures (Plan 2) and the `/scaffold` generator + CI/hook harness (Plan 3). The Python reference fixture is a self-contained mock payment handler (stdlib-only HS256 JWT, in-memory store) plus a parametrized contract-test suite; a bash orchestrator runs the suite against the correct handler (expect all-green) and against each trap module (expect the specific test to go red).

**Tech Stack:** Markdown (skill/commands/docs), Python 3 + pytest (reference fixtures, stdlib `hmac`/`hashlib`/`base64`/`json` — no third-party JWT dep), bash 4+ (self-test orchestrator).

## Global Constraints

- Generic & project-agnostic: no hardcoded company/product/project names or paths anywhere in plugin files. (Repo CLAUDE.md)
- Project-specific values use template variables, not hardcoded strings. (Repo CLAUDE.md)
- Plugins work with bash 4+ and standard POSIX tools. (Repo CLAUDE.md)
- External dependencies (here: `python3`, `pytest`) documented in README. (Repo CLAUDE.md)
- Plugin version `0.1.0` set in BOTH `plugins/payment-contract-tester/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json` — kept in sync. (Repo CLAUDE.md)
- README MUST include an Installation section with the three scopes: **user** (Install for you), **project** (Install for all collaborators on this repository), **local** (Install for you, in this repo only). (Repo CLAUDE.md)
- Every gateway claim in `skills/.../references/*.md` carries a VERIFIED / PARTIALLY VERIFIED / UNVERIFIED tag with a primary-source URL and retrieval date `2026-06-18`. Never emit a corrected-away literal (e.g. Montonio `409 ALREADY_PAID_FOR`, `EXPIRED`/`FAILED` statuses, Mollie legacy webhook signature).
- Plugin reports findings / generates tests only; it never edits payment source code.

---

### Task 1: Plugin packaging

**Files:**
- Create: `plugins/payment-contract-tester/.claude-plugin/plugin.json`
- Create: `plugins/payment-contract-tester/LICENSE`
- Modify: `.claude-plugin/marketplace.json` (add plugin entry to the `plugins` array)

**Interfaces:**
- Produces: the plugin manifest at name `payment-contract-tester`, version `0.1.0`, that later tasks add components under.

- [ ] **Step 1: Create the plugin manifest**

Create `plugins/payment-contract-tester/.claude-plugin/plugin.json`:

```json
{
  "name": "payment-contract-tester",
  "version": "0.1.0",
  "description": "Research-grounded payment-integration hardening — a skill encoding Montonio/Stripe/Mollie silent-trap knowledge plus runnable contract-test reference fixtures (webhook idempotency, signature/authenticity, money-as-integer, terminal-state, replay) that run green against a correct handler and red against each seeded trap",
  "author": {
    "name": "Andre Paat"
  },
  "repository": "https://github.com/paat/claude-plugins",
  "license": "MIT",
  "keywords": ["payment", "contract-test", "webhook-idempotency", "signature-verification", "montonio", "stripe", "mollie", "silent-failure", "money-as-cents", "estonian-saas"]
}
```

- [ ] **Step 2: Add the LICENSE file**

Copy the repo's existing MIT license text into `plugins/payment-contract-tester/LICENSE` (match an existing plugin's LICENSE verbatim, e.g. `plugins/silent-failure-scanner/LICENSE`).

Run: `cp plugins/silent-failure-scanner/LICENSE plugins/payment-contract-tester/LICENSE`

- [ ] **Step 3: Register the plugin in the marketplace**

Add this object to the `plugins` array in `.claude-plugin/marketplace.json` (after the last existing entry):

```json
{
  "name": "payment-contract-tester",
  "description": "Research-grounded payment-integration hardening — a skill encoding Montonio/Stripe/Mollie silent-trap knowledge plus runnable contract-test reference fixtures that run green against a correct handler and red against each seeded trap",
  "version": "0.1.0",
  "author": {
    "name": "Andre Paat"
  },
  "source": "./plugins/payment-contract-tester",
  "category": "testing",
  "homepage": "https://github.com/paat/claude-plugins"
}
```

- [ ] **Step 4: Verify both JSON files parse and versions match**

Run: `jq -e '.version' plugins/payment-contract-tester/.claude-plugin/plugin.json && jq -e '.plugins[] | select(.name=="payment-contract-tester") | .version' .claude-plugin/marketplace.json`
Expected: prints `"0.1.0"` twice (both files valid JSON, versions in sync).

- [ ] **Step 5: Commit**

```bash
git add plugins/payment-contract-tester/.claude-plugin/plugin.json plugins/payment-contract-tester/LICENSE .claude-plugin/marketplace.json
git commit -m "feat(payment-contract-tester): scaffold plugin manifest at v0.1.0"
```

---

### Task 2: README with Installation section

**Files:**
- Create: `plugins/payment-contract-tester/README.md`

**Interfaces:**
- Consumes: plugin name `payment-contract-tester` from Task 1.

- [ ] **Step 1: Write the README**

Create `plugins/payment-contract-tester/README.md`. It MUST contain (in order): a one-paragraph summary, the **Installation** section with the three scopes verbatim, a "What it provides" section (skill + reference fixtures; note `/scaffold` and CI/hook harness arrive in a later version), a "Dependencies" section (`python3`, `pytest` for running the reference fixtures; `bash 4+`), and a "Verified-vs-unverified policy" note. Use this exact Installation block:

```markdown
## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install payment-contract-tester@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this repository, via `.claude/settings.local.json`.
```

Keep the rest concise; do not document `/scaffold` behavior yet (Plan 3).

- [ ] **Step 2: Verify the three scopes are present**

Run: `grep -c -E 'user scope|project scope|local scope' plugins/payment-contract-tester/README.md`
Expected: `3`

- [ ] **Step 3: Commit**

```bash
git add plugins/payment-contract-tester/README.md
git commit -m "docs(payment-contract-tester): README with three-scope install section"
```

---

### Task 3: Skill + reference knowledge base

**Files:**
- Create: `plugins/payment-contract-tester/skills/payment-contract-tester/SKILL.md`
- Create: `plugins/payment-contract-tester/skills/payment-contract-tester/references/invariants.md`
- Create: `plugins/payment-contract-tester/skills/payment-contract-tester/references/montonio.md`
- Create: `plugins/payment-contract-tester/skills/payment-contract-tester/references/stripe.md`
- Create: `plugins/payment-contract-tester/skills/payment-contract-tester/references/mollie.md`

**Interfaces:**
- Produces: the invariant catalogue the pytest fixtures (Task 4) and the future `/scaffold` (Plan 3) mirror. Invariant names used as the shared vocabulary: `idempotent-effects`, `webhook-authenticity`, `money-minor-units`, `terminal-state-ordering`, `reconciliation`, `reference-uniqueness`, `durability-before-ack`.

> **Source material:** the four research reports in the design spec (`docs/superpowers/specs/2026-06-18-payment-contract-tester-design.md`, §3) are the authoritative content. Transcribe their findings into these files with the structure below. Do NOT summarize away the verified/unverified tags or the corrected Montonio literals.

- [ ] **Step 1: Write SKILL.md**

Frontmatter `name: payment-contract-tester` and a `description` triggering on payment/webhook/contract-test/idempotency/signature-verification/"double charge"/"silent webhook failure" contexts. Body sections: (1) what this skill is for; (2) the seven invariants as a one-line index linking to `references/invariants.md`; (3) per-gateway pointers to `references/{montonio,stripe,mollie}.md`; (4) "How to write a payment contract test" — the GREEN/RED method; (5) the verified/unverified policy (only assert documented behavior; comment uncertain assertions `TODO-verify-against-sandbox`). Keep SKILL.md under ~150 lines; detail lives in references (progressive disclosure).

- [ ] **Step 2: Write references/invariants.md**

One entry per invariant. Use this exact four-field template (worked example for invariant 1 shown in full — write all seven the same way, drawing facts from spec §3.1):

```markdown
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
```

Remaining invariants to write (same template, facts from spec §3.1): `webhook-authenticity`
(per-gateway: signed-payload-authoritative for Stripe/Montonio, re-fetch forced for Mollie — NOT
universal re-fetch), `money-minor-units` (integer minor units / decimal; zero-decimal currency
caveat; cents↔decimal boundary), `terminal-state-ordering` (delivery order not guaranteed; no
downgrade of a terminal status; persist a distinct terminal failure), `reconciliation` (gateway is
source of truth; delivery can be permanently exhausted — **mark this skill-knowledge-only**, with a
documented manual test shape, not auto-generated), `reference-uniqueness` (stable per intent, unique
across intents; **include the Montonio PENDING-retry exception: reuse the same reference when
retrying a still-PENDING order**), `durability-before-ack` (persist before returning 2xx).

- [ ] **Step 3: Write references/montonio.md**

A verified/unverified table plus the hardening entries, from spec §3.2. The table MUST record these
CORRECTIONS as their tagged status (with URL + retrieval date 2026-06-18):

```markdown
| Claim | Status | Note |
|---|---|---|
| Stargate JWT HS256, `POST /orders` body `{"data":"<jwt>"}` | VERIFIED | docs.montonio.com/api/stargate/reference |
| camelCase claims (`merchantReference`, `grandTotal`, …) | VERIFIED | docs.montonio.com/api/stargate/guides/orders |
| `grandTotal` decimal at JSON level | VERIFIED | same |
| `iat` independently required | UNVERIFIED | only `exp` is doc-required; treat `iat` as defensive |
| `409 ALREADY_PAID_FOR` literal | UNVERIFIED | docs show `Order_already_paid_for`; do NOT assert 409/ALREADY_PAID_FOR |
| `EXPIRED` / `FAILED` statuses | UNVERIFIED | real drop status is `ABANDONED`; statuses: PENDING/AUTHORIZED/PAID/ABANDONED/PARTIALLY_REFUNDED/REFUNDED/VOIDED |
| reuse merchantReference on PENDING retry | VERIFIED | help.montonio.com PENDING handling — uniqueness only for fresh orders |
| webhook is source of truth, retried 13×/48h | VERIFIED | help.montonio.com webhook notifications |
| localhost notificationUrl rejected at create | UNVERIFIED | only reachability guidance confirmed |
```

Then 2–3 hardening entries (amount boundary, JWT claim completeness, webhook verify, merchantRef +
PENDING nuance, status-transition guard) using the invariants template.

- [ ] **Step 4: Write references/stripe.md**

From spec §3.4: `Stripe-Signature` (`t=`/`v1=`), HMAC-SHA256 over `t.body`, default tolerance 300s
(never 0), constant-time compare, raw bytes; Idempotency-Key 24h + params-mismatch error; event
dedupe by `event.id`; amounts integer minor units + zero-decimal caveat; ordering not guaranteed →
re-fetch; testing via Stripe CLI `trigger`/`listen` + test clocks. Prefer official SDK
`construct_event`; assert raw-body preservation. Tag each VERIFIED with a docs.stripe.com URL +
2026-06-18. Mark the stripe-mock maintenance status UNVERIFIED.

- [ ] **Step 5: Write references/mollie.md**

From spec §3.3, emphasizing the DIFFERENT model: webhook body is id-only (`id=tr_…`) → re-fetch
`GET /v2/payments/{id}`; legacy webhooks UNSIGNED (security = unguessable id + authenticated
re-fetch), next-gen `X-Mollie-Signature` HMAC-SHA256 (tag UNVERIFIED-as-MUST, keep out of generated
assertions); amount object `{"currency":"EUR","value":"10.00"}` decimal string; Idempotency-Key 1h;
refunds/chargebacks fire the same payment webhook, status stays `paid`, reconcile via
`amountRefunded`/`amountChargedBack`; `authorized` ≠ collected; recurring needs a `valid` mandate +
`customerId`. Tag with docs.mollie.com URLs + 2026-06-18.

- [ ] **Step 6: Verify structure**

Run: `ls plugins/payment-contract-tester/skills/payment-contract-tester/references/ && grep -L 'VERIFIED' plugins/payment-contract-tester/skills/payment-contract-tester/references/{montonio,stripe,mollie}.md`
Expected: lists `invariants.md montonio.md stripe.md mollie.md`; the `grep -L` prints nothing (every gateway file contains verification tags).

- [ ] **Step 7: Verify no corrected-away literals leaked as assertions**

Run: `! grep -rn 'ALREADY_PAID_FOR' plugins/payment-contract-tester/skills/ | grep -v 'do NOT\|UNVERIFIED'`
Expected: exit 0 (the literal appears only in the "do NOT assert" / UNVERIFIED context, never as a recommended assertion).

- [ ] **Step 8: Commit**

```bash
git add plugins/payment-contract-tester/skills/
git commit -m "feat(payment-contract-tester): skill + Montonio/Stripe/Mollie reference knowledge base"
```

---

### Task 4: pytest reference fixture — correct handler + contract suite (GREEN)

**Files:**
- Create: `plugins/payment-contract-tester/reference/pytest/jwtmini.py`
- Create: `plugins/payment-contract-tester/reference/pytest/handler.py`
- Create: `plugins/payment-contract-tester/reference/pytest/test_contract.py`

**Interfaces:**
- Produces (handler API consumed by the test suite AND copied by every trap in Task 5):
  - `SECRET: bytes`, `TOLERANCE: int`, `TERMINAL: set[str]`
  - `class Store` with `orders: dict`, `processed: set`, `effects: list`, methods `create_order(ref, amount_cents)` and `paid_count(ref) -> int`
  - `build_grand_total(amount_cents: int) -> str`
  - `make_webhook_token(uuid, ref, status, amount_cents, *, secret=SECRET, now=1_700_000_000, iat=True) -> str`
  - `handle_webhook(store, raw_body: str, *, now: int) -> int` (HTTP-style status code)
- The test suite selects the handler module via env var `PCT_HANDLER` (default `handler`).

- [ ] **Step 1: Write the stdlib JWT helper**

Create `reference/pytest/jwtmini.py`:

```python
"""Minimal HS256 JWT encode/verify using only the standard library."""
import base64
import hashlib
import hmac
import json


def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _b64u_dec(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def encode(claims: dict, secret: bytes) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    seg = _b64u(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        _b64u(json.dumps(claims, separators=(",", ":")).encode())
    sig = hmac.new(secret, seg.encode(), hashlib.sha256).digest()
    return seg + "." + _b64u(sig)


def decode(token: str, secret: bytes) -> dict:
    """Verify the HS256 signature (constant-time) and return the claims."""
    seg, _, sig_b64 = token.rpartition(".")
    if not seg or not sig_b64:
        raise ValueError("malformed token")
    expected = hmac.new(secret, seg.encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(expected, _b64u_dec(sig_b64)):
        raise ValueError("bad signature")
    _, _, payload_b64 = seg.partition(".")
    return json.loads(_b64u_dec(payload_b64))


def decode_unsafe(token: str) -> dict:
    """Parse claims WITHOUT verifying the signature. Used only by a seeded trap."""
    seg, _, _ = token.rpartition(".")
    _, _, payload_b64 = seg.partition(".")
    return json.loads(_b64u_dec(payload_b64))
```

- [ ] **Step 2: Write the correct handler**

Create `reference/pytest/handler.py`:

```python
"""Reference CORRECT mock payment-webhook handler (Montonio-style HS256 JWT).

Each seeded trap in ../pytest/trap_*.py is a one-edit copy of this file with a single
invariant broken. The contract suite asserts this version is all-green.
"""
import json
import threading

import jwtmini

SECRET = b"test-secret"
TOLERANCE = 300
TERMINAL = {"PAID", "ABANDONED", "REFUNDED"}


class Store:
    def __init__(self):
        self.orders = {}        # ref -> {"status": str, "amount_cents": int}
        self.processed = set()  # event uuids already applied (durable dedupe)
        self.effects = []       # list of (ref, status) actually applied
        self._lock = threading.Lock()

    def create_order(self, ref, amount_cents):
        if ref in self.orders:                       # reference-uniqueness (fresh order)
            raise ValueError("duplicate merchantReference: %s" % ref)
        self.orders[ref] = {"status": "PENDING", "amount_cents": amount_cents}

    def paid_count(self, ref):
        return sum(1 for r, st in self.effects if r == ref and st == "PAID")


def build_grand_total(amount_cents):                 # money-minor-units: no float
    return "%d.%02d" % (amount_cents // 100, amount_cents % 100)


def make_webhook_token(uuid, ref, status, amount_cents, *,
                       secret=SECRET, now=1_700_000_000, iat=True):
    claims = {
        "accessKey": "ak",
        "uuid": uuid,
        "merchantReference": ref,
        "paymentStatus": status,
        "grandTotal": build_grand_total(amount_cents),
        "currency": "EUR",
        "exp": now + 600,
    }
    if iat:
        claims["iat"] = now
    return jwtmini.encode(claims, secret)


def handle_webhook(store, raw_body, *, now):
    body = json.loads(raw_body)
    token = body.get("orderToken", "")
    try:
        claims = jwtmini.decode(token, SECRET)       # webhook-authenticity (constant-time)
    except ValueError:
        return 401
    iat = claims.get("iat")
    if iat is None or abs(now - iat) > TOLERANCE:    # replay / recency window
        return 401
    ref = claims.get("merchantReference")
    status = claims.get("paymentStatus")             # status from VERIFIED token, not body
    if not ref or not status:                        # required claim shape
        return 400
    order = store.orders.get(ref)
    if order is None:
        return 404
    uuid = claims["uuid"]
    with store._lock:                                # atomic, durable dedupe
        if uuid in store.processed:                  # idempotent-effects
            return 200
        if order["status"] in TERMINAL and status != order["status"]:
            store.processed.add(uuid)                # terminal-state-ordering: no downgrade
            return 200
        order["status"] = status                     # durability-before-ack: persist first
        store.effects.append((ref, status))
        store.processed.add(uuid)
    return 200
```

- [ ] **Step 3: Write the contract suite (the failing test, before any trap exists)**

Create `reference/pytest/test_contract.py`:

```python
import importlib
import os
import threading

import pytest

H = importlib.import_module(os.environ.get("PCT_HANDLER", "handler"))
NOW = 1_700_000_000


def fresh():
    s = H.Store()
    s.create_order("REF-1", 2500)
    return s


def _wh(tok):
    return '{"orderToken": "%s"}' % tok


def test_money_decimal_boundary_no_float():
    assert H.build_grand_total(2500) == "25.00"
    assert H.build_grand_total(7) == "0.07"
    assert H.build_grand_total(1999) == "19.99"


def test_paid_marks_order():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    assert H.handle_webhook(s, _wh(tok), now=NOW) == 200
    assert s.orders["REF-1"]["status"] == "PAID"


def test_required_claim_missing_rejected():
    claims = {"accessKey": "ak", "uuid": "e1", "paymentStatus": "PAID",
              "exp": NOW + 600, "iat": NOW}  # no merchantReference
    tok = jwtmini_encode(claims)
    s = fresh()
    assert H.handle_webhook(s, _wh(tok), now=NOW) == 400


def test_duplicate_reference_rejected():
    s = fresh()
    with pytest.raises(Exception):
        s.create_order("REF-1", 999)


def test_forged_signature_rejected():
    s = fresh()
    bad = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW, secret=b"wrong")
    assert H.handle_webhook(s, _wh(bad), now=NOW) == 401
    assert s.orders["REF-1"]["status"] == "PENDING"


def test_status_taken_from_token_not_body():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "ABANDONED", 2500, now=NOW)
    body = '{"orderToken": "%s", "paymentStatus": "PAID"}' % tok
    H.handle_webhook(s, body, now=NOW)
    assert s.orders["REF-1"]["status"] == "ABANDONED"  # body's PAID must be ignored


def test_stale_timestamp_rejected():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW - 10_000)
    assert H.handle_webhook(s, _wh(tok), now=NOW) == 401
    assert s.orders["REF-1"]["status"] == "PENDING"


def test_replayed_webhook_idempotent():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    H.handle_webhook(s, _wh(tok), now=NOW)
    H.handle_webhook(s, _wh(tok), now=NOW)  # replay (same uuid)
    assert s.paid_count("REF-1") == 1


def test_terminal_state_not_downgraded():
    s = fresh()
    paid = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    H.handle_webhook(s, _wh(paid), now=NOW)
    aband = H.make_webhook_token("e2", "REF-1", "ABANDONED", 2500, now=NOW)
    H.handle_webhook(s, _wh(aband), now=NOW)
    assert s.orders["REF-1"]["status"] == "PAID"


def test_concurrent_duplicate_applies_once():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    body = _wh(tok)
    barrier = threading.Barrier(8)

    def worker():
        barrier.wait()
        H.handle_webhook(s, body, now=NOW)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert s.paid_count("REF-1") == 1


def jwtmini_encode(claims):
    import jwtmini
    return jwtmini.encode(claims, H.SECRET)
```

- [ ] **Step 4: Run the suite against the correct handler**

Run: `cd plugins/payment-contract-tester/reference/pytest && PCT_HANDLER=handler python3 -m pytest -q`
Expected: `10 passed` (all GREEN against the correct handler).

- [ ] **Step 5: Commit**

```bash
git add plugins/payment-contract-tester/reference/pytest/jwtmini.py plugins/payment-contract-tester/reference/pytest/handler.py plugins/payment-contract-tester/reference/pytest/test_contract.py
git commit -m "feat(payment-contract-tester): pytest reference fixture — correct handler + contract suite (green)"
```

---

### Task 5: pytest seeded traps (10) + per-stack runner

**Files:**
- Create: `plugins/payment-contract-tester/reference/pytest/trap_01_claim_shape.py` … `trap_10_concurrency.py`
- Create: `plugins/payment-contract-tester/reference/pytest/run.sh`

**Interfaces:**
- Consumes: the handler API from Task 4 (each trap is a copy of `handler.py` with ONE edit).
- Produces: `run.sh` exit code 0 only when the correct handler is all-green AND every trap reddens exactly its mapped test.

Each trap is `handler.py` copied to the trap filename with the single edit below. The trap→test
mapping (used by `run.sh`):

| Trap file | Single edit vs handler.py | Test that must go RED |
|---|---|---|
| `trap_01_claim_shape.py` | in `make_webhook_token`, rename claim key `"merchantReference"` → `"merchant_reference"` | `test_paid_marks_order` |
| `trap_02_missing_claim_guard.py` | delete the `if not ref or not status: return 400` lines | `test_required_claim_missing_rejected` |
| `trap_03_reference_reuse.py` | in `Store.create_order`, delete the `if ref in self.orders: raise …` guard | `test_duplicate_reference_rejected` |
| `trap_04_float_money.py` | `build_grand_total` body → `return str(amount_cents / 100)` | `test_money_decimal_boundary_no_float` |
| `trap_05_no_dedupe.py` | delete the `if uuid in store.processed: return 200` lines | `test_replayed_webhook_idempotent` |
| `trap_06_skip_signature.py` | change `claims = jwtmini.decode(token, SECRET)` (in the try) → `claims = jwtmini.decode_unsafe(token)` | `test_forged_signature_rejected` |
| `trap_07_trust_body_status.py` | after computing `status`, insert `status = body.get("paymentStatus", status)` | `test_status_taken_from_token_not_body` |
| `trap_08_no_recency.py` | change the recency guard to `if iat is None:` (drop the `or abs(now - iat) > TOLERANCE`) | `test_stale_timestamp_rejected` |
| `trap_09_downgrade.py` | delete the `if order["status"] in TERMINAL and status != order["status"]:` block (its two-line body + guard) | `test_terminal_state_not_downgraded` |
| `trap_10_concurrency.py` | remove `with store._lock:` (de-indent its body) AND insert `import time; time.sleep(0.001)` between the `if uuid in store.processed` check and `order["status"] = status` | `test_concurrent_duplicate_applies_once` |

- [ ] **Step 1: Create trap_04 (float money) and verify it reddens its test**

Run: `cd plugins/payment-contract-tester/reference/pytest && cp handler.py trap_04_float_money.py`
Then edit `trap_04_float_money.py` so `build_grand_total` reads:

```python
def build_grand_total(amount_cents):
    return str(amount_cents / 100)   # SEEDED TRAP: float money
```

Run: `cd plugins/payment-contract-tester/reference/pytest && PCT_HANDLER=trap_04_float_money python3 -m pytest -q -k test_money_decimal_boundary_no_float`
Expected: `1 failed` (asserts `25.0 != 25.00`).

- [ ] **Step 2: Create the remaining nine traps**

For each row in the table above: `cp handler.py <trap_file>` then apply the single edit. Mark each edit with a `# SEEDED TRAP:` comment so reviewers can spot it.

- [ ] **Step 3: Spot-check three more traps redden their mapped test**

Run: `cd plugins/payment-contract-tester/reference/pytest && for t in trap_06_skip_signature:test_forged_signature_rejected trap_09_downgrade:test_terminal_state_not_downgraded trap_10_concurrency:test_concurrent_duplicate_applies_once; do mod=${t%%:*}; tst=${t##*:}; PCT_HANDLER=$mod python3 -m pytest -q -k $tst >/dev/null 2>&1 && echo "BUG: $mod stayed green" || echo "OK: $mod reddened $tst"; done`
Expected: three `OK:` lines, no `BUG:` line.

- [ ] **Step 4: Write run.sh (per-stack runner)**

Create `reference/pytest/run.sh`:

```bash
#!/usr/bin/env bash
# Runs the pytest reference suite: GREEN against the correct handler, then asserts each
# seeded trap reddens exactly its mapped test. Exit 0 only if all expectations hold.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v python3 >/dev/null || ! python3 -c 'import pytest' 2>/dev/null; then
  echo "SKIP: python3 + pytest not available"; exit 0
fi

fail=0

echo "== correct handler (expect all green) =="
if PCT_HANDLER=handler python3 -m pytest -q >/tmp/pct_green.log 2>&1; then
  echo "OK: correct handler all green"
else
  echo "FAIL: correct handler was not all green"; cat /tmp/pct_green.log; fail=1
fi

# trap_module : test_that_must_fail
traps="
trap_01_claim_shape:test_paid_marks_order
trap_02_missing_claim_guard:test_required_claim_missing_rejected
trap_03_reference_reuse:test_duplicate_reference_rejected
trap_04_float_money:test_money_decimal_boundary_no_float
trap_05_no_dedupe:test_replayed_webhook_idempotent
trap_06_skip_signature:test_forged_signature_rejected
trap_07_trust_body_status:test_status_taken_from_token_not_body
trap_08_no_recency:test_stale_timestamp_rejected
trap_09_downgrade:test_terminal_state_not_downgraded
trap_10_concurrency:test_concurrent_duplicate_applies_once
"

echo "== seeded traps (expect each to redden its mapped test) =="
for pair in $traps; do
  mod=${pair%%:*}; tst=${pair##*:}
  if PCT_HANDLER=$mod python3 -m pytest -q -k "$tst" >/dev/null 2>&1; then
    echo "FAIL: $mod stayed green for $tst"; fail=1
  else
    echo "OK: $mod reddened $tst"
  fi
done

exit $fail
```

Run: `chmod +x plugins/payment-contract-tester/reference/pytest/run.sh && plugins/payment-contract-tester/reference/pytest/run.sh`
Expected: `OK: correct handler all green`, ten `OK: trap_… reddened …` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/payment-contract-tester/reference/pytest/trap_*.py plugins/payment-contract-tester/reference/pytest/run.sh
git commit -m "feat(payment-contract-tester): 10 seeded pytest traps + per-stack runner (red proofs)"
```

---

### Task 6: Plugin self-test orchestrator

**Files:**
- Create: `plugins/payment-contract-tester/tests/run-tests.sh`

**Interfaces:**
- Consumes: `reference/pytest/run.sh` from Task 5.
- Produces: the plugin's top-level self-test (Plan 2 extends it to also call `reference/xunit/run.sh`).

- [ ] **Step 1: Write the orchestrator**

Create `tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# payment-contract-tester self-tests: prove the contract-test patterns run green against the
# correct handler and red against each seeded trap, per supported stack. Skips a stack whose
# runtime is absent (never a false green). Plan 2 adds the xunit stack here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

echo "### pytest reference fixtures ###"
bash "$ROOT/reference/pytest/run.sh" || rc=1

# Plan 2: bash "$ROOT/reference/xunit/run.sh" || rc=1

if [ "$rc" -eq 0 ]; then echo "ALL SELF-TESTS PASSED"; else echo "SELF-TESTS FAILED"; fi
exit $rc
```

- [ ] **Step 2: Run the full self-test**

Run: `chmod +x plugins/payment-contract-tester/tests/run-tests.sh && plugins/payment-contract-tester/tests/run-tests.sh`
Expected: pytest section all-OK, final line `ALL SELF-TESTS PASSED`, exit 0.

- [ ] **Step 3: Verify the skip path (no false green)**

Run: `PATH=/usr/bin python3 -c 'pass' 2>/dev/null; bash -c 'command -v python3 >/dev/null && echo "python3 present — skip-path not exercised here" || echo "would SKIP"'`
Expected: prints that python3 is present (documents that on a python-less host the runner prints `SKIP:` and exits 0 rather than failing). No code change needed; this confirms the guard exists in `reference/pytest/run.sh`.

- [ ] **Step 4: Commit**

```bash
git add plugins/payment-contract-tester/tests/run-tests.sh
git commit -m "feat(payment-contract-tester): self-test orchestrator (pytest stack)"
```

---

## Self-Review

**Spec coverage (vs design spec §4):**
- §4.1 Skill + references (3 gateways + invariants, URL/date pinned) → Task 3 ✓
- §4.4 self-test fixtures, GREEN vs RED, canonical + webhook-security traps → Tasks 4–6 ✓ (traps 1–10 runnable; trap 11 ack-before-durable-write is documented-only in invariants.md per the handler-modeling note — recorded in Task 3 Step 2)
- §5 testing strategy (bash + runners, skip-if-absent, no false green) → Task 5 run.sh guard + Task 6 ✓
- §6 versioning + README install section → Tasks 1, 2 ✓
- §4.2 `/scaffold` and §4.3 enforcement harness → **Plan 3** (out of scope here, stated up front) ✓
- xUnit fixtures → **Plan 2** ✓

**Placeholder scan:** No "TBD/TODO-implement". The only `TODO-verify-against-sandbox` strings are an intentional skill convention (commented uncertain assertions), not plan placeholders. Doc tasks (3) give exact structure + one fully-worked entry + enumerated remaining entries with their facts sourced from spec §3 — the spec is the content, not a placeholder.

**Type consistency:** Handler API names (`Store`, `create_order`, `paid_count`, `build_grand_total`, `make_webhook_token`, `handle_webhook`, `SECRET`, `TOLERANCE`, `TERMINAL`, env `PCT_HANDLER`) are defined in Task 4 and used identically in Task 5's trap table and Task 5/6 runners. Trap→test mapping in the Task 5 table matches the test names in Task 4's `test_contract.py` and the `traps` list in `run.sh`.

---

## Execution Handoff

Plan 1 of 3. Plans 2 (xUnit fixtures) and 3 (`/scaffold` + CI/hook harness) to be written when reached.
