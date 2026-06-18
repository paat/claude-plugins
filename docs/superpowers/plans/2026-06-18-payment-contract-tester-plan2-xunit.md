# payment-contract-tester Plan 2 — xUnit reference fixtures (.NET) + runner hardening

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror the shipped pytest proof in xUnit so the plugin's acceptance criterion (green-vs-correct, red-vs-each-trap) is proven for the .NET stack too, and harden BOTH runners' trap-isolation check.

**Architecture:** A self-contained .NET 9 / xUnit test project under `reference/xunit/`. A correct mock webhook handler implements `IPaymentHandler`; the contract suite (10 `[Fact]`s mirroring the pytest tests) runs against whichever handler `HandlerFactory.FromEnv()` returns, selected at run time by the `PCT_HANDLER` env var — exactly mirroring how the pytest suite imports a module named by `PCT_HANDLER`. Each of the 10 seeded traps is a one-edit copy of the correct handler in `reference/xunit/Traps/`. A `run.sh` builds once, asserts the correct handler is all-green, then asserts each trap reddens its mapped test (and — for non-foundational traps — leaves the others green). JWT is HS256 via the BCL only (`System.Security.Cryptography`), no third-party gateway SDK.

**Tech Stack:** .NET 9 SDK (xUnit, `Microsoft.NET.Test.Sdk`, `xunit.runner.visualstudio` — all from `dotnet new xunit`), bash 4+, `System.Text.Json` + `HMACSHA256` from the BCL.

## Global Constraints

- **Trap → invariant mapping is identical across stacks** (the canonical 10, from the handoff):
  `trap_01` claim-shape (camelCase→snake_case key) · `trap_02` missing-required-claim guard removed ·
  `trap_03` reference-reuse guard removed · `trap_04` float money (not integer-cents string) ·
  `trap_05` no webhook dedupe · `trap_06` skip signature verification · `trap_07` trust body status
  not verified-token status · `trap_08` no recency/tolerance window · `trap_09` terminal-state
  downgrade allowed · `trap_10` concurrency race (remove lock + widen window).
- **Target framework `net9.0`** (matches the live target repo Varustame, .NET 9 / ASP.NET Core).
- **No third-party gateway SDK.** JWT is hand-rolled HS256 using only `System.Security.Cryptography` + `System.Text.Json` (mirrors pytest `jwtmini.py`).
- **Runner must SKIP cleanly when `dotnet` is absent** (print a SKIP line, exit 0) — never a false green, exactly like the pytest guard. (`dotnet` is on PATH only when the .NET SDK is installed/exported; CI without the SDK and any un-exported shell will correctly SKIP.)
- **Runner hardening applies to BOTH stacks.** Non-foundational traps must redden their mapped test AND leave the other tests green, except a documented per-trap "also-red allowlist". **Exempt only `trap_01`** (empirically reddens 5/10 tests — a malformed token has no clean single-test isolation). `trap_05`'s allowlist is the concurrency test (dedupe underpins both replay and concurrency). All other traps have an empty allowlist. *(This refines the handoff, which exempted both 01 and 02; live verification shows trap_02 isolates cleanly to 1 test — see Task 1 note.)*
- **Version bump in BOTH** `plugins/payment-contract-tester/.claude-plugin/plugin.json` **and** root `.claude-plugin/marketplace.json` (kept in sync) before push: `0.1.0` → `0.1.1`.
- **Commit trailer:** `Claude-Session: <session-url>`.

## File Structure

```
plugins/payment-contract-tester/
├── reference/
│   ├── pytest/run.sh                  # MODIFY (Task 1): add the others-green hardening
│   └── xunit/                         # NEW (Tasks 2–4)
│       ├── .gitignore                 # bin/ obj/
│       ├── ContractFixture.csproj     # from `dotnet new xunit`
│       ├── GlobalUsings.cs            # from `dotnet new xunit` (global using Xunit;)
│       ├── JwtMini.cs                 # BCL HS256 encode/decode/decode-unsafe
│       ├── Interfaces.cs              # IPaymentHandler, IStore
│       ├── HandlerFactory.cs          # PCT_HANDLER → handler instance
│       ├── CorrectHandler.cs          # the reference correct handler
│       ├── ContractTests.cs           # the 10 [Fact] contract tests
│       ├── Traps/Trap01ClaimShape.cs … Trap10Concurrency.cs   # 10 one-edit copies (Task 3)
│       └── run.sh                     # build once, green + red + others-green (Task 4)
└── tests/run-tests.sh                 # MODIFY (Task 4): wire in reference/xunit/run.sh
```

Each `Traps/TrapNN_*.cs` is a copy of `CorrectHandler.cs` with the public class renamed and exactly one invariant broken — the faithful mirror of how each `reference/pytest/trap_*.py` is a one-edit copy of `handler.py`.

---

## Task 1: Harden the pytest runner (others-green check)

**Files:**
- Modify: `plugins/payment-contract-tester/reference/pytest/run.sh`

**Interfaces:**
- Produces: the hardening contract that Task 4's `reference/xunit/run.sh` mirrors exactly — the trap spec format `module:mapped_test:allowlist`, the `EXEMPT` sentinel, and the two-check loop (mapped-red, then others-green minus allowlist).

**Note (why exempt only trap_01):** live verification on the shipped fixture —
`PCT_HANDLER=trap_01_claim_shape pytest -q` → **5 failed, 5 passed** (the malformed token key reddens every test that drives a successful effect; no clean single-test isolation → EXEMPT).
`PCT_HANDLER=trap_02_missing_claim_guard pytest -q` → **1 failed, 9 passed** (isolates cleanly to its mapped test → apply the others-green check, empty allowlist). This corrects the handoff, which assumed trap_02 also lacked isolation.

- [ ] **Step 1: Replace `run.sh` with the hardened version**

Overwrite `plugins/payment-contract-tester/reference/pytest/run.sh` with exactly:

```bash
#!/usr/bin/env bash
# Runs the pytest reference suite: GREEN against the correct handler, then asserts each seeded
# trap reddens its mapped test AND (for non-foundational traps) leaves the OTHER tests green —
# so a trap that reddens its target for an unrelated reason is caught. Exit 0 only if all hold.
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

# module : mapped_test : also-red allowlist (|-separated, may be empty; EXEMPT = skip others-green).
# trap_01 is EXEMPT: a malformed token key reddens every effect-driving test (5/10) — there is no
# clean single-test isolation. trap_05's allowlist is the concurrency test: removing dedupe reddens
# both the replay AND the concurrency test (dedupe underpins both).
traps="
trap_01_claim_shape:test_paid_marks_order:EXEMPT
trap_02_missing_claim_guard:test_required_claim_missing_rejected:
trap_03_reference_reuse:test_duplicate_reference_rejected:
trap_04_float_money:test_money_decimal_boundary_no_float:
trap_05_no_dedupe:test_replayed_webhook_idempotent:test_concurrent_duplicate_applies_once
trap_06_skip_signature:test_forged_signature_rejected:
trap_07_trust_body_status:test_status_taken_from_token_not_body:
trap_08_no_recency:test_stale_timestamp_rejected:
trap_09_downgrade:test_terminal_state_not_downgraded:
trap_10_concurrency:test_concurrent_duplicate_applies_once:
"

echo "== seeded traps (expect each to redden its mapped test) =="
for spec in $traps; do
  mod=${spec%%:*}; rest=${spec#*:}; tst=${rest%%:*}; allow=${rest#*:}

  # 1) the mapped test MUST go red
  if PCT_HANDLER=$mod python3 -m pytest -q -k "$tst" >/dev/null 2>&1; then
    echo "FAIL: $mod stayed green for $tst"; fail=1
  else
    echo "OK: $mod reddened $tst"
  fi

  # 2) non-foundational traps must leave the OTHER tests green (minus the documented allowlist)
  if [ "$allow" = "EXEMPT" ]; then
    echo "   (exempt from others-green: foundational claim trap)"; continue
  fi
  expr="not $tst"
  if [ -n "$allow" ]; then
    IFS='|' read -ra extra <<< "$allow"
    for e in "${extra[@]}"; do expr="$expr and not $e"; done
  fi
  if PCT_HANDLER=$mod python3 -m pytest -q -k "$expr" >/dev/null 2>&1; then
    echo "OK: $mod left the other tests green"
  else
    echo "FAIL: $mod reddened an unrelated test"; fail=1
  fi
done

exit $fail
```

- [ ] **Step 2: Run the hardened pytest runner**

Run: `bash plugins/payment-contract-tester/reference/pytest/run.sh; echo "exit=$?"`
Expected: `OK: correct handler all green`, then for every trap `OK: … reddened …`; for `trap_01` the line `(exempt from others-green: foundational claim trap)`; for every other trap `OK: … left the other tests green`. Final line `exit=0`.

- [ ] **Step 3: Commit**

```bash
git add plugins/payment-contract-tester/reference/pytest/run.sh
git commit -m "test(payment-contract-tester): harden pytest runner with others-green trap-isolation check

Claude-Session: <session-url>"
```

---

## Task 2: xUnit project scaffold — correct handler, green suite

**Files:**
- Create: `plugins/payment-contract-tester/reference/xunit/.gitignore`
- Create (via `dotnet new xunit`): `ContractFixture.csproj`, `GlobalUsings.cs`
- Create: `reference/xunit/JwtMini.cs`, `Interfaces.cs`, `CorrectHandler.cs`, `HandlerFactory.cs`, `ContractTests.cs`
- Delete: the generated `UnitTest1.cs`

**Interfaces:**
- Produces (consumed by Tasks 3 & 4):
  - `public interface IStore { void CreateOrder(string reference, long amountCents); string? OrderStatus(string reference); int PaidCount(string reference); }`
  - `public interface IPaymentHandler { byte[] Secret { get; } string BuildGrandTotal(long amountCents); string MakeWebhookToken(string uuid, string reference, string status, long amountCents, byte[]? secret = null, long now = 1_700_000_000, bool iat = true); IStore NewStore(); int HandleWebhook(IStore store, string rawBody, long now); }`
  - `public static class JwtMini { string Encode(IDictionary<string,object?> claims, byte[] secret); Dictionary<string,JsonElement> Decode(string token, byte[] secret); Dictionary<string,JsonElement> DecodeUnsafe(string token); }`
  - `public static class HandlerFactory { IPaymentHandler FromEnv(); }` — reads `PCT_HANDLER` (default `correct`).
  - The 10 `[Fact]` names (used as filter substrings by both run.sh scripts):
    `Money_decimal_boundary_no_float`, `Paid_marks_order`, `Required_claim_missing_rejected`,
    `Duplicate_reference_rejected`, `Forged_signature_rejected`, `Status_taken_from_token_not_body`,
    `Stale_timestamp_rejected`, `Replayed_webhook_idempotent`, `Terminal_state_not_downgraded`,
    `Concurrent_duplicate_applies_once`.

> **Environment note for the implementer:** this container has no system `dotnet`. Provision it once (no sudo) and export it for every build/test step in Tasks 2–4:
> ```bash
> [ -x "$HOME/.dotnet/dotnet" ] || { curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && bash /tmp/di.sh --channel 9.0 --install-dir "$HOME/.dotnet"; }
> export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
> dotnet --version   # 9.0.x
> ```

- [ ] **Step 1: Scaffold the project**

```bash
cd plugins/payment-contract-tester/reference/xunit
dotnet new xunit -n ContractFixture -o .
rm -f UnitTest1.cs
```
Expected: creates `ContractFixture.csproj`, `GlobalUsings.cs` (contains `global using Xunit;`), and an `obj/` dir. `ls` shows `ContractFixture.csproj`.

- [ ] **Step 2: Write `.gitignore`**

Create `reference/xunit/.gitignore`:
```gitignore
bin/
obj/
```

- [ ] **Step 3: Write `JwtMini.cs`**

Create `reference/xunit/JwtMini.cs`:
```csharp
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ContractFixture;

/// <summary>Minimal HS256 JWT encode/verify using only the BCL (mirrors pytest jwtmini.py).</summary>
public static class JwtMini
{
    private static string B64u(byte[] b) =>
        Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] B64uDec(string s)
    {
        s = s.Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4) { case 2: s += "=="; break; case 3: s += "="; break; }
        return Convert.FromBase64String(s);
    }

    public static string Encode(IDictionary<string, object?> claims, byte[] secret)
    {
        var header = JsonSerializer.SerializeToUtf8Bytes(
            new Dictionary<string, object?> { ["alg"] = "HS256", ["typ"] = "JWT" });
        var payload = JsonSerializer.SerializeToUtf8Bytes(claims);
        var seg = B64u(header) + "." + B64u(payload);
        var sig = HMACSHA256.HashData(secret, Encoding.UTF8.GetBytes(seg));
        return seg + "." + B64u(sig);
    }

    /// <summary>Verify the HS256 signature (constant-time) and return the claims.</summary>
    public static Dictionary<string, JsonElement> Decode(string token, byte[] secret)
    {
        var lastDot = token.LastIndexOf('.');
        if (lastDot <= 0) throw new FormatException("malformed token");
        var seg = token.Substring(0, lastDot);
        var sigB64 = token.Substring(lastDot + 1);
        if (seg.IndexOf('.') < 0 || sigB64.Length == 0) throw new FormatException("malformed token");
        var expected = HMACSHA256.HashData(secret, Encoding.UTF8.GetBytes(seg));
        if (!CryptographicOperations.FixedTimeEquals(expected, B64uDec(sigB64)))
            throw new FormatException("bad signature");
        var payloadB64 = seg.Substring(seg.IndexOf('.') + 1);
        return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(B64uDec(payloadB64))!;
    }

    /// <summary>Parse claims WITHOUT verifying the signature. Used only by a seeded trap.</summary>
    public static Dictionary<string, JsonElement> DecodeUnsafe(string token)
    {
        var lastDot = token.LastIndexOf('.');
        var seg = token.Substring(0, lastDot);
        var payloadB64 = seg.Substring(seg.IndexOf('.') + 1);
        return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(B64uDec(payloadB64))!;
    }
}
```

- [ ] **Step 4: Write `Interfaces.cs`**

Create `reference/xunit/Interfaces.cs`:
```csharp
namespace ContractFixture;

/// <summary>The order store the handler mutates. Each handler variant owns a concrete impl so that
/// store-level traps (reference reuse, dedupe, concurrency) are one-edit changes like the rest.</summary>
public interface IStore
{
    void CreateOrder(string reference, long amountCents);
    string? OrderStatus(string reference);   // null when the order does not exist
    int PaidCount(string reference);
}

/// <summary>The handler-under-test seam. HandlerFactory.FromEnv() picks the implementation.</summary>
public interface IPaymentHandler
{
    byte[] Secret { get; }
    string BuildGrandTotal(long amountCents);
    string MakeWebhookToken(string uuid, string reference, string status, long amountCents,
                            byte[]? secret = null, long now = 1_700_000_000, bool iat = true);
    IStore NewStore();
    int HandleWebhook(IStore store, string rawBody, long now);
}
```

- [ ] **Step 5: Write `CorrectHandler.cs`**

Create `reference/xunit/CorrectHandler.cs`:
```csharp
using System.Text;
using System.Text.Json;

namespace ContractFixture;

/// <summary>Reference CORRECT mock payment-webhook handler (Montonio-style HS256 JWT).
/// Each Traps/TrapNN_*.cs is a one-edit copy of this file with a single invariant broken.</summary>
public sealed class CorrectHandler : IPaymentHandler
{
    private static readonly byte[] SECRET = Encoding.UTF8.GetBytes("test-secret");
    private const long TOLERANCE = 300;
    private static readonly HashSet<string> TERMINAL = new() { "PAID", "ABANDONED", "REFUNDED" };

    public byte[] Secret => SECRET;

    private sealed class Order { public string Status = "PENDING"; public long AmountCents; }

    // The store is internally thread-safe (concurrent collections); the only thing the lock in
    // HandleWebhook adds is check-then-act atomicity — so the concurrency trap is purely "drop the
    // lock", never a container-corruption crash.
    private sealed class MockStore : IStore
    {
        public readonly Dictionary<string, Order> Orders = new();
        public readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte> Processed = new();
        public readonly System.Collections.Concurrent.ConcurrentQueue<(string Ref, string Status)> Effects = new();
        public readonly object Lock = new();

        public void CreateOrder(string reference, long amountCents)
        {
            if (Orders.ContainsKey(reference))                 // reference-uniqueness (fresh order)
                throw new InvalidOperationException($"duplicate merchantReference: {reference}");
            Orders[reference] = new Order { Status = "PENDING", AmountCents = amountCents };
        }
        public string? OrderStatus(string reference) =>
            Orders.TryGetValue(reference, out var o) ? o.Status : null;
        public int PaidCount(string reference) =>
            Effects.Count(e => e.Ref == reference && e.Status == "PAID");
    }

    public IStore NewStore() => new MockStore();

    public string BuildGrandTotal(long amountCents) =>                 // money-minor-units: no float
        $"{amountCents / 100}.{amountCents % 100:D2}";

    public string MakeWebhookToken(string uuid, string reference, string status, long amountCents,
                                   byte[]? secret = null, long now = 1_700_000_000, bool iat = true)
    {
        var claims = new Dictionary<string, object?>
        {
            ["accessKey"] = "ak",
            ["uuid"] = uuid,
            ["merchantReference"] = reference,
            ["paymentStatus"] = status,
            ["grandTotal"] = BuildGrandTotal(amountCents),
            ["currency"] = "EUR",
            ["exp"] = now + 600,
        };
        if (iat) claims["iat"] = now;
        return JwtMini.Encode(claims, secret ?? SECRET);
    }

    public int HandleWebhook(IStore store, string rawBody, long now)
    {
        var s = (MockStore)store;
        var body = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(rawBody)!;
        var token = body.TryGetValue("orderToken", out var t) ? t.GetString() ?? "" : "";
        Dictionary<string, JsonElement> claims;
        try { claims = JwtMini.Decode(token, SECRET); }       // webhook-authenticity (constant-time)
        catch (Exception) { return 401; }
        if (!claims.TryGetValue("iat", out var iatEl) || Math.Abs(now - iatEl.GetInt64()) > TOLERANCE)
            return 401;                                       // replay / recency window
        var reference = claims.TryGetValue("merchantReference", out var r) ? r.GetString() : null;
        var status = claims.TryGetValue("paymentStatus", out var st) ? st.GetString() : null;  // VERIFIED token
        if (string.IsNullOrEmpty(reference) || string.IsNullOrEmpty(status))   // required claim shape
            return 400;
        if (!s.Orders.TryGetValue(reference, out var order))
            return 404;
        var uuid = claims["uuid"].GetString()!;
        lock (s.Lock)                                          // atomic, durable dedupe
        {
            if (s.Processed.ContainsKey(uuid))                // idempotent-effects
                return 200;
            if (TERMINAL.Contains(order.Status) && status != order.Status)
            {
                s.Processed.TryAdd(uuid, 0);                  // terminal-state-ordering: no downgrade
                return 200;
            }
            order.Status = status;                            // durability-before-ack: persist first
            s.Effects.Enqueue((reference, status));
            s.Processed.TryAdd(uuid, 0);
        }
        return 200;
    }
}
```

- [ ] **Step 6: Write `HandlerFactory.cs` (correct-only for now)**

Create `reference/xunit/HandlerFactory.cs`:
```csharp
namespace ContractFixture;

public static class HandlerFactory
{
    public static IPaymentHandler FromEnv()
    {
        var name = Environment.GetEnvironmentVariable("PCT_HANDLER") ?? "correct";
        return name switch
        {
            "correct" => new CorrectHandler(),
            // trap_* cases are added in Task 3.
            _ => throw new ArgumentException($"unknown PCT_HANDLER: {name}"),
        };
    }
}
```

- [ ] **Step 7: Write `ContractTests.cs`**

Create `reference/xunit/ContractTests.cs`:
```csharp
using System.Text;
using Xunit;

namespace ContractFixture;

public class ContractTests
{
    private static readonly IPaymentHandler H = HandlerFactory.FromEnv();
    private const long NOW = 1_700_000_000;

    private static IStore Fresh()
    {
        var s = H.NewStore();
        s.CreateOrder("REF-1", 2500);
        return s;
    }

    private static string Wh(string token) => $"{{\"orderToken\": \"{token}\"}}";

    [Fact]
    public void Money_decimal_boundary_no_float()
    {
        Assert.Equal("25.00", H.BuildGrandTotal(2500));
        Assert.Equal("0.07", H.BuildGrandTotal(7));
        Assert.Equal("19.99", H.BuildGrandTotal(1999));
    }

    [Fact]
    public void Paid_marks_order()
    {
        var s = Fresh();
        var tok = H.MakeWebhookToken("e1", "REF-1", "PAID", 2500, now: NOW);
        Assert.Equal(200, H.HandleWebhook(s, Wh(tok), NOW));
        Assert.Equal("PAID", s.OrderStatus("REF-1"));
    }

    [Fact]
    public void Required_claim_missing_rejected()
    {
        var claims = new Dictionary<string, object?>
        {
            ["accessKey"] = "ak", ["uuid"] = "e1", ["paymentStatus"] = "PAID",
            ["exp"] = NOW + 600, ["iat"] = NOW,   // no merchantReference
        };
        var tok = JwtMini.Encode(claims, H.Secret);
        var s = Fresh();
        Assert.Equal(400, H.HandleWebhook(s, Wh(tok), NOW));
    }

    [Fact]
    public void Duplicate_reference_rejected()
    {
        var s = Fresh();
        Assert.ThrowsAny<Exception>(() => s.CreateOrder("REF-1", 999));
    }

    [Fact]
    public void Forged_signature_rejected()
    {
        var s = Fresh();
        var bad = H.MakeWebhookToken("e1", "REF-1", "PAID", 2500, now: NOW,
                                     secret: Encoding.UTF8.GetBytes("wrong"));
        Assert.Equal(401, H.HandleWebhook(s, Wh(bad), NOW));
        Assert.Equal("PENDING", s.OrderStatus("REF-1"));
    }

    [Fact]
    public void Status_taken_from_token_not_body()
    {
        var s = Fresh();
        var tok = H.MakeWebhookToken("e1", "REF-1", "ABANDONED", 2500, now: NOW);
        var body = $"{{\"orderToken\": \"{tok}\", \"paymentStatus\": \"PAID\"}}";
        H.HandleWebhook(s, body, NOW);
        Assert.Equal("ABANDONED", s.OrderStatus("REF-1"));   // body's PAID must be ignored
    }

    [Fact]
    public void Stale_timestamp_rejected()
    {
        var s = Fresh();
        var tok = H.MakeWebhookToken("e1", "REF-1", "PAID", 2500, now: NOW - 10_000);
        Assert.Equal(401, H.HandleWebhook(s, Wh(tok), NOW));
        Assert.Equal("PENDING", s.OrderStatus("REF-1"));
    }

    [Fact]
    public void Replayed_webhook_idempotent()
    {
        var s = Fresh();
        var tok = H.MakeWebhookToken("e1", "REF-1", "PAID", 2500, now: NOW);
        H.HandleWebhook(s, Wh(tok), NOW);
        H.HandleWebhook(s, Wh(tok), NOW);   // replay (same uuid)
        Assert.Equal(1, s.PaidCount("REF-1"));
    }

    [Fact]
    public void Terminal_state_not_downgraded()
    {
        var s = Fresh();
        var paid = H.MakeWebhookToken("e1", "REF-1", "PAID", 2500, now: NOW);
        H.HandleWebhook(s, Wh(paid), NOW);
        var aband = H.MakeWebhookToken("e2", "REF-1", "ABANDONED", 2500, now: NOW);
        H.HandleWebhook(s, Wh(aband), NOW);
        Assert.Equal("PAID", s.OrderStatus("REF-1"));
    }

    [Fact]
    public void Concurrent_duplicate_applies_once()
    {
        var s = Fresh();
        var tok = H.MakeWebhookToken("e1", "REF-1", "PAID", 2500, now: NOW);
        var body = Wh(tok);
        var barrier = new System.Threading.Barrier(8);
        var threads = new System.Threading.Thread[8];
        for (int i = 0; i < 8; i++)
        {
            threads[i] = new System.Threading.Thread(() =>
            {
                barrier.SignalAndWait();
                H.HandleWebhook(s, body, NOW);
            });
        }
        foreach (var th in threads) th.Start();
        foreach (var th in threads) th.Join();
        Assert.Equal(1, s.PaidCount("REF-1"));
    }
}
```

- [ ] **Step 8: Build, then run the correct handler — expect all green**

```bash
cd plugins/payment-contract-tester/reference/xunit
dotnet build -v quiet
PCT_HANDLER=correct dotnet test --no-build
```
Expected: build succeeds; `Passed!  - Failed: 0, Passed: 10`. (If a `dotnet test` filter is omitted, `PCT_HANDLER` defaults to `correct` anyway.)

- [ ] **Step 9: Commit**

```bash
git add plugins/payment-contract-tester/reference/xunit/.gitignore \
        plugins/payment-contract-tester/reference/xunit/ContractFixture.csproj \
        plugins/payment-contract-tester/reference/xunit/GlobalUsings.cs \
        plugins/payment-contract-tester/reference/xunit/JwtMini.cs \
        plugins/payment-contract-tester/reference/xunit/Interfaces.cs \
        plugins/payment-contract-tester/reference/xunit/CorrectHandler.cs \
        plugins/payment-contract-tester/reference/xunit/HandlerFactory.cs \
        plugins/payment-contract-tester/reference/xunit/ContractTests.cs
git commit -m "feat(payment-contract-tester): xUnit reference fixture — correct handler + contract suite (green)

Claude-Session: <session-url>"
```

---

## Task 3: The 10 seeded xUnit traps (red proofs)

**Files:**
- Create: `reference/xunit/Traps/Trap01ClaimShape.cs` … `Trap10Concurrency.cs`
- Modify: `reference/xunit/HandlerFactory.cs` (add the 10 cases)

**Interfaces:**
- Consumes: `IPaymentHandler`, `IStore`, `JwtMini`, the `MockStore`/`Order`/`SECRET`/`TOLERANCE`/`TERMINAL` shape from `CorrectHandler.cs` (each trap is a copy of that file).
- Produces: 10 classes `Trap01ClaimShape … Trap10Concurrency`, each `: IPaymentHandler`, registered in `HandlerFactory` under the env keys `trap_01_claim_shape … trap_10_concurrency`.

**Procedure for every trap (do this 10 times):**
1. `cp CorrectHandler.cs Traps/TrapNN_Name.cs`
2. In the copy, change the class declaration line `public sealed class CorrectHandler : IPaymentHandler` to `public sealed class TrapNN_Name : IPaymentHandler` (nested `Order`/`MockStore` names stay — they are private and per-file).
3. Update the XML doc comment first line to `/// <summary>SEEDED TRAP …</summary>` describing the one break.
4. Apply the single edit shown below.

The exact class name ↔ file ↔ env key for each:

| File | Class | Env key (`PCT_HANDLER`) |
|---|---|---|
| `Traps/Trap01ClaimShape.cs` | `Trap01ClaimShape` | `trap_01_claim_shape` |
| `Traps/Trap02MissingClaimGuard.cs` | `Trap02MissingClaimGuard` | `trap_02_missing_claim_guard` |
| `Traps/Trap03ReferenceReuse.cs` | `Trap03ReferenceReuse` | `trap_03_reference_reuse` |
| `Traps/Trap04FloatMoney.cs` | `Trap04FloatMoney` | `trap_04_float_money` |
| `Traps/Trap05NoDedupe.cs` | `Trap05NoDedupe` | `trap_05_no_dedupe` |
| `Traps/Trap06SkipSignature.cs` | `Trap06SkipSignature` | `trap_06_skip_signature` |
| `Traps/Trap07TrustBodyStatus.cs` | `Trap07TrustBodyStatus` | `trap_07_trust_body_status` |
| `Traps/Trap08NoRecency.cs` | `Trap08NoRecency` | `trap_08_no_recency` |
| `Traps/Trap09Downgrade.cs` | `Trap09Downgrade` | `trap_09_downgrade` |
| `Traps/Trap10Concurrency.cs` | `Trap10Concurrency` | `trap_10_concurrency` |

- [ ] **Step 1: `Trap01ClaimShape` — claim-shape (snake_case key)**

In `MakeWebhookToken`, change the claims dictionary line:
```csharp
            ["merchantReference"] = reference,
```
to:
```csharp
            ["merchant_reference"] = reference,   // SEEDED TRAP: renamed claim key breaks receiver lookup
```

- [ ] **Step 2: `Trap02MissingClaimGuard` — required-claim guard removed**

In `HandleWebhook`, delete the two guard lines:
```csharp
        if (string.IsNullOrEmpty(reference) || string.IsNullOrEmpty(status))   // required claim shape
            return 400;
```
and replace with:
```csharp
        // SEEDED TRAP: required-claim guard deleted — a missing merchantReference now reaches the
        // store lookup (TryGetValue(null)) and errors instead of returning 400.
```

- [ ] **Step 3: `Trap03ReferenceReuse` — duplicate-reference guard removed**

In `MockStore.CreateOrder`, delete the guard:
```csharp
            if (Orders.ContainsKey(reference))                 // reference-uniqueness (fresh order)
                throw new InvalidOperationException($"duplicate merchantReference: {reference}");
```
and replace with:
```csharp
            // SEEDED TRAP: duplicate-reference guard deleted — ref uniqueness not enforced
```

- [ ] **Step 4: `Trap04FloatMoney` — float money**

Change `BuildGrandTotal`:
```csharp
    public string BuildGrandTotal(long amountCents) =>                 // money-minor-units: no float
        $"{amountCents / 100}.{amountCents % 100:D2}";
```
to:
```csharp
    public string BuildGrandTotal(long amountCents) =>   // SEEDED TRAP: float money (drops trailing zeros)
        (amountCents / 100.0).ToString(System.Globalization.CultureInfo.InvariantCulture);
```

- [ ] **Step 5: `Trap05NoDedupe` — dedupe guard removed**

In `HandleWebhook`, delete the dedupe check:
```csharp
            if (s.Processed.ContainsKey(uuid))                // idempotent-effects
                return 200;
```
and replace with:
```csharp
            // SEEDED TRAP: idempotent-effects dedupe deleted — replays (and concurrent dupes) apply twice
```

- [ ] **Step 6: `Trap06SkipSignature` — signature not verified**

Change the decode line:
```csharp
        try { claims = JwtMini.Decode(token, SECRET); }       // webhook-authenticity (constant-time)
```
to:
```csharp
        try { claims = JwtMini.DecodeUnsafe(token); }          // SEEDED TRAP: signature skipped — forged tokens accepted
```

- [ ] **Step 7: `Trap07TrustBodyStatus` — body status trusted**

In `HandleWebhook`, immediately after the `status` line, insert one line:
```csharp
        var status = claims.TryGetValue("paymentStatus", out var st) ? st.GetString() : null;  // VERIFIED token
        status = body.TryGetValue("paymentStatus", out var bs) ? bs.GetString() : status;  // SEEDED TRAP: untrusted body overrides token status
```

- [ ] **Step 8: `Trap08NoRecency` — recency window dropped**

Change the recency check:
```csharp
        if (!claims.TryGetValue("iat", out var iatEl) || Math.Abs(now - iatEl.GetInt64()) > TOLERANCE)
            return 401;                                       // replay / recency window
```
to:
```csharp
        if (!claims.ContainsKey("iat"))                       // SEEDED TRAP: recency window dropped — stale tokens accepted
            return 401;
```

- [ ] **Step 9: `Trap09Downgrade` — terminal-state downgrade allowed**

In `HandleWebhook`, delete the terminal-state guard:
```csharp
            if (TERMINAL.Contains(order.Status) && status != order.Status)
            {
                s.Processed.TryAdd(uuid, 0);                  // terminal-state-ordering: no downgrade
                return 200;
            }
```
and replace with:
```csharp
            // SEEDED TRAP: terminal-state downgrade guard deleted — PAID can be overwritten
```

- [ ] **Step 10: `Trap10Concurrency` — lock removed + race window widened**

Replace the whole `lock (s.Lock) { … }` block:
```csharp
        lock (s.Lock)                                          // atomic, durable dedupe
        {
            if (s.Processed.ContainsKey(uuid))                // idempotent-effects
                return 200;
            if (TERMINAL.Contains(order.Status) && status != order.Status)
            {
                s.Processed.TryAdd(uuid, 0);                  // terminal-state-ordering: no downgrade
                return 200;
            }
            order.Status = status;                            // durability-before-ack: persist first
            s.Effects.Enqueue((reference, status));
            s.Processed.TryAdd(uuid, 0);
        }
```
with the same body, lock removed and a race window inserted:
```csharp
        // SEEDED TRAP: lock removed — concurrent requests are no longer serialized
        if (s.Processed.ContainsKey(uuid))                    // idempotent-effects
            return 200;
        System.Threading.Thread.Sleep(1);                     // SEEDED TRAP: widen race window so concurrent dupes double-apply
        if (TERMINAL.Contains(order.Status) && status != order.Status)
        {
            s.Processed.TryAdd(uuid, 0);                      // terminal-state-ordering: no downgrade
            return 200;
        }
        order.Status = status;                                // durability-before-ack: persist first
        s.Effects.Enqueue((reference, status));
        s.Processed.TryAdd(uuid, 0);
```

- [ ] **Step 11: Extend `HandlerFactory.FromEnv()` with all 10 cases**

Replace the body of the `switch` in `reference/xunit/HandlerFactory.cs` so it reads:
```csharp
        return name switch
        {
            "correct" => new CorrectHandler(),
            "trap_01_claim_shape" => new Trap01ClaimShape(),
            "trap_02_missing_claim_guard" => new Trap02MissingClaimGuard(),
            "trap_03_reference_reuse" => new Trap03ReferenceReuse(),
            "trap_04_float_money" => new Trap04FloatMoney(),
            "trap_05_no_dedupe" => new Trap05NoDedupe(),
            "trap_06_skip_signature" => new Trap06SkipSignature(),
            "trap_07_trust_body_status" => new Trap07TrustBodyStatus(),
            "trap_08_no_recency" => new Trap08NoRecency(),
            "trap_09_downgrade" => new Trap09Downgrade(),
            "trap_10_concurrency" => new Trap10Concurrency(),
            _ => throw new ArgumentException($"unknown PCT_HANDLER: {name}"),
        };
```

- [ ] **Step 12: Build, then verify the correct handler is still green and each trap reddens its mapped test**

```bash
cd plugins/payment-contract-tester/reference/xunit
dotnet build -v quiet
PCT_HANDLER=correct dotnet test --no-build --filter "FullyQualifiedName~ContractTests" 2>&1 | tail -1
# spot-check three traps red their mapped test (non-zero exit = red, as expected):
for kv in trap_04_float_money:Money_decimal_boundary_no_float \
          trap_06_skip_signature:Forged_signature_rejected \
          trap_10_concurrency:Concurrent_duplicate_applies_once; do
  mod=${kv%%:*}; tst=${kv##*:}
  PCT_HANDLER=$mod dotnet test --no-build --filter "FullyQualifiedName~$tst" >/dev/null 2>&1 \
    && echo "$mod UNEXPECTED GREEN" || echo "$mod reddened $tst (expected)"
done
```
Expected: correct handler `Passed: 10`; each spot-checked trap prints `… reddened … (expected)`.

- [ ] **Step 13: Commit**

```bash
git add plugins/payment-contract-tester/reference/xunit/Traps \
        plugins/payment-contract-tester/reference/xunit/HandlerFactory.cs
git commit -m "feat(payment-contract-tester): 10 seeded xUnit traps + factory wiring (red proofs)

Claude-Session: <session-url>"
```

---

## Task 4: xUnit runner + self-test integration + docs

**Files:**
- Create: `reference/xunit/run.sh`
- Modify: `tests/run-tests.sh` (uncomment/replace the Plan 2 placeholder)
- Modify: `README.md` (add .NET/xUnit to fixtures + dependencies)
- Modify: `.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json` (version `0.1.0` → `0.1.1`)

**Interfaces:**
- Consumes: the `FullyQualifiedName` substrings from Task 2's `[Fact]` names; the env keys from Task 3; the hardening contract from Task 1.

- [ ] **Step 1: Write `reference/xunit/run.sh`**

Create `reference/xunit/run.sh` (mark executable in Step 2):
```bash
#!/usr/bin/env bash
# Runs the xUnit reference suite: GREEN against the correct handler, then asserts each seeded trap
# reddens its mapped test AND (for non-foundational traps) leaves the OTHER tests green. Exit 0 only
# if all hold. SKIPs cleanly if the .NET SDK is absent (no false green) — mirrors the pytest guard.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "SKIP: dotnet SDK not available"; exit 0
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

# Build once; the handler-under-test is chosen at runtime via PCT_HANDLER, so one build serves all.
if ! dotnet build -v quiet >/tmp/pct_xunit_build.log 2>&1; then
  echo "FAIL: xunit project did not build"; cat /tmp/pct_xunit_build.log; exit 1
fi

run() {  # run <PCT_HANDLER> [extra dotnet test args...]
  local handler="$1"; shift
  PCT_HANDLER="$handler" dotnet test --no-build "$@"
}

fail=0

echo "== correct handler (expect all green) =="
if run correct >/tmp/pct_xunit_green.log 2>&1; then
  echo "OK: correct handler all green"
else
  echo "FAIL: correct handler was not all green"; cat /tmp/pct_xunit_green.log; fail=1
fi

# module : mapped_test : also-red allowlist (|-separated, may be empty; EXEMPT = skip others-green).
# Mirrors reference/pytest/run.sh exactly. trap_01 is EXEMPT (a malformed token key reddens every
# effect-driving test — no clean isolation). trap_05's allowlist is the concurrency test.
traps="
trap_01_claim_shape:Paid_marks_order:EXEMPT
trap_02_missing_claim_guard:Required_claim_missing_rejected:
trap_03_reference_reuse:Duplicate_reference_rejected:
trap_04_float_money:Money_decimal_boundary_no_float:
trap_05_no_dedupe:Replayed_webhook_idempotent:Concurrent_duplicate_applies_once
trap_06_skip_signature:Forged_signature_rejected:
trap_07_trust_body_status:Status_taken_from_token_not_body:
trap_08_no_recency:Stale_timestamp_rejected:
trap_09_downgrade:Terminal_state_not_downgraded:
trap_10_concurrency:Concurrent_duplicate_applies_once:
"

echo "== seeded traps (expect each to redden its mapped test) =="
for spec in $traps; do
  mod=${spec%%:*}; rest=${spec#*:}; tst=${rest%%:*}; allow=${rest#*:}

  # 1) the mapped test MUST go red
  if run "$mod" --filter "FullyQualifiedName~$tst" >/dev/null 2>&1; then
    echo "FAIL: $mod stayed green for $tst"; fail=1
  else
    echo "OK: $mod reddened $tst"
  fi

  # 2) non-foundational traps must leave the OTHER tests green (minus the documented allowlist)
  if [ "$allow" = "EXEMPT" ]; then
    echo "   (exempt from others-green: foundational claim trap)"; continue
  fi
  filter="FullyQualifiedName!~$tst"
  if [ -n "$allow" ]; then
    IFS='|' read -ra extra <<< "$allow"
    for e in "${extra[@]}"; do filter="$filter&FullyQualifiedName!~$e"; done
  fi
  if run "$mod" --filter "$filter" >/dev/null 2>&1; then
    echo "OK: $mod left the other tests green"
  else
    echo "FAIL: $mod reddened an unrelated test"; fail=1
  fi
done

exit $fail
```

- [ ] **Step 2: Make it executable and run it (with dotnet on PATH)**

```bash
chmod +x plugins/payment-contract-tester/reference/xunit/run.sh
export PATH="$HOME/.dotnet:$PATH"
bash plugins/payment-contract-tester/reference/xunit/run.sh; echo "exit=$?"
```
Expected: `OK: correct handler all green`; every trap `OK: … reddened …`; `trap_01` prints the exempt line; every other trap `OK: … left the other tests green`. Final `exit=0`.

- [ ] **Step 3: Verify the SKIP path (no false green when dotnet absent)**

```bash
env -i bash plugins/payment-contract-tester/reference/xunit/run.sh; echo "exit=$?"
```
Expected: `SKIP: dotnet SDK not available` and `exit=0` (empty env → no `dotnet` on PATH).

- [ ] **Step 4: Wire the xUnit suite into `tests/run-tests.sh`**

In `plugins/payment-contract-tester/tests/run-tests.sh`, replace the placeholder line:
```bash
# Plan 2: bash "$ROOT/reference/xunit/run.sh" || rc=1
```
with:
```bash
echo "### xunit reference fixtures ###"
bash "$ROOT/reference/xunit/run.sh" || rc=1
```

- [ ] **Step 5: Run the whole self-test orchestrator (dotnet on PATH → both stacks run)**

```bash
export PATH="$HOME/.dotnet:$PATH"
bash plugins/payment-contract-tester/tests/run-tests.sh; echo "exit=$?"
```
Expected: pytest section all-OK, xunit section all-OK, final `ALL SELF-TESTS PASSED`, `exit=0`.

- [ ] **Step 6: Confirm the orchestrator still passes when dotnet is absent (xunit SKIPs, pytest runs)**

```bash
env -i PATH=/usr/bin:/bin bash plugins/payment-contract-tester/tests/run-tests.sh; echo "exit=$?"
```
Expected: pytest section runs and passes, xunit section prints `SKIP: dotnet SDK not available`, final `ALL SELF-TESTS PASSED`, `exit=0`.

- [ ] **Step 7: Update the README**

In `plugins/payment-contract-tester/README.md`:

Change the **Reference fixtures** line (currently "(Python + pytest)"):
```markdown
**Reference fixtures:** Suites of contract tests — **Python + pytest** and **.NET + xUnit** — that run green against correct payment handlers and red against each seeded trap pattern (idempotency violations, signature failures, money-as-string, terminal-state errors, replay acceptance). Each stack mirrors the same 10 traps. Use these to validate your own payment code.
```

Add to the **Dependencies** list (after the `pytest` line), so the self-tests' per-stack runtimes are documented:
```markdown
- `dotnet` (.NET 9 SDK) — required to run the xUnit reference fixtures; the self-test skips this stack cleanly if absent
```

- [ ] **Step 8: Bump the version in BOTH manifests**

In `plugins/payment-contract-tester/.claude-plugin/plugin.json` and root `.claude-plugin/marketplace.json`, change `"version": "0.1.0"` to `"version": "0.1.1"` (the payment-contract-tester entry in the marketplace file).

Verify they match:
```bash
grep -h '"version"' plugins/payment-contract-tester/.claude-plugin/plugin.json
grep -A3 'payment-contract-tester' .claude-plugin/marketplace.json | grep '"version"'
```
Expected: both show `0.1.1`.

- [ ] **Step 9: Commit**

```bash
git add plugins/payment-contract-tester/reference/xunit/run.sh \
        plugins/payment-contract-tester/tests/run-tests.sh \
        plugins/payment-contract-tester/README.md \
        plugins/payment-contract-tester/.claude-plugin/plugin.json \
        .claude-plugin/marketplace.json
git commit -m "feat(payment-contract-tester): wire xUnit self-test, docs, bump 0.1.1

Claude-Session: <session-url>"
```

---

## Self-Review

**Spec coverage (Plan 2 section of the handoff):**
- xUnit fixture mirroring pytest (correct handler + 10 traps + contract suite, env-selected handler, no third-party SDK) → Tasks 2 & 3. ✓
- `run.sh` with `dotnet test --filter` → Task 4 Step 1. ✓
- Extend `tests/run-tests.sh`, SKIP cleanly if `dotnet` absent → Task 4 Steps 3, 4, 6. ✓
- Runner hardening (others-green for non-foundational traps, both stacks), foundational exemption with comment → Task 1 (pytest) + Task 4 (xunit). ✓ *(Refinement: exempt only trap_01, justified by live data; trap_05 allowlist = concurrency test.)*
- Money trap = float / culture ToString; concurrency trap = real race (barrier + lock removal + sleep) → Task 3 Steps 4 & 10. ✓
- Identical 10-trap mapping across stacks → run.sh `traps` tables match line-for-line (modulo test-name casing). ✓

**Placeholder scan:** every code/step is concrete; no TBD/TODO-in-plan. ✓

**Type consistency:** `IPaymentHandler` / `IStore` signatures, `MockStore` field names (`Orders`/`Processed`/`Effects`/`Lock`), `JwtMini` method names, the 10 `[Fact]` names, and the env keys are used identically across CorrectHandler, the trap edits, the factory, ContractTests, and both run.sh tables. ✓

**Out of scope (Plan 2):** `/scaffold`, CI/hook harness, gateways beyond the three — none touched. ✓
