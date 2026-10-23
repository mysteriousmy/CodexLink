using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace CodexLink.Server.Realtime;

public sealed class EventHub(IHostApplicationLifetime application)
{
    private sealed record Frame(long Seq, DateTimeOffset At, byte[] Bytes);
    private readonly object _gate = new();
    private readonly Queue<Frame> _history = new();
    private sealed class Subscriber
    {
        public CancellationTokenSource Stop { get; } = new();
        public Channel<byte[]> Queue { get; } = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(512) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
        public int Bytes;
        public bool Enqueue(byte[] data)
        {
            if (Bytes + data.Length > 4 * 1024 * 1024 || !Queue.Writer.TryWrite(data)) return false;
            Bytes += data.Length;
            return true;
        }
    }
    private readonly HashSet<Subscriber> _subscribers = [];
    private long _sequence;
    private int _bytes;
    public string Epoch { get; } = Guid.NewGuid().ToString("N");
    public long Sequence { get { lock (_gate) return _sequence; } }

    public void Publish(string method, JsonNode? parameters)
    {
        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            var data = Encoding.UTF8.GetBytes(Json.Compact(Json.Object(("epoch", Epoch), ("seq", ++_sequence),
                ("method", method), ("params", parameters.Copy()))));
            _history.Enqueue(new(_sequence, now, data));
            _bytes += data.Length;
            while (_history.Count > 0 && (_bytes > 8 * 1024 * 1024 || now - _history.Peek().At > TimeSpan.FromMinutes(5)))
                _bytes -= _history.Dequeue().Bytes.Length;
            foreach (var queue in _subscribers.ToArray())
                if (!queue.Enqueue(data))
                {
                    queue.Queue.Writer.TryComplete(new IOException("Slow consumer: resync required."));
                    queue.Stop.Cancel();
                    _subscribers.Remove(queue);
                }
        }
    }

    public async Task ConnectAsync(HttpContext context)
    {
        if (!context.WebSockets.IsWebSocketRequest) throw new ApiException(400, "websocket_required", "需要 WebSocket 连接。");
        using var socket = await context.WebSockets.AcceptWebSocketAsync();
        var subscriber = new Subscriber();
        var channel = subscriber.Queue;
        var epoch = context.Request.Query["epoch"].ToString();
        _ = long.TryParse(context.Request.Query["after"], out var after);
        lock (_gate)
        {
            var frames = _history.Where(f => f.Seq > after).ToArray();
            var canReplay = epoch == Epoch && after <= _sequence &&
                (_history.Count == 0 ? after == _sequence : after >= _history.Peek().Seq - 1) && frames.Length < 480 && frames.Sum(f => (long)f.Bytes.Length) < 4 * 1024 * 1024 - 4096;
            subscriber.Enqueue(Encoding.UTF8.GetBytes(Json.Compact(Json.Object(("epoch", Epoch), ("seq", _sequence),
                ("method", canReplay ? "stream/replay" : "stream/resync"), ("params", new JsonObject())))));
            if (canReplay) foreach (var frame in frames) subscriber.Enqueue(frame.Bytes);
            subscriber.Enqueue(Encoding.UTF8.GetBytes(Json.Compact(Json.Object(("epoch", Epoch), ("seq", _sequence),
                ("method", "stream/ready"), ("params", new JsonObject())))));
            _subscribers.Add(subscriber);
        }
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted, application.ApplicationStopping, subscriber.Stop.Token);
        async Task SendAsync()
        {
            await foreach (var bytes in channel.Reader.ReadAllAsync(lifetime.Token))
            {
                lock (_gate) subscriber.Bytes -= bytes.Length;
                await socket.SendAsync(bytes, WebSocketMessageType.Text, true, lifetime.Token);
            }
        }
        async Task ReceiveAsync()
        {
            var buffer = new byte[4096];
            while (!lifetime.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, lifetime.Token);
                if (result.MessageType == WebSocketMessageType.Close) return;
                if (!result.EndOfMessage) throw new IOException("Client message too large.");
                // Browser heartbeats travel through the same bounded writer as event frames.
                lock (_gate) if (!subscriber.Enqueue(Encoding.UTF8.GetBytes("{\"method\":\"stream/pong\"}"))) return;
            }
        }
        var send = SendAsync();
        var receive = ReceiveAsync();
        try { await await Task.WhenAny(send, receive); }
        catch (Exception e) when (e is OperationCanceledException or WebSocketException or IOException or ChannelClosedException) { }
        finally
        {
            lifetime.Cancel();
            lock (_gate) _subscribers.Remove(subscriber);
            channel.Writer.TryComplete();
            socket.Abort();
            try { await Task.WhenAll(send, receive); }
            catch (Exception e) when (e is OperationCanceledException or WebSocketException or IOException or ChannelClosedException) { }
            subscriber.Stop.Dispose();
        }
    }
}
