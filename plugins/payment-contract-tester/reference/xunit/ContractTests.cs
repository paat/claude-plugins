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
        foreach (var missing in new[] { "merchantReference", "paymentStatus", "uuid" })
        {
            var claims = new Dictionary<string, object?>
            {
                ["accessKey"] = "ak", ["uuid"] = "e1", ["merchantReference"] = "REF-1",
                ["paymentStatus"] = "PAID", ["exp"] = NOW + 600, ["iat"] = NOW,
            };
            claims.Remove(missing);
            var tok = JwtMini.Encode(claims, H.Secret);
            var s = Fresh();
            Assert.Equal(400, H.HandleWebhook(s, Wh(tok), NOW));
        }
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
