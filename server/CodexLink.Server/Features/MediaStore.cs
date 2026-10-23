using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace CodexLink.Server.Features;

// A bounded, regenerable preview cache. Codex remains the history source.
// Large encoded images never enter the WebSocket replay buffer or Flutter text.
public sealed class MediaStore
{
    private readonly string _directory;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private const long MaxBytes = 512L * 1024 * 1024;
    public MediaStore(Configuration config)
    {
        _directory = Path.Combine(config.DataDirectory, "media");
        Directory.CreateDirectory(_directory);
        Clean(0);
    }

    public string Get(string id)
    {
        if (id.Length != 64 || id.Any(c => !char.IsAsciiHexDigit(c))) throw new ApiException(404, "media_missing", "预览不存在。");
        var file = Path.Combine(_directory, id);
        if (!File.Exists(file)) throw new ApiException(404, "media_expired", "预览缓存已清理，请重新同步会话。");
        return file;
    }

    public async Task ProjectAsync(string threadId, JsonObject item, CancellationToken ct)
    {
        try
        {
            var type = item.String("type");
            if (type == "imageGeneration")
            {
                var encoded = item.String("result") ?? "";
                item["result"] = "";
                if (encoded.Length > 0)
                    item["media"] = await SaveAsync(threadId, item.String("id")!, encoded, null, ct);
                else if (item.String("savedPath") is { } saved && File.Exists(saved))
                    item["media"] = await SaveAsync(threadId, item.String("id")!, null, saved, ct);
            }
            else if (type == "imageView" && item.String("path") is { } path)
                item["media"] = await SaveAsync(threadId, item.String("id")!, null, path, ct);
            else if (type == "mcpToolCall" && item["result"]?["content"] is JsonArray content)
            {
                var index = 0;
                foreach (var part in content.OfType<JsonObject>())
                {
                    if (part.String("type") != "image" || part.String("data") is not { } encoded) continue;
                    part.Remove("data");
                    part["media"] = await SaveAsync(threadId, item.String("id") + ":" + index++, encoded, null, ct);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException or ApiException)
        {
            item["mediaError"] = "图片无法预览：文件已失效、格式不支持或超过 32 MiB。";
        }
    }

    private async Task<JsonObject> SaveAsync(string threadId, string itemId, string? encoded, string? source, CancellationToken ct)
    {
        if (encoded?.StartsWith("data:", StringComparison.Ordinal) == true) encoded = encoded[(encoded.IndexOf(',') + 1)..];
        if (encoded is { Length: > 45 * 1024 * 1024 }) throw new IOException("Media exceeds limit.");
        var fingerprint = encoded is null ? source + ":" + File.GetLastWriteTimeUtc(source!).Ticks
            : Convert.ToHexString(SHA256.HashData(MemoryMarshal.AsBytes(encoded.AsSpan())));
        var id = Configuration.HashToken(threadId + ":" + itemId + ":" + fingerprint);
        var target = Path.Combine(_directory, id);
        await _gate.WaitAsync(ct);
        try
        {
            byte[] header;
            if (!File.Exists(target))
            {
                var bytes = encoded is null ? await ReadFileAsync(source!, ct) : Convert.FromBase64String(encoded);
                if (bytes.Length > 32 * 1024 * 1024) throw new IOException("Media exceeds limit.");
                _ = Detect(bytes, source);
                Clean(bytes.Length);
                var temp = target + ".tmp";
                try { await File.WriteAllBytesAsync(temp, bytes, ct); File.Move(temp, target, true); }
                finally { if (File.Exists(temp)) File.Delete(temp); }
                header = bytes;
            }
            else
            {
                header = new byte[Math.Min(512, new FileInfo(target).Length)];
                await using var stream = File.OpenRead(target);
                await stream.ReadExactlyAsync(header, ct);
            }
            var contentType = Detect(header, source);
            var extension = contentType switch { "image/jpeg" => "jpg", "image/svg+xml" => "svg", "image/webp" => "webp", "image/gif" => "gif", _ => "png" };
            return Json.Object(("id", id), ("name", "codex-" + id[..8] + "." + extension), ("contentType", contentType));
        }
        finally { _gate.Release(); }
    }

    private static async Task<byte[]> ReadFileAsync(string path, CancellationToken ct)
    {
        if (new FileInfo(path).Length > 32 * 1024 * 1024) throw new IOException("Media exceeds limit.");
        return await File.ReadAllBytesAsync(path, ct);
    }

    public static string Detect(ReadOnlySpan<byte> bytes, string? name = null)
    {
        if (bytes.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return "image/png";
        if (bytes.StartsWith(new byte[] { 255, 216, 255 })) return "image/jpeg";
        if (bytes.StartsWith("GIF8"u8)) return "image/gif";
        if (bytes.Length >= 12 && bytes.StartsWith("RIFF"u8) && bytes.Slice(8, 4).SequenceEqual("WEBP"u8)) return "image/webp";
        if (name?.EndsWith(".svg", StringComparison.OrdinalIgnoreCase) == true || System.Text.Encoding.UTF8.GetString(bytes[..Math.Min(bytes.Length, 512)]).Contains("<svg", StringComparison.Ordinal)) return "image/svg+xml";
        throw new IOException("Unsupported image format.");
    }

    private void Clean(long incoming)
    {
        var files = new DirectoryInfo(_directory).GetFiles().OrderBy(f => f.LastWriteTimeUtc).ToArray();
        var total = files.Sum(f => f.Length) + incoming;
        var count = files.Length;
        foreach (var file in files)
        {
            if (total <= MaxBytes && count < 512 && DateTime.UtcNow - file.LastWriteTimeUtc < TimeSpan.FromDays(1)) break;
            total -= file.Length; count--; file.Delete();
        }
    }
}
