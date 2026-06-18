using System.Text;
using System.Text.Json;

namespace ContractFixture;

/// <summary>SEEDED TRAP: claim-shape — renamed claim key (snake_case) breaks receiver lookup.</summary>
public sealed class Trap01ClaimShape : IPaymentHandler
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
            ["merchant_reference"] = reference,   // SEEDED TRAP: renamed claim key breaks receiver lookup
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
