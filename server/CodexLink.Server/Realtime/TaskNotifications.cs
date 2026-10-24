using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Threading.Channels;
using CodexLink.Server.Codex;

namespace CodexLink.Server.Realtime;

/// <summary>A turn result or question reminder; never includes answers or reply text.</summary>
public sealed record TaskNotice(long Sequence, string Id, string ThreadId, string TurnId, string Status, DateTimeOffset CompletedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? QuestionId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Preview = null);
/// <summary>A bounded completion history and the cursor for subsequent delivery.</summary>
public sealed record TaskNoticeBatch(string Epoch, long Cursor, bool Reset, bool Gap, bool Durable, TaskNotice[] Items);
/// <summary>Gateway-owned notification metadata retained across normal restarts.</summary>
public sealed record TaskNoticeJournal(string Epoch, long Cursor, TaskNotice[] Items, long? DiscardedThrough = null);

public sealed partial class TaskNotifications(Configuration config, CodexRpc rpc, ILogger<TaskNotifications> logger,
    IHostApplicationLifetime lifetime) : BackgroundService
{
    private const int Capacity = 256;
    private static readonly TimeSpan Retention = TimeSpan.FromDays(7);
    private readonly object _gate = new();
    private readonly List<TaskNotice> _history = [];
    private readonly Channel<bool> _dirty = Channel.CreateBounded<bool>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
    private TaskCompletionSource _changed = NewSignal();
    private string _epoch = Guid.NewGuid().ToString("N");
    private long _sequence;
    private long _persistedSequence;
    private long _discardedThrough;
    private bool _durable = true;
    private string JournalPath => Path.Combine(config.DataDirectory, "notifications.json");
    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    public override async Task StartAsync(CancellationToken cancellationToken)
    {
        if (File.Exists(JournalPath))
        {
            try
            {
                await using var stream = File.OpenRead(JournalPath);
                var journal = await JsonSerializer.DeserializeAsync(stream, JsonContext.Default.TaskNoticeJournal, cancellationToken)
                    ?? throw new JsonException("Empty notification journal.");
                if (!Guid.TryParseExact(journal.Epoch, "N", out _) || journal.Cursor < 0 || journal.DiscardedThrough < 0 || journal.DiscardedThrough > journal.Cursor || journal.Items is null || journal.Items.Length > Capacity ||
                    journal.Items.Any(n => n is null || n.Sequence <= 0 || n.Sequence > journal.Cursor ||
                        string.IsNullOrEmpty(n.ThreadId) || n.ThreadId.Length > 256 ||
                        string.IsNullOrEmpty(n.TurnId) || n.TurnId.Length > 256 ||
                        !ValidNotice(n)))
                    throw new JsonException("Invalid notification journal.");
                _epoch = journal.Epoch;
                _sequence = journal.Cursor;
                _persistedSequence = journal.Cursor;
                _history.AddRange(journal.Items.OrderBy(n => n.Sequence));
                _discardedThrough = journal.DiscardedThrough ?? (_history.Count == 0 ? 0 : _history[0].Sequence - 1);
            }
            catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
            {
                // A changed epoch explicitly tells existing clients that their
                // old cursor can no longer recover all offline completions.
                _durable = false;
                logger.LogError("Notification journal could not be loaded ({Kind}); previous delivery history is unavailable.", e.GetType().Name);
            }
        }
        // Native request IDs belong to the previous RPC connection. Async
        // questions remain answerable from the saved conversation history.
        lock (_gate) ResolveQuestions(n => n.QuestionId!.StartsWith("native:", StringComparison.Ordinal));
        rpc.Notification += Capture;
        await base.StartAsync(cancellationToken);
    }

    private void Capture(string method, JsonNode? parameters)
    {
        lock (_gate) CaptureQuestions(method, parameters);
        if (method != "turn/completed") return;
        var thread = parameters.String("threadId");
        var turn = parameters?["turn"].String("id");
        var status = parameters?["turn"].String("status");
        if (string.IsNullOrEmpty(thread) || string.IsNullOrEmpty(turn) || thread.Length > 256 || turn.Length > 256 ||
            status is not ("completed" or "failed")) return;
        var id = thread + ":" + turn;
        lock (_gate)
        {
            if (_history.Any(n => n.Id == id)) return;
            var now = DateTimeOffset.UtcNow;
            AddNotice(new(++_sequence, id, thread, turn, status, now));
        }
    }

    public TaskNoticeBatch Read(string? epoch, long? after)
    {
        if (after < 0) throw new ApiException(400, "invalid_notification_cursor", "通知游标无效。");
        lock (_gate)
        {
            var retained = _history.Where(n => DateTimeOffset.UtcNow - n.CompletedAt <= Retention).ToArray();
            var reset = after is null || epoch != _epoch || after > _sequence;
            var discarded = Math.Max(_discardedThrough, _history.Where(n => DateTimeOffset.UtcNow - n.CompletedAt > Retention).Select(n => n.Sequence).DefaultIfEmpty(0).Max());
            var gap = after is not null && (reset ? after > 0 : after < discarded);
            return new(_epoch, _sequence, reset, gap, _durable && _persistedSequence == _sequence,
                reset ? [] : retained.Where(n => n.Sequence > after).ToArray());
        }
    }

    public async Task StreamAsync(HttpContext context)
    {
        var epoch = context.Request.Query["epoch"].ToString();
        long? cursor = null;
        if (context.Request.Query.TryGetValue("after", out var after))
        {
            if (!long.TryParse(after, out var value) || value < 0)
                throw new ApiException(400, "invalid_notification_cursor", "通知游标无效。");
            cursor = value;
        }
        // EventSource sends this header automatically when its TCP connection
        // reconnects; it is a cursor only, never an authentication credential.
        var lastId = context.Request.Headers["Last-Event-ID"].ToString();
        if (lastId.Length > 0)
        {
            var parts = lastId.Split(':', 2);
            if (parts.Length != 2 || !Guid.TryParseExact(parts[0], "N", out _) || !long.TryParse(parts[1], out var value) || value < 0)
                throw new ApiException(400, "invalid_notification_cursor", "通知游标无效。");
            epoch = parts[0];
            cursor = value;
        }
        context.Response.ContentType = "text/event-stream; charset=utf-8";
        context.Response.Headers.CacheControl = "no-cache, no-transform";
        context.Response.Headers["X-Accel-Buffering"] = "no";
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted, lifetime.ApplicationStopping);
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var batch = Read(epoch, cursor);
                foreach (var item in batch.Items)
                    await WriteFrameAsync(context, item.QuestionId is null ? "task" : "question", batch.Epoch + ":" + item.Sequence,
                        JsonSerializer.Serialize(item, JsonContext.Default.TaskNotice), stop.Token);
                await WriteFrameAsync(context, "ready", batch.Epoch + ":" + batch.Cursor,
                    JsonSerializer.Serialize(batch with { Items = [] }, JsonContext.Default.TaskNoticeBatch), stop.Token);
                epoch = batch.Epoch;
                cursor = batch.Cursor;
                Task changed;
                lock (_gate) changed = _sequence != cursor ? Task.CompletedTask : _changed.Task;
                try { await changed.WaitAsync(TimeSpan.FromSeconds(20), stop.Token); }
                catch (TimeoutException) { } // SSE ready frame is also the keepalive.
            }
        }
        catch (Exception e) when (e is OperationCanceledException or IOException or TimeoutException) { }
    }

    private static async Task WriteFrameAsync(HttpContext context, string kind, string id, string json, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        await context.Response.WriteAsync($"event: {kind}\nid: {id}\ndata: {json}\n\n", timeout.Token);
        await context.Response.Body.FlushAsync(timeout.Token);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var _ in _dirty.Reader.ReadAllAsync(stoppingToken))
        {
            TaskNoticeJournal journal;
            lock (_gate) journal = new(_epoch, _sequence, _history.ToArray(), _discardedThrough);
            try
            {
                await Configuration.WritePrivateAsync(JournalPath, JsonSerializer.Serialize(journal, JsonContext.Default.TaskNoticeJournal));
                lock (_gate) { _durable = true; _persistedSequence = journal.Cursor; }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                lock (_gate) _durable = false;
                logger.LogError("Notification journal could not be saved ({Kind}); delivery remains live but restart recovery is unavailable.", e.GetType().Name);
                await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken);
                _dirty.Writer.TryWrite(true);
            }
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        rpc.Notification -= Capture;
        _dirty.Writer.TryComplete();
        await base.StopAsync(cancellationToken);
        TaskNoticeJournal journal;
        lock (_gate) journal = new(_epoch, _sequence, _history.ToArray(), _discardedThrough);
        try { await Configuration.WritePrivateAsync(JournalPath, JsonSerializer.Serialize(journal, JsonContext.Default.TaskNoticeJournal)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { logger.LogError("Final notification journal could not be saved ({Kind}).", e.GetType().Name); }
    }
}
