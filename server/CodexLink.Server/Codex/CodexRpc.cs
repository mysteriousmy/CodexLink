using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text.Json.Nodes;
using CodexLink.Server.Realtime;
using CodexLink.Server.Features;

namespace CodexLink.Server.Codex;

public sealed class CodexRpc(Configuration configuration, EventHub events, MediaStore media, ILogger<CodexRpc> logger, IHostApplicationLifetime lifetime) : BackgroundService
{
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonNode?>> _pending = new();
    private readonly ConcurrentDictionary<string, JsonObject> _approvals = new();
    private readonly Dictionary<string, int> _textOffsets = new();
    private readonly SemaphoreSlim _write = new(1, 1);
    private CodexTransport? _transport;
    public bool Shared { get; private set; }
    private long _id;
    private volatile bool _ready;
    public bool Ready => _ready;
    public string State { get; private set; } = "starting";
    public string? Version { get; private set; }
    public event Action<string, JsonNode?>? Notification;
    public JsonArray Approvals => new(_approvals.Values.Select(x => (JsonNode)x.DeepClone()).ToArray());

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var shutdown = lifetime.ApplicationStopping.Register(() => _transport?.Stop());
        // Choose once. A lost shared connection must reconnect to the same owner,
        // not silently start a competing private writer.
        var socketPath = await CodexTransport.DiscoverSocketAsync(configuration.Value, stoppingToken);
        var failures = 0;
        while (!stoppingToken.IsCancellationRequested && !lifetime.ApplicationStopping.IsCancellationRequested && failures < 5)
        {
            CodexTransport? transport = null;
            Task? reader = null;
            try
            {
                State = "starting";
                transport = await CodexTransport.OpenAsync(configuration.Value, socketPath, stoppingToken);
                _transport = transport;
                Shared = transport.Shared;
                reader = ReadAsync(transport, stoppingToken);
                var result = await CallCoreAsync("initialize", Json.Object(
                    ("clientInfo", Json.Object(("name", "codexlink"), ("version", "0.1.6"))),
                    ("capabilities", Json.Object(("experimentalApi", true)))), stoppingToken);
                Version = result.String("userAgent");
                await WriteAsync(Json.Object(("method", "initialized")), stoppingToken);
                _ready = true;
                State = "ready";
                events.Publish("runtime/ready", Json.Object(("version", Version)));
                await reader;
                throw new IOException("Codex exited.");
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                failures++;
                State = "unavailable";
                logger.LogWarning("Codex runtime stopped ({Kind}), restart attempt {Attempt}/5", exception.GetType().Name, failures);
            }
            finally
            {
                _ready = false;
                _transport = null;
                foreach (var pending in _pending.Values) pending.TrySetException(new ApiException(503, "codex_disconnected", "Codex 连接已断开，操作结果可能未知。"));
                _pending.Clear();
                _approvals.Clear();
                _textOffsets.Clear();
                Notification?.Invoke("runtime/stopped", null);
                events.Publish("runtime/stopped", new JsonObject());
                if (transport is not null)
                {
                    transport.Stop();
                    if (reader is not null)
                    {
                        try { await reader; }
                        catch (Exception e) when (e is IOException or OperationCanceledException or System.Text.Json.JsonException or WebSocketException) { }
                    }
                    await transport.DisposeAsync();
                }
            }
            if (failures < 5)
                try { await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, failures))), stoppingToken); }
                catch (OperationCanceledException) { break; }
        }
    }

    public Task<JsonNode?> CallAsync(string method, JsonNode? parameters, CancellationToken cancellationToken = default)
    {
        if (!Ready) throw new ApiException(503, "codex_unavailable", "Codex 尚未就绪，请检查主机状态。");
        return CallCoreAsync(method, parameters, cancellationToken);
    }

    private async Task<JsonNode?> CallCoreAsync(string method, JsonNode? parameters, CancellationToken cancellationToken)
    {
        if (_pending.Count >= 128) throw new ApiException(429, "rpc_busy", "在途请求过多，请稍后重试。");
        var id = Interlocked.Increment(ref _id);
        var pending = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = pending;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(60));
        try
        {
            await WriteAsync(Json.Object(("id", id), ("method", method), ("params", parameters)), timeout.Token);
            return await pending.Task.WaitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new ApiException(504, "rpc_timeout", "Codex 响应超时；请核对会话状态，不要重复提交任务。"); }
        finally { _pending.TryRemove(id, out _); }
    }

    private async Task WriteAsync(JsonObject message, CancellationToken cancellationToken)
    {
        await _write.WaitAsync(cancellationToken);
        try
        {
            var transport = _transport ?? throw new ApiException(503, "codex_unavailable", "Codex 连接不可用。");
            await transport.SendAsync(Json.Compact(message), cancellationToken);
        }
        finally { _write.Release(); }
    }

    private async Task ReadAsync(CodexTransport transport, CancellationToken cancellationToken)
    {
        // Both transports yield complete JSON values; the RPC projection is shared.
        while (await transport.ReceiveAsync(cancellationToken) is { } line)
        {
            if (line.Length > 64 * 1024 * 1024) throw new IOException("Codex protocol frame exceeds limit.");
            var message = JsonNode.Parse(line)?.AsObject() ?? throw new IOException("Invalid Codex frame.");
            var method = message.String("method");
            if (method is null && message["id"] is JsonValue value && value.TryGetValue<long>(out var id))
            {
                if (_pending.TryRemove(id, out var pending))
                {
                    if (message["error"] is { } error)
                        pending.TrySetException(new ApiException(409, "codex_rpc_error", error.String("message") ?? "Codex 拒绝了操作。"));
                    else pending.TrySetResult(message["result"].Copy());
                }
                continue;
            }
            if (method is null) continue;
            var parameters = message["params"];
            if (method is "item/started" or "item/completed" && parameters?["item"] is JsonObject mediaItem && parameters.String("threadId") is { } mediaThread)
                await media.ProjectAsync(mediaThread, mediaItem, cancellationToken);
            if (parameters?["turn"]?["items"] is JsonArray turnItems && parameters.String("threadId") is { } turnThread)
                foreach (var turnItem in turnItems.OfType<JsonObject>()) await media.ProjectAsync(turnThread, turnItem, cancellationToken);
            // Offsets let reconnecting clients merge buffered deltas with a history snapshot.
            // C# and Dart both count UTF-16 code units here.
            if (method == "item/started" && parameters?["item"] is JsonObject started)
            {
                var key = parameters.String("threadId") + ":" + started.String("id");
                if (_textOffsets.Count >= 2048) _textOffsets.Remove(_textOffsets.Keys.First());
                _textOffsets[key] = (started.String("text") ?? started.String("aggregatedOutput") ?? "").Length;
            }
            if (method is "item/agentMessage/delta" or "item/commandExecution/outputDelta" && parameters is JsonObject deltaParameters)
            {
                var key = parameters.String("threadId") + ":" + parameters.String("itemId");
                if (_textOffsets.TryGetValue(key, out var offset))
                {
                    deltaParameters["clientOffset"] = offset;
                    _textOffsets[key] = offset + (parameters.String("delta")?.Length ?? 0);
                }
            }
            if (message["id"] is { } requestId)
            {
                if (method is "item/commandExecution/requestApproval" or "item/fileChange/requestApproval" or "item/tool/requestUserInput" or "item/permissions/requestApproval")
                {
                    if (_approvals.Count >= 128) throw new IOException("Too many pending approvals.");
                    var key = _approvals.FirstOrDefault(a => JsonNode.DeepEquals(a.Value["rpcId"], requestId)).Key ?? Guid.NewGuid().ToString("N");
                    var approval = Json.Object(("id", key), ("rpcId", requestId.Copy()), ("method", method), ("params", parameters.Copy()));
                    _approvals[key] = approval;
                    events.Publish("approval/requested", approval);
                }
                else if (!Shared) await WriteAsync(Json.Object(("id", requestId.Copy()), ("error", Json.Object(("code", -32601), ("message", "Unsupported client request")))), cancellationToken);
                continue;
            }
            if (method == "serverRequest/resolved")
            {
                foreach (var item in _approvals.Where(a => JsonNode.DeepEquals(a.Value["rpcId"], parameters?["requestId"])).ToArray())
                    if (_approvals.TryRemove(item.Key, out _)) events.Publish("approval/resolved", Json.Object(("id", item.Key)));
            }
            if (method is "turn/completed")
            {
                var threadId = parameters.String("threadId");
                var turnId = parameters?["turn"].String("id");
                foreach (var item in _approvals.Where(x => x.Value["params"].String("threadId") == threadId &&
                    x.Value["params"].String("turnId") == turnId).ToArray())
                    if (_approvals.TryRemove(item.Key, out _)) events.Publish("approval/resolved", Json.Object(("id", item.Key)));
            }
            Notification?.Invoke(method, parameters);
            if (method.StartsWith("thread/", StringComparison.Ordinal) || method.StartsWith("turn/", StringComparison.Ordinal) ||
                method.StartsWith("item/", StringComparison.Ordinal) || method is "account/updated" or "account/rateLimits/updated" or "error")
                events.Publish(method, parameters);
        }
    }

    public async Task AnswerAsync(string id, JsonNode result)
    {
        // Validate before consuming the request. The write lock also prevents two
        // devices from answering the same native request concurrently.
        await _write.WaitAsync();
        try
        {
            if (!_approvals.TryGetValue(id, out var approval)) throw new ApiException(409, "approval_expired", "请求已处理或失效。");
            if (approval.String("method") == "item/tool/requestUserInput") ValidateAnswers(approval["params"], result);
            var transport = _transport ?? throw new ApiException(503, "codex_unavailable", "Codex 连接不可用。");
            if (!_approvals.TryRemove(id, out _)) throw new ApiException(409, "approval_expired", "请求已处理或失效。");
            // A failed write may already have reached Codex; do not offer a blind retry.
            try { await transport.SendAsync(Json.Compact(Json.Object(("id", approval["rpcId"].Copy()), ("result", result))), CancellationToken.None); }
            finally { events.Publish("approval/resolved", Json.Object(("id", id))); }
        }
        finally { _write.Release(); }
    }

    private static void ValidateAnswers(JsonNode? parameters, JsonNode result)
    {
        if (parameters?["questions"] is not JsonArray { Count: > 0 } questions || result["answers"] is not JsonObject answers ||
            answers.Count != questions.Count)
            throw new ApiException(400, "invalid_answers", "请回答每个问题。");
        foreach (var question in questions)
        {
            var questionId = question.String("id");
            if (questionId is null || answers[questionId] is not JsonObject response || response["answers"] is not JsonArray { Count: 1 } values ||
                values[0] is not JsonValue value || !value.TryGetValue<string>(out var answer) ||
                string.IsNullOrWhiteSpace(answer) || answer.Length > 20_000)
                throw new ApiException(400, "invalid_answers", "每个问题需要一个非空回答，最多 20,000 字符。");
            if (question?["options"] is JsonArray { Count: > 0 } options && question?["isOther"]?.GetValue<bool>() != true &&
                !options.Any(o => o.String("label") == answer))
                throw new ApiException(400, "invalid_answers", "请从问题提供的选项中选择回答。");
        }
    }

}
