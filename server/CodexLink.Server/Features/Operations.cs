using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace CodexLink.Server.Features;

public sealed class Operations
{
    private sealed record Entry(string Fingerprint, DateTimeOffset CreatedAt, Task<JsonNode?> Task);
    private readonly Dictionary<string, Entry> _entries = new();
    private readonly object _gate = new();

    public Task<JsonNode?> RunAsync(string device, string id, string fingerprint, Func<Task<JsonNode?>> operation)
    {
        if (!Guid.TryParse(id, out _)) throw new ApiException(400, "invalid_request_id", "消息需要有效的 requestId。");
        var key = device + ":" + id;
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(fingerprint)));
        lock (_gate)
        {
            if (_entries.TryGetValue(key, out var existing))
            {
                if (existing.Fingerprint != hash) throw new ApiException(409, "request_id_conflict", "相同 requestId 不能用于不同消息。");
                return existing.Task;
            }
            foreach (var expired in _entries.Where(e => e.Value.Task.IsCompleted && DateTimeOffset.UtcNow - e.Value.CreatedAt > TimeSpan.FromMinutes(30)).Select(e => e.Key).ToArray()) _entries.Remove(expired);
            if (_entries.Count >= 1024) throw new ApiException(429, "operation_capacity", "短时间内请求过多，请稍后再试。");
            var completion = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
            _entries[key] = new(hash, DateTimeOffset.UtcNow, completion.Task);
            _ = CompleteAsync(completion, operation);
            return completion.Task;
        }
    }
    private static async Task CompleteAsync(TaskCompletionSource<JsonNode?> completion, Func<Task<JsonNode?>> operation)
    {
        try { completion.TrySetResult(await operation()); }
        catch (Exception exception) { completion.TrySetException(exception); }
    }
    public JsonObject Read(string device, string id)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(device + ":" + id, out var entry)) return Json.Object(("state", "unknown"));
            if (!entry.Task.IsCompleted) return Json.Object(("state", "pending"));
            if (entry.Task.IsCompletedSuccessfully) return Json.Object(("state", "accepted"), ("result", entry.Task.GetAwaiter().GetResult().Copy()));
            if (entry.Task.Exception?.InnerException is ApiException { Code: "rpc_timeout" or "codex_disconnected" })
                return Json.Object(("state", "unknown"), ("message", "Codex 结果未知，请检查最新会话。"));
            return Json.Object(("state", "failed"), ("message", entry.Task.Exception?.InnerException?.Message ?? "操作未完成"));
        }
    }
}
