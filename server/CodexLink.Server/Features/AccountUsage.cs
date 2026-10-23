using System.Text.Json.Nodes;
using CodexLink.Server.Codex;

namespace CodexLink.Server.Features;

public sealed class AccountUsage
{
    private readonly CodexRpc _rpc;
    private readonly Configuration _configuration;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _state = new();
    private long _accountVersion;
    private long _limitsVersion;
    private string? _tokensError;
    private string? _limitsError;
    private JsonNode? _account;
    private JsonNode? _tokens;
    private JsonNode? _limits;
    private DateTimeOffset? _tokensAt;
    private DateTimeOffset? _limitsAt;
    private DateTimeOffset _fetchedAt;

    public AccountUsage(CodexRpc rpc, Configuration configuration)
    {
        _rpc = rpc; _configuration = configuration;
        rpc.Notification += (method, payload) =>
        {
            lock (_state)
            {
                if (method == "account/updated")
                {
                    _accountVersion++;
                    _account = null; _tokens = null; _limits = null;
                    _tokensAt = null; _limitsAt = null; _fetchedAt = default;
                    _tokensError = null; _limitsError = null;
                }
                else if (method == "account/rateLimits/updated")
                {
                    _limitsVersion++;
                    _limits = payload.Copy(); _limitsAt = DateTimeOffset.UtcNow;
                    _limitsError = null;
                }
            }
        };
    }

    public async Task<JsonObject> ReadAsync(bool refresh, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            bool fetch;
            long version, limitsVersion;
            lock (_state)
            {
                fetch = _account is null || (DateTimeOffset.UtcNow - _fetchedAt).TotalSeconds >= (refresh ? 5 : 60);
                version = _accountVersion; limitsVersion = _limitsVersion;
            }
            if (fetch)
            {
                var account = await _rpc.CallAsync("account/read", Json.Object(("refreshToken", false)), cancellationToken);
                lock (_state)
                {
                    if (version != _accountVersion) throw new ApiException(409, "account_changed", "账号已改变，请刷新用量。");
                    if (Json.Compact(account ?? new JsonObject()) != Json.Compact(_account ?? new JsonObject()))
                    { _tokens = null; _limits = null; _tokensAt = null; _limitsAt = null; }
                    _account = account.Copy();
                }
                JsonNode? tokens = null, limits = null;
                string? tokensError = null, limitsError = null;
                try { tokens = await _rpc.CallAsync("account/usage/read", null, cancellationToken); }
                catch (ApiException exception) { tokensError = exception.Message; }
                try { limits = await _rpc.CallAsync("account/rateLimits/read", null, cancellationToken); }
                catch (ApiException exception) { limitsError = exception.Message; }
                lock (_state)
                {
                    if (version != _accountVersion) throw new ApiException(409, "account_changed", "账号已改变，请刷新用量。");
                    _tokensError = tokensError;
                    if (tokensError is null) { _tokens = tokens; _tokensAt = DateTimeOffset.UtcNow; }
                    if (limitsVersion == _limitsVersion)
                    {
                        _limitsError = limitsError;
                        if (limitsError is null) { _limits = limits; _limitsAt = DateTimeOffset.UtcNow; }
                    }
                    _fetchedAt = DateTimeOffset.UtcNow;
                }
            }
            var zone = TimeZoneInfo.FindSystemTimeZoneById(_configuration.Value.TimeZone);
            lock (_state)
            {
                return Json.Object(("account", _account.Copy()), ("tokens", _tokens.Copy()), ("rateLimits", _limits.Copy()),
                    ("tokensUpdatedAt", _tokensAt?.ToString("O")), ("limitsUpdatedAt", _limitsAt?.ToString("O")),
                    ("tokensError", _tokensError), ("limitsError", _limitsError), ("timeZone", zone.Id),
                    ("today", TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).ToString("yyyy-MM-dd")));
            }
        }
        finally { _gate.Release(); }
    }
}
