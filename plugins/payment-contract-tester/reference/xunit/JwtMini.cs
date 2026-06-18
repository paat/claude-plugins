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
