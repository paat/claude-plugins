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
