using System.Reflection;
using Microsoft.AspNetCore.StaticFiles;

namespace CodexLink.Server.Web;

public sealed class EmbeddedWeb
{
    private const string Prefix = "CodexLink.Web/";
    private readonly Assembly _assembly = typeof(EmbeddedWeb).Assembly;
    private readonly Dictionary<string, string> _resources;
    private readonly FileExtensionContentTypeProvider _types = new();
    public EmbeddedWeb()
    {
        _resources = _assembly.GetManifestResourceNames().Where(n => n.StartsWith(Prefix, StringComparison.Ordinal))
            .ToDictionary(n => n[Prefix.Length..].Replace('\\', '/'), n => n, StringComparer.Ordinal);
        _types.Mappings[".wasm"] = "application/wasm";
    }
    public async Task ServeAsync(HttpContext context)
    {
        var path = context.Request.Path.Value?.TrimStart('/') ?? "";
        if (path.StartsWith("api/", StringComparison.Ordinal) || context.Request.Method is not ("GET" or "HEAD"))
        { context.Response.StatusCode = 404; return; }
        if (path.Length == 0 || !Path.HasExtension(path)) path = "index.html";
        if (!_resources.TryGetValue(path, out var resource)) { context.Response.StatusCode = 404; return; }
        var stream = _assembly.GetManifestResourceStream(resource)!;
        context.Response.Headers.CacheControl = Path.GetFileName(path) is "index.html" or "flutter_bootstrap.js" or "flutter_service_worker.js" or "main.dart.js" or "flutter.js" or "version.json" or "manifest.json"
            ? "no-cache" : "public,max-age=3600";
        var type = _types.TryGetContentType(path, out var value) ? value : "application/octet-stream";
        await Results.Stream(stream, type, enableRangeProcessing: true).ExecuteAsync(context);
    }
}
