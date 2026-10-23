using System.Security.Cryptography;

namespace CodexLink.Server.Security;

public sealed class DeviceAuth(Configuration configuration)
{
    public const string CookieName = "codexlink_session";
    private readonly Dictionary<string, (int Count, DateTimeOffset Start)> _loginAttempts = new();
    private readonly object _gate = new();

    public DeviceConfig? Authenticate(string? token)
    {
        if (string.IsNullOrEmpty(token) || token.Length > 256) return null;
        var hash = Convert.FromHexString(Configuration.HashToken(token));
        return configuration.Value.Devices.FirstOrDefault(d => CryptographicOperations.FixedTimeEquals(hash, Convert.FromHexString(d.TokenHash)));
    }

    public DeviceConfig? Authenticate(HttpContext context)
    {
        var header = context.Request.Headers.Authorization.ToString();
        return Authenticate(header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? header[7..] : context.Request.Cookies[CookieName]);
    }

    public void CheckOrigin(HttpContext context)
    {
        var origin = context.Request.Headers.Origin.ToString();
        var bearer = context.Request.Headers.Authorization.ToString().StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase);
        var isWrite = context.Request.Method is not ("GET" or "HEAD" or "OPTIONS");
        if (origin.Length == 0)
        {
            if (!bearer && (isWrite || context.WebSockets.IsWebSocketRequest))
                throw new ApiException(403, "origin_required", "浏览器请求缺少来源信息。");
            return;
        }
        var allowed = configuration.Value.PublicOrigin ?? $"{context.Request.Scheme}://{context.Request.Host}";
        if (!string.Equals(origin.TrimEnd('/'), allowed.TrimEnd('/'), StringComparison.OrdinalIgnoreCase))
            throw new ApiException(403, "origin_rejected", "请求来源与服务配置不匹配。");
    }

    public void CheckLoginRate(HttpContext context)
    {
        var key = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        var now = DateTimeOffset.UtcNow;
        lock (_gate)
        {
            foreach (var old in _loginAttempts.Where(x => now - x.Value.Start > TimeSpan.FromMinutes(1)).Select(x => x.Key).ToArray()) _loginAttempts.Remove(old);
            if (_loginAttempts.Count >= 1024 && !_loginAttempts.ContainsKey(key)) throw new ApiException(429, "login_rate_limit", "请稍后再试。");
            var attempt = _loginAttempts.GetValueOrDefault(key, (0, now));
            if (attempt.Item1 >= 10) throw new ApiException(429, "login_rate_limit", "登录尝试过于频繁，请一分钟后重试。");
            _loginAttempts[key] = (attempt.Item1 + 1, attempt.Item2);
        }
    }
}
