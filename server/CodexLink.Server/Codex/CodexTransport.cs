using System.Diagnostics;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace CodexLink.Server.Codex;

// stdio owns its child process; a shared connection owns only its socket.
internal abstract class CodexTransport : IAsyncDisposable
{
    public abstract bool Shared { get; }
    public abstract ValueTask<string?> ReceiveAsync(CancellationToken cancellationToken);
    public abstract ValueTask SendAsync(string message, CancellationToken cancellationToken);
    public abstract void Stop();
    public abstract ValueTask DisposeAsync();

    public static async Task<string?> DiscoverSocketAsync(GatewayConfig config, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(config.CodexSocketPath)) return Path.GetFullPath(config.CodexSocketPath);
        if (!config.PreferSharedDaemon || !config.CodexArguments.SequenceEqual(["app-server", "--listen", "stdio://"])) return null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        using var process = new Process { StartInfo = StartInfo(config.CodexPath, ["app-server", "daemon", "version"], Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) };
        try
        {
            process.Start();
            var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errors = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            var text = await output;
            await errors;
            if (process.ExitCode != 0) return null;
            var result = JsonNode.Parse(text);
            return result.String("status") == "running" ? result.String("socketPath") : null;
        }
        catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception or System.Text.Json.JsonException or OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            cancellationToken.ThrowIfCancellationRequested();
            return null;
        }
    }

    public static async Task<CodexTransport> OpenAsync(GatewayConfig config, string? socketPath, CancellationToken cancellationToken)
    {
        if (socketPath is null)
            return new StdioTransport(Process.Start(StartInfo(config.CodexPath, config.CodexArguments, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)))
                ?? throw new IOException("Cannot start Codex."));
        var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            ConnectCallback = async (_, ct) =>
            {
                var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                try
                {
                    await socket.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), ct);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch { socket.Dispose(); throw; }
            }
        };
        var invoker = new HttpMessageInvoker(handler);
        var webSocket = new ClientWebSocket();
        webSocket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        webSocket.Options.KeepAliveTimeout = TimeSpan.FromSeconds(20);
        try
        {
            await webSocket.ConnectAsync(new Uri("ws://localhost/rpc"), invoker, cancellationToken);
            return new SharedTransport(webSocket, invoker);
        }
        catch { webSocket.Dispose(); invoker.Dispose(); throw; }
    }

    private static ProcessStartInfo StartInfo(string path, string[] arguments, string cwd)
    {
        var start = new ProcessStartInfo(path)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            UseShellExecute = false, WorkingDirectory = cwd,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return start;
    }

    private sealed class StdioTransport(Process process) : CodexTransport
    {
        private readonly Task _stderr = DrainErrorsAsync(process);
        public override bool Shared => false;
        public override ValueTask<string?> ReceiveAsync(CancellationToken cancellationToken) => process.StandardOutput.ReadLineAsync(cancellationToken);
        public override async ValueTask SendAsync(string message, CancellationToken cancellationToken)
        {
            await process.StandardInput.WriteLineAsync(message.AsMemory(), cancellationToken);
            await process.StandardInput.FlushAsync(cancellationToken);
        }
        public override void Stop()
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        }
        public override async ValueTask DisposeAsync()
        {
            Stop();
            try { await _stderr; } catch (IOException) { }
            process.Dispose();
        }
        private static async Task DrainErrorsAsync(Process child)
        {
            // stderr can contain prompts and tool output; never copy it into logs.
            var buffer = new char[4096];
            while (await child.StandardError.ReadAsync(buffer.AsMemory()) != 0) { }
        }
    }

    private sealed class SharedTransport(ClientWebSocket socket, HttpMessageInvoker invoker) : CodexTransport
    {
        private readonly byte[] _buffer = new byte[64 * 1024];
        public override bool Shared => true;
        public override async ValueTask<string?> ReceiveAsync(CancellationToken cancellationToken)
        {
            using var message = new MemoryStream();
            ValueWebSocketReceiveResult frame;
            do
            {
                frame = await socket.ReceiveAsync(_buffer.AsMemory(), cancellationToken);
                if (frame.MessageType == WebSocketMessageType.Close) return null;
                if (frame.MessageType != WebSocketMessageType.Text || message.Length + frame.Count > 64 * 1024 * 1024)
                    throw new IOException("Invalid Codex WebSocket frame.");
                message.Write(_buffer, 0, frame.Count);
            } while (!frame.EndOfMessage);
            return Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
        }
        public override ValueTask SendAsync(string message, CancellationToken cancellationToken) =>
            socket.SendAsync(Encoding.UTF8.GetBytes(message).AsMemory(), WebSocketMessageType.Text, true, cancellationToken);
        public override void Stop() => socket.Abort();
        public override ValueTask DisposeAsync()
        {
            socket.Dispose();
            invoker.Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
