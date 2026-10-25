using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexLink.Server;
using CodexLink.Server.Codex;
using CodexLink.Server.Features;
using CodexLink.Server.Realtime;
using CodexLink.Server.Security;
using CodexLink.Server.Web;

var configuration = await Configuration.LoadOrManageAsync(args);
if (configuration is null) return;
// Optional external root is only for deliberate frontend development overrides.
var webRoot = Environment.GetEnvironmentVariable("CODEXLINK_WEB_ROOT");
var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = [], WebRootPath = Directory.Exists(webRoot) ? webRoot : null });
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
builder.WebHost.UseUrls(configuration.Value.ListenUrl);
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = Math.Max(1024 * 1024, configuration.Value.MaxFileBytes));
builder.Services.ConfigureHttpJsonOptions(options => options.SerializerOptions.TypeInfoResolverChain.Insert(0, JsonContext.Default));
builder.Services.AddSingleton(configuration);
builder.Services.AddSingleton<DeviceAuth>();
builder.Services.AddSingleton<EventHub>();
builder.Services.AddSingleton<CodexRpc>();
builder.Services.AddSingleton<TaskNotifications>();
builder.Services.AddHostedService(services => services.GetRequiredService<TaskNotifications>());
builder.Services.AddHostedService(services => services.GetRequiredService<CodexRpc>());
builder.Services.AddSingleton<AttachmentStore>();
builder.Services.AddSingleton<MediaStore>();
builder.Services.AddSingleton<ComposerCatalog>();
builder.Services.AddSingleton<ProjectCatalog>();
builder.Services.AddSingleton<Operations>();
builder.Services.AddSingleton<SessionService>();
builder.Services.AddSingleton<AccountUsage>();
var app = builder.Build();
// Register the small state projections before Codex begins emitting notifications.
_ = app.Services.GetRequiredService<SessionService>();
_ = app.Services.GetRequiredService<AccountUsage>();
app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20), KeepAliveTimeout = TimeSpan.FromSeconds(20) });
app.Use(async (context, next) =>
{
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "same-origin";
    context.Response.Headers["X-Frame-Options"] = "DENY";
    try
    {
        if (context.Request.Path.StartsWithSegments("/api"))
        {
            context.Response.Headers.CacheControl = "no-store";
            var auth = context.RequestServices.GetRequiredService<DeviceAuth>();
            auth.CheckOrigin(context);
            if (context.Request.Path != "/api/auth/session" || context.Request.Method != "POST")
            {
                var device = auth.Authenticate(context) ?? throw new ApiException(401, "unauthorized", "访问密钥无效或登录已过期。");
                context.Items["deviceId"] = device.Id;
            }
            if (context.Request.Method is "POST" or "PUT" && context.Request.Path != "/api/attachments" &&
                !context.Request.HasJsonContentType()) throw new ApiException(415, "json_required", "请求需要 application/json。");
        }
        await next(context);
    }
    catch (Exception exception) when (!context.Response.HasStarted)
    {
        if (exception is OperationCanceledException && context.RequestAborted.IsCancellationRequested) return;
        var error = exception switch
        {
            ApiException api => api,
            BadHttpRequestException bad => new ApiException(bad.StatusCode, "invalid_request", "请求格式或大小无效。"),
            JsonException => new ApiException(400, "invalid_json", "JSON 请求格式无效。"),
            _ => new ApiException(500, "internal_error", "服务端发生错误，请查看主机日志。")
        };
        app.Logger.LogWarning("Request failed {Method} {Path} {Status} {Code} ({Kind})", context.Request.Method, context.Request.Path, error.Status, error.Code, exception.GetType().Name);
        context.Response.StatusCode = error.Status;
        await context.Response.WriteAsJsonAsync(new ApiProblem("about:blank", error.Code, error.Status, error.Message, error.Code), JsonContext.Default.ApiProblem, "application/problem+json", context.RequestAborted);
    }
});

static IResult JsonResult(JsonNode? node, int status = 200) => TypedResults.Json(node, JsonContext.Default.JsonNode, statusCode: status);

app.MapPost("/api/auth/session", (LoginRequest request, HttpContext context, DeviceAuth auth) =>
{
    auth.CheckLoginRate(context);
    var device = auth.Authenticate(request.Token) ?? throw new ApiException(401, "unauthorized", "访问密钥不正确。");
    var localHttp = StartupInfo.IsPrivateHttp(context, configuration);
    if (!localHttp && !context.Request.IsHttps && !(configuration.Value.PublicOrigin?.StartsWith("https://", StringComparison.Ordinal) ?? false))
        throw new ApiException(400, "https_required", "远程网页登录必须使用 HTTPS；请配置 HTTPS 入口和 publicOrigin。");
    context.Response.Cookies.Append(DeviceAuth.CookieName, request.Token, new CookieOptions
    {
        HttpOnly = true,
        Secure = !localHttp,
        SameSite = SameSiteMode.Strict,
        Path = "/",
        MaxAge = TimeSpan.FromDays(30),
        IsEssential = true
    });
    return JsonResult(Json.Object(("device", device.Name)));
}).WithSummary("Create a browser session using a device access key");

app.MapDelete("/api/auth/session", (HttpContext context) =>
{
    context.Response.Cookies.Delete(DeviceAuth.CookieName, new CookieOptions { Path = "/" });
    return TypedResults.NoContent();
});
app.MapGet("/api/status", async (CodexRpc rpc, CancellationToken ct) =>
{
    JsonNode? account = null;
    if (rpc.Ready) account = await rpc.CallAsync("account/read", Json.Object(("refreshToken", false)), ct);
    return JsonResult(Json.Object(("gateway", "ready"), ("codex", rpc.State), ("codexVersion", rpc.Version),
        ("account", account), ("maxFileBytes", configuration.Value.MaxFileBytes), ("codexTransport", rpc.Ready ? rpc.Shared ? "shared" : "stdio" : null),
        ("onDemandRuntime", true), ("codexError", rpc.StartupError),
        ("taskNotifications", true), ("queuedMessages", true), ("automaticInput", true), ("threadActions", true)));
});
app.MapGet("/api/version", () => JsonResult(GatewayVersion.Read()))
    .WithSummary("Read the running gateway version and download platform without starting Codex");
app.MapPost("/api/runtime/start", async (CodexRpc rpc, CancellationToken ct) =>
{
    await rpc.EnsureReadyAsync(ct);
    return JsonResult(Json.Object(("codex", rpc.State), ("codexTransport", rpc.Shared ? "shared" : "stdio")));
});
app.MapGet("/api/projects", async (ProjectCatalog projects, CancellationToken ct) => JsonResult(await projects.ListAsync(ct)));
app.MapPost("/api/projects", async (CreateProjectRequest request, ProjectCatalog projects) => JsonResult(await projects.CreateAsync(request), 201));
app.MapGet("/api/directories", (string? path, bool? hidden, string? search, int? offset) => JsonResult(HostDirectories.List(path, hidden ?? false, search, offset ?? 0)));
app.MapPost("/api/directories", (CreateDirectoryRequest request) => JsonResult(HostDirectories.Create(request), 201));
app.MapGet("/api/models", async (CodexRpc rpc, CancellationToken ct) => JsonResult(await rpc.CallAsync("model/list", Json.Object(("limit", 100)), ct)));
app.MapGet("/api/threads", async (string? projectId, string? cursor, string? search, bool? archived, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.ListAsync(projectId, cursor, search, archived ?? false, ct)));
app.MapPost("/api/threads", async (CreateThreadRequest request, SessionService sessions, HttpContext context) =>
{
    var result = await sessions.CreateAsync(request);
    context.Response.Headers.Location = "/api/threads/" + result?["thread"].String("id");
    return JsonResult(result, 201);
});
app.MapGet("/api/threads/{id}", async (string id, bool? archived, bool? reopen, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.SnapshotAsync(id, archived ?? false, ct, reopen ?? false)));
app.MapPost("/api/threads/{id}/archive", async (string id, ThreadActionRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.ArchiveAsync(id, request, (string)context.Items["deviceId"]!)));
app.MapPost("/api/threads/{id}/close", async (string id, ThreadActionRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.CloseAsync(id, request, (string)context.Items["deviceId"]!)));
app.MapPost("/api/threads/{id}/unarchive", async (string id, SessionService sessions) => JsonResult(await sessions.UnarchiveAsync(id)));
app.MapGet("/api/threads/{id}/items", async (string id, string? cursor, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.ItemsAsync(id, cursor, ct)));
app.MapGet("/api/threads/{id}/skills", async (string id, bool? refresh, SessionService sessions, ComposerCatalog catalog, CancellationToken ct) =>
    JsonResult(await catalog.SkillsAsync((await sessions.AuthorizeAsync(id, ct)).Path, refresh ?? false, ct)));
app.MapGet("/api/threads/{id}/file-search", async (string id, string? query, SessionService sessions, ComposerCatalog catalog, CancellationToken ct) =>
    JsonResult(await catalog.FilesAsync((await sessions.AuthorizeAsync(id, ct)).Path, query ?? "", ct)));
app.MapGet("/api/threads/{id}/mcp", async (string id, string? cursor, SessionService sessions, ComposerCatalog catalog, CancellationToken ct) =>
{
    await sessions.AuthorizeAsync(id, ct);
    return JsonResult(await catalog.McpAsync(id, cursor, ct));
});
app.MapGet("/api/threads/{id}/file", async (string id, string path, bool? download, SessionService sessions, HttpContext context, CancellationToken ct) =>
{
    var project = await sessions.AuthorizeAsync(id, ct);
    var file = WorkspaceFiles.Resolve(project.Path, path);
    if (download != true && new FileInfo(file).Length > 32 * 1024 * 1024)
        throw new ApiException(413, "preview_too_large", "文件超过 32 MiB，请使用下载按钮打开。");
    context.Response.Headers["Content-Security-Policy"] = "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:;";
    return TypedResults.PhysicalFile(file, WorkspaceFiles.ContentType(file), download == true ? Path.GetFileName(file) : null, enableRangeProcessing: true);
});
app.MapGet("/api/media/{id}", async (string id, bool? download, MediaStore media, HttpContext context, CancellationToken ct) =>
{
    var file = media.Get(id);
    var header = new byte[Math.Min(512, new FileInfo(file).Length)];
    await using (var stream = File.OpenRead(file)) await stream.ReadExactlyAsync(header, ct);
    var type = MediaStore.Detect(header);
    var extension = type.Split('/').Last().Replace("svg+xml", "svg");
    context.Response.Headers["Content-Security-Policy"] = "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:;";
    return TypedResults.PhysicalFile(file, type, download == true ? "codex-" + id[..8] + "." + extension : null, enableRangeProcessing: true);
});
app.MapPost("/api/threads/{id}/turns", async (string id, SendMessageRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.SendAsync((string)context.Items["deviceId"]!, id, null, request)));
app.MapPost("/api/threads/{id}/input", async (string id, SendMessageRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.SendAsync((string)context.Items["deviceId"]!, id, null, request, automatic: true)));
app.MapGet("/api/threads/{id}/queue", async (string id, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.QueueAsync(id, ct)));
app.MapPost("/api/threads/{id}/queue", async (string id, SendMessageRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.EnqueueAsync((string)context.Items["deviceId"]!, id, request)));
app.MapPost("/api/threads/{id}/queue/{queuedId}/send", async (string id, string queuedId, QueueActionRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.QueueActionAsync((string)context.Items["deviceId"]!, id, queuedId, request, send: true)));
app.MapPost("/api/threads/{id}/queue/{queuedId}/withdraw", async (string id, string queuedId, QueueActionRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.QueueActionAsync((string)context.Items["deviceId"]!, id, queuedId, request, send: false)));
app.MapPost("/api/threads/{id}/turns/{turnId}/steer", async (string id, string turnId, SendMessageRequest request, SessionService sessions, HttpContext context) =>
    JsonResult(await sessions.SendAsync((string)context.Items["deviceId"]!, id, turnId, request)));
app.MapPost("/api/threads/{id}/turns/{turnId}/interrupt", async (string id, string turnId, SessionService sessions) => JsonResult(await sessions.InterruptAsync(id, turnId)));
app.MapGet("/api/threads/{id}/goal", async (string id, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.GoalAsync(id, ct)));
app.MapGet("/api/threads/{id}/permissions", async (string id, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.PermissionsAsync(id, ct)));
app.MapPut("/api/threads/{id}/permissions", async (string id, SetPermissionsRequest request, SessionService sessions) => JsonResult(await sessions.SetPermissionsAsync(id, request)));
app.MapPut("/api/threads/{id}/speed", async (string id, SetSpeedRequest request, SessionService sessions) => JsonResult(await sessions.SetSpeedAsync(id, request)));
app.MapPut("/api/threads/{id}/goal", async (string id, SetGoalRequest request, SessionService sessions) => JsonResult(await sessions.SetGoalAsync(id, request)));
app.MapDelete("/api/threads/{id}/goal", async (string id, SessionService sessions) => { await sessions.ClearGoalAsync(id); return TypedResults.NoContent(); });
app.MapGet("/api/threads/{id}/usage", async (string id, SessionService sessions, CancellationToken ct) => JsonResult(await sessions.UsageAsync(id, ct)));
app.MapGet("/api/account/usage", async (bool? refresh, AccountUsage account, CancellationToken ct) => JsonResult(await account.ReadAsync(refresh ?? false, ct)));
app.MapGet("/api/approvals", (CodexRpc rpc) => JsonResult(rpc.Approvals));
app.MapPost("/api/approvals/{id}", async (string id, ApprovalRequest request, CodexRpc rpc) =>
{
    if (request.Result.ValueKind != JsonValueKind.Object) throw new ApiException(400, "invalid_approval", "审批响应必须是对象。");
    await rpc.AnswerAsync(id, JsonNode.Parse(request.Result.GetRawText())!);
    return TypedResults.NoContent();
});
app.MapGet("/api/operations/{id}", (string id, Operations operations, HttpContext context) => JsonResult(operations.Read((string)context.Items["deviceId"]!, id)));
app.MapPost("/api/attachments", async (string threadId, AttachmentStore attachments, SessionService sessions, HttpContext context, CancellationToken ct) =>
{
    var project = await sessions.AuthorizeAsync(threadId, ct);
    var result = await attachments.UploadAsync(context.Request, threadId, project.Id, ct);
    context.Response.Headers.Location = "/api/attachments/" + result.Id;
    return TypedResults.Json(result, JsonContext.Default.AttachmentRecord, statusCode: 201);
});
app.MapGet("/api/attachments/{id}", async (string id, bool? preview, AttachmentStore attachments, SessionService sessions, CancellationToken ct) =>
{
    var file = attachments.Get(id);
    await sessions.AuthorizeAsync(file.ThreadId, ct);
    return TypedResults.PhysicalFile(attachments.PathFor(id), file.ContentType, preview == true && file.IsImage ? null : file.Name, enableRangeProcessing: true);
});
app.MapDelete("/api/attachments/{id}", async (string id, bool? cleanup, SessionService sessions) =>
{
    await sessions.DeleteAttachmentAsync(id, cleanup ?? false);
    return TypedResults.NoContent();
});
app.MapGet("/api/events", (HttpContext context, EventHub hub) => hub.ConnectAsync(context));
app.MapGet("/api/notifications", (string? epoch, long? after, TaskNotifications notifications) =>
    TypedResults.Json(notifications.Read(epoch, after), JsonContext.Default.TaskNoticeBatch))
    .WithSummary("Read retained task completion metadata after a notification cursor");
app.MapGet("/api/notifications/events", (HttpContext context, TaskNotifications notifications) => notifications.StreamAsync(context))
    .WithSummary("Receive task completion notifications and reconnect cursors as server-sent events");
app.MapGet("/health", () => TypedResults.Text("ok"));
if (Directory.Exists(webRoot))
{
    app.UseDefaultFiles();
    app.UseStaticFiles(new StaticFileOptions
    {
        OnPrepareResponse = context => context.Context.Response.Headers.CacheControl =
            context.File.Name is "index.html" or "flutter_bootstrap.js" or "flutter_service_worker.js" or "main.dart.js" or "flutter.js" or "version.json" or "manifest.json" ? "no-cache" : "public,max-age=3600"
    });
    app.MapFallbackToFile("index.html");
}
else
{
    var embedded = new EmbeddedWeb();
    app.MapFallback("/{**path}", embedded.ServeAsync);
}
app.Lifetime.ApplicationStarted.Register(() => StartupInfo.Print(configuration));
await app.RunAsync();
