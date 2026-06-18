namespace ContractFixture;

public static class HandlerFactory
{
    public static IPaymentHandler FromEnv()
    {
        var name = Environment.GetEnvironmentVariable("PCT_HANDLER") ?? "correct";
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
    }
}
