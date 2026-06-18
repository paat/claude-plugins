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
