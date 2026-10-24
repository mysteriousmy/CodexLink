using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexLink.Server.Codex;

namespace CodexLink.Server.Features;

public sealed partial class SessionService
{
    private sealed class SessionState(ProjectConfig project)
    {
        public ProjectConfig Project { get; } = project;
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public bool Loaded { get; set; }
        public bool Closed { get; set; }
        public bool Archived { get; set; }
        public bool CloseRequested { get; set; }
        public long CloseEventVersion { get; set; }
        public bool Materialized { get; set; } = true;
        public long TurnEventVersion { get; set; }
        public string? ActiveTurn { get; set; }
        public JsonNode? Usage { get; set; }
        public JsonNode? Goal { get; set; }
        public JsonNode? Permissions { get; set; }
        public long SettingsEventVersion { get; set; }
        public TaskCompletionSource<JsonNode?>? SettingsChanged { get; set; }
        public string? ControlReason { get; set; }
        public DateTimeOffset Accessed { get; set; } = DateTimeOffset.UtcNow;
    }
    private readonly Configuration _config;
    private readonly CodexRpc _rpc;
    private readonly AttachmentStore _attachments;
    private readonly Operations _operations;
    private readonly ComposerCatalog _catalog;
    private readonly MediaStore _media;
    private readonly ProjectCatalog _projects;
    private readonly Realtime.EventHub _events;
    private readonly ConcurrentDictionary<string, SessionState> _sessions = new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _projectGates = new();

    public SessionService(Configuration config, CodexRpc rpc, AttachmentStore attachments, Operations operations, ComposerCatalog catalog, MediaStore media, ProjectCatalog projects, Realtime.EventHub events)
    {
        _config = config; _rpc = rpc; _attachments = attachments; _operations = operations; _catalog = catalog; _media = media;
        _projects = projects; _events = events;
        rpc.Notification += OnNotification;
    }

    private void OnNotification(string method, JsonNode? parameters)
    {
        if (method == "runtime/stopped")
        {
            foreach (var state in _sessions.Values) { state.Loaded = false; state.ActiveTurn = null; state.Usage = null; state.Permissions = null; }
            return;
        }
        if (parameters.String("threadId") is not { } id || !_sessions.TryGetValue(id, out var session)) return;
        switch (method)
        {
            case "turn/started": session.ActiveTurn = parameters?["turn"].String("id"); session.TurnEventVersion++; break;
            case "turn/completed":
                if (session.ActiveTurn == parameters?["turn"].String("id")) session.ActiveTurn = null;
                session.TurnEventVersion++;
                break;
            case "thread/status/changed":
                if (parameters?["status"].String("type") is "idle" or "notLoaded")
                {
                    session.ActiveTurn = null; session.TurnEventVersion++;
                    if (parameters?["status"].String("type") == "notLoaded")
                    { session.Loaded = false; session.CloseRequested = false; }
                }
                break;
            case "item/started": if (parameters?["item"].String("type") == "userMessage") session.Materialized = true; break;
            case "thread/tokenUsage/updated": session.Usage = parameters?["tokenUsage"].Copy(); break;
            case "thread/goal/updated": session.Goal = parameters?["goal"].Copy(); break;
            case "thread/goal/cleared": session.Goal = null; break;
            case "thread/settings/updated":
                session.Permissions = PermissionModes.Read(parameters?["threadSettings"]);
                session.SettingsEventVersion++;
                parameters!["permissions"] = session.Permissions.Copy();
                session.SettingsChanged?.TrySetResult(session.Permissions.Copy());
                break;
            case "thread/closed":
                session.Loaded = false; session.ActiveTurn = null; session.TurnEventVersion++;
                session.Closed = true; session.CloseRequested = false;
                session.CloseEventVersion++;
                break;
            case "thread/archived":
                session.Archived = true; session.Closed = true; session.Loaded = false;
                session.CloseRequested = false; session.CloseEventVersion++;
                session.ActiveTurn = null; session.TurnEventVersion++;
                break;
            case "thread/unarchived": session.Archived = false; break;
        }
    }

    public async Task<JsonNode?> ListAsync(string? projectId, string? cursor, string? search, bool archived, CancellationToken cancellationToken)
    {
        var parameters = Json.Object(("cursor", cursor), ("limit", 30), ("sortKey", "updated_at"),
            ("modelProviders", new JsonArray()), ("archived", archived),
            ("sourceKinds", new JsonArray("cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown")));
        if (!string.IsNullOrEmpty(projectId)) parameters["projectId"] = projectId;
        if (!string.IsNullOrWhiteSpace(search)) parameters["searchTerm"] = search.Trim();
        var result = await _rpc.CallAsync("thread/list", parameters, cancellationToken);
        if (result?["data"] is JsonArray rows)
            foreach (var row in rows)
                if (row.String("id") is { } id && _sessions.TryGetValue(id, out var state))
                {
                    if (row?["status"].String("type") == "notLoaded")
                    { state.CloseRequested = false; state.Loaded = false; state.ActiveTurn = null; }
                    row!["closePending"] = state.CloseRequested;
                    row["closedByClient"] = state.Closed;
                }
        return result;
    }

    public async Task<JsonNode?> CreateAsync(CreateThreadRequest request)
    {
        JsonNode? codexProject = null;
        var path = request.Path;
        if (!string.IsNullOrWhiteSpace(request.ProjectId))
        {
            codexProject = await _projects.ReadAsync(request.ProjectId);
            var roots = codexProject["roots"]?.AsArray().Select(r => r.String("path")).OfType<string>().ToArray() ?? [];
            path ??= roots.FirstOrDefault();
            path = HostDirectories.Existing(path);
            if (!roots.Any(r => string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(r)), path, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)))
                throw new ApiException(400, "invalid_project_root", "工作目录必须是所选 Codex 项目的目录。");
        }
        var project = _config.ProjectForPath(HostDirectories.Existing(path));
        var parameters = SessionParameters(project);
        if (codexProject is not null)
        {
            parameters["projectId"] = request.ProjectId;
            parameters["runtimeWorkspaceRoots"] = new JsonArray(codexProject["roots"]!.AsArray().Select(r => (JsonNode?)JsonValue.Create(HostDirectories.Existing(r.String("path")))).ToArray());
        }
        if (!string.IsNullOrWhiteSpace(request.Model)) parameters["model"] = request.Model;
        var response = await _rpc.CallAsync("thread/start", parameters);
        var id = response?["thread"].String("id") ?? throw new ApiException(502, "invalid_codex_response", "Codex 未返回会话 ID。");
        AddSession(id, new SessionState(project) { Loaded = true, Materialized = false, Permissions = PermissionModes.Read(response) });
        return response;
    }

    private void AddSession(string id, SessionState session)
    {
        if (_sessions.Count >= 256)
        {
            var old = _sessions.Where(s => s.Value.ActiveTurn is null && s.Value.Gate.CurrentCount == 1).OrderBy(s => s.Value.Accessed).FirstOrDefault();
            if (old.Key is not null) _sessions.TryRemove(old.Key, out _);
            else throw new ApiException(429, "session_capacity", "已加载会话过多。");
        }
        _sessions.TryAdd(id, session);
    }

    public async Task<ProjectConfig> AuthorizeAsync(string id, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(id) || id.Length > 150) throw new ApiException(400, "invalid_thread", "会话 ID 无效。");
        if (!_sessions.TryGetValue(id, out var state))
        {
            var response = await _rpc.CallAsync("thread/read", Json.Object(("threadId", id), ("includeTurns", false)), cancellationToken);
            var project = _config.ProjectForPath(response?["thread"].String("cwd") ?? throw new ApiException(404, "thread_not_found", "会话不存在。"));
            AddSession(id, new(project));
            state = _sessions[id];
        }
        state.Accessed = DateTimeOffset.UtcNow;
        return state.Project;
    }

    private JsonObject SessionParameters(ProjectConfig project) => Json.Object(("cwd", project.Path),
        ("permissions", ":workspace"), ("approvalPolicy", "on-request"), ("approvalsReviewer", "user"));

    private async Task ResumeInsideLockAsync(string id, SessionState session)
    {
        if (session.Archived) throw new ApiException(409, "thread_archived", "会话已归档，请先恢复会话。");
        if (session.Closed) throw new ApiException(409, "thread_closed", "会话已关闭，请重新打开后继续。");
        if (session.Loaded) return;
        // Rejoin the exact thread without replacing its model, working directory,
        // permissions or goal. Another client may already be executing it.
        var parameters = Json.Object(("threadId", id), ("excludeTurns", true));
        var eventVersion = session.TurnEventVersion;
        var settingsVersion = session.SettingsEventVersion;
        var response = await _rpc.CallAsync("thread/resume", parameters);
        session.Loaded = true;
        session.ControlReason = null;
        if (session.SettingsEventVersion == settingsVersion) session.Permissions = PermissionModes.Read(response);
        if (session.TurnEventVersion == eventVersion && response?["thread"]?["turns"] is JsonArray { Count: > 0 } turns)
            session.ActiveTurn = turns.FirstOrDefault(t => t.String("status") == "inProgress").String("id");
    }

    private void EnsureProjectAvailable(string id, SessionState session)
    {
        if (_sessions.Any(s => s.Key != id && s.Value.Project.Id == session.Project.Id &&
            !s.Value.Archived && !(s.Value.Closed && !s.Value.CloseRequested) &&
            (s.Value.ActiveTurn is not null || s.Value.Goal.String("status") == "active")))
            throw new ApiException(409, "project_busy", "同一项目另有任务或目标正在执行，请先完成或暂停它。");
    }

    public async Task<JsonObject> SnapshotAsync(string id, bool archived, CancellationToken cancellationToken, bool reopen = false)
    {
        await AuthorizeAsync(id, cancellationToken);
        var session = _sessions[id];
        await session.Gate.WaitAsync(cancellationToken);
        try
        {
            archived |= session.Archived;
            if (reopen && !archived) { session.Closed = false; session.CloseRequested = false; }
            session.ControlReason = archived ? "这是已归档会话。恢复后可继续对话或设置 Goal。"
                : session.Closed ? "此会话已关闭或正在等待卸载，重新打开后可继续。" : null;
            if (!archived && !session.Closed)
            {
                try { await ResumeInsideLockAsync(id, session); }
                catch (ApiException e) when (e.Code == "codex_rpc_error" && e.Message.Contains("active writer", StringComparison.OrdinalIgnoreCase))
                {
                    session.ControlReason = "另一个独立 Codex 进程持有此会话。可查看历史；请先在原客户端释放会话，再同步重试。";
                }
            }
            var metadata = await _rpc.CallAsync("thread/read", Json.Object(("threadId", id), ("includeTurns", false)), cancellationToken);
            if (_rpc.Shared && session.Loaded && session.Materialized && !archived)
            {
                // A shared runtime may have started this turn before we subscribed.
                var version = session.TurnEventVersion;
                var turns = await _rpc.CallAsync("thread/turns/list", Json.Object(("threadId", id), ("limit", 1),
                    ("sortDirection", "desc"), ("itemsView", "notLoaded")), cancellationToken);
                if (session.TurnEventVersion == version && turns?["data"] is JsonArray recent)
                    session.ActiveTurn = recent.FirstOrDefault(t => t.String("status") == "inProgress").String("id");
            }
            return Json.Object(("thread", metadata?["thread"].Copy()), ("activeTurnId", session.ActiveTurn),
                ("usage", session.Usage.Copy()), ("goal", session.Goal.Copy()),
                ("permissions", session.Permissions.Copy()),
                ("canControl", session.ControlReason is null), ("controlReason", session.ControlReason), ("archived", archived), ("closed", session.Closed),
                ("approvals", new JsonArray(_rpc.Approvals.Where(a => a?["params"].String("threadId") == id).Select(a => a.Copy()).ToArray())),
                ("attachments", JsonSerializer.SerializeToNode(_attachments.ForThread(id), JsonContext.Default.AttachmentRecordArray)));
        }
        finally { session.Gate.Release(); }
    }

    public async Task<JsonObject> PermissionsAsync(string id, CancellationToken ct)
    {
        await AuthorizeAsync(id, ct);
        var session = _sessions[id];
        await session.Gate.WaitAsync(ct);
        try
        {
            if (session.ControlReason is not null) throw new ApiException(409, "thread_read_only", session.ControlReason);
            await ResumeInsideLockAsync(id, session);
            return Json.Object(("current", session.Permissions.Copy()),
                ("options", await PermissionModes.OptionsAsync(_rpc, session.Project.Path, ct)));
        }
        finally { session.Gate.Release(); }
    }

    public async Task<JsonNode?> SetPermissionsAsync(string id, SetPermissionsRequest request)
    {
        var parameters = PermissionModes.Parameters(request.Preset);
        await AuthorizeAsync(id);
        var session = _sessions[id];
        await session.Gate.WaitAsync();
        try
        {
            if (session.ControlReason is not null) throw new ApiException(409, "thread_read_only", session.ControlReason);
            await ResumeInsideLockAsync(id, session);
            var metadata = await _rpc.CallAsync("thread/read", Json.Object(("threadId", id), ("includeTurns", false)));
            var goal = await _rpc.CallAsync("thread/goal/get", Json.Object(("threadId", id)));
            if (session.ActiveTurn is not null || metadata?["thread"]?["status"].String("type") == "active" || goal?["goal"].String("status") == "active")
                throw new ApiException(409, "thread_busy", "请先结束当前轮次并暂停 Goal，再切换权限。");
            var options = await PermissionModes.OptionsAsync(_rpc, session.Project.Path);
            if (!options.Any(o => o.String("id") == request.Preset && o?["allowed"]?.GetValue<bool>() == true))
                throw new ApiException(403, "permissions_not_allowed", "当前 Codex 环境或管理策略不允许此权限。");
            parameters["threadId"] = id;
            session.SettingsChanged = new(TaskCreationOptions.RunContinuationsAsynchronously);
            await _rpc.CallAsync("thread/settings/update", parameters);
            // Settings arrive after the empty response, including for empty threads
            // that have no rollout and therefore cannot be resumed yet.
            try { return await session.SettingsChanged.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (TimeoutException) { throw new ApiException(504, "permissions_unconfirmed", "权限更新已提交，但尚未收到 Codex 确认；请同步后核对，不要重复提交。"); }
        }
        finally { session.SettingsChanged = null; session.Gate.Release(); }
    }

    public async Task<JsonNode?> UnarchiveAsync(string id)
    {
        await AuthorizeAsync(id);
        var session = _sessions[id];
        await session.Gate.WaitAsync();
        try
        {
            var result = await _rpc.CallAsync("thread/unarchive", Json.Object(("threadId", id)));
            session.Archived = false;
            session.Closed = false;
            session.CloseRequested = false;
            session.ControlReason = null;
            _events.Publish("thread/lifecycle/changed", Json.Object(("threadId", id), ("state", "unarchived")));
            return result;
        }
        finally { session.Gate.Release(); }
    }

    public async Task<JsonNode?> ItemsAsync(string id, string? cursor, CancellationToken cancellationToken)
    {
        await AuthorizeAsync(id, cancellationToken);
        if (!_sessions[id].Materialized) return Json.Object(("data", new JsonArray()), ("nextCursor", null));
        var result = await _rpc.CallAsync("thread/items/list", Json.Object(("threadId", id), ("cursor", cursor), ("limit", 50), ("sortDirection", "desc")), cancellationToken);
        if (result?["data"] is JsonArray entries)
            foreach (var entry in entries) if (entry?["item"] is JsonObject item) await _media.ProjectAsync(id, item, cancellationToken);
        return result;
    }

    public Task<JsonNode?> SendAsync(string device, string id, string? expectedTurn, SendMessageRequest request, bool automatic = false)
    {
        if (request.Text is null || request.Text.Length > 200_000 || (string.IsNullOrWhiteSpace(request.Text) && (request.AttachmentIds?.Length ?? 0) == 0 && (request.References?.Length ?? 0) == 0))
            throw new ApiException(400, "invalid_message", "请输入消息或添加附件；正文最多 200,000 字符。");
        var fingerprint = id + ":" + (automatic ? "auto" : expectedTurn) + ":" + JsonSerializer.Serialize(request, JsonContext.Default.SendMessageRequest);
        return _operations.RunAsync(device, request.RequestId, fingerprint, async () =>
        {
            await AuthorizeAsync(id);
            var session = _sessions[id];
            var projectGate = _projectGates.GetOrAdd(session.Project.Id, _ => new SemaphoreSlim(1, 1));
            await projectGate.WaitAsync();
            await session.Gate.WaitAsync();
            try
            {
                await ResumeInsideLockAsync(id, session);
                if (session.ControlReason is not null) throw new ApiException(409, "thread_read_only", session.ControlReason);
                // Choose against the subscribed runtime state under the same
                // gate as submission. Codex controls when a steer is consumed.
                if (automatic) expectedTurn = session.ActiveTurn;
                if (expectedTurn is null && session.ActiveTurn is not null) throw new ApiException(409, "thread_busy", "任务正在执行，请使用补充指令。");
                if (expectedTurn is not null && expectedTurn != session.ActiveTurn) throw new ApiException(409, "turn_changed", "当前轮次已结束或改变。草稿已保留，请核对后重新发送。");
                // Steering an already-running thread must remain available even
                // when another client has concurrent work in this directory.
                if (expectedTurn is null) EnsureProjectAvailable(id, session);
                var input = await _attachments.BuildInputAsync(id, request.Text, request.AttachmentIds ?? []);
                await _catalog.AddInputsAsync(input, session.Project.Path, request.References ?? []);
                var parameters = Json.Object(("threadId", id), ("input", input), ("clientUserMessageId", request.RequestId));
                if (expectedTurn is not null) parameters["expectedTurnId"] = expectedTurn;
                else
                {
                    if (!string.IsNullOrEmpty(request.Model)) parameters["model"] = request.Model;
                    if (!string.IsNullOrEmpty(request.Effort)) parameters["effort"] = request.Effort;
                }
                var eventVersion = session.TurnEventVersion;
                var response = await _rpc.CallAsync(expectedTurn is null ? "turn/start" : "turn/steer", parameters);
                session.Materialized = true;
                if (session.TurnEventVersion == eventVersion) session.ActiveTurn = expectedTurn ?? response?["turn"].String("id");
                return response;
            }
            finally { session.Gate.Release(); projectGate.Release(); }
        });
    }

    public async Task<JsonNode?> InterruptAsync(string id, string turnId)
    {
        await AuthorizeAsync(id);
        var goal = await GoalAsync(id, CancellationToken.None);
        if (goal?["goal"].String("status") == "active") await SetGoalAsync(id, new(null, "paused", null));
        return await _rpc.CallAsync("turn/interrupt", Json.Object(("threadId", id), ("turnId", turnId)));
    }

    public async Task<JsonNode?> GoalAsync(string id, CancellationToken cancellationToken)
    {
        await AuthorizeAsync(id, cancellationToken);
        var response = await _rpc.CallAsync("thread/goal/get", Json.Object(("threadId", id)), cancellationToken);
        _sessions[id].Goal = response?["goal"].Copy();
        return response;
    }

    public async Task<JsonNode?> SetGoalAsync(string id, SetGoalRequest request)
    {
        await AuthorizeAsync(id);
        if (request.Objective is not null && (string.IsNullOrWhiteSpace(request.Objective) || request.Objective.Length > 4000)) throw new ApiException(400, "invalid_goal", "目标需为 1–4,000 字符。");
        if (request.Status is not null && request.Status is not ("active" or "paused")) throw new ApiException(400, "invalid_goal_status", "只能手动启用或暂停目标。");
        if (request.BudgetSpecified && request.TokenBudget is <= 0) throw new ApiException(400, "invalid_budget", "预算必须为正整数。");
        var session = _sessions[id];
        var projectGate = _projectGates.GetOrAdd(session.Project.Id, _ => new SemaphoreSlim(1, 1));
        await projectGate.WaitAsync();
        await session.Gate.WaitAsync();
        try
        {
            await ResumeInsideLockAsync(id, session);
            if (session.ControlReason is not null) throw new ApiException(409, "thread_read_only", session.ControlReason);
            if (request.Status != "paused") EnsureProjectAvailable(id, session);
            var parameters = Json.Object(("threadId", id), ("origin", "user"));
            if (request.Objective is not null) parameters["objective"] = request.Objective;
            if (request.Status is not null) parameters["status"] = request.Status;
            if (request.BudgetSpecified) parameters["tokenBudget"] = request.TokenBudget;
            var result = await _rpc.CallAsync("thread/goal/set", parameters);
            session.Goal = result?["goal"].Copy();
            return result;
        }
        finally { session.Gate.Release(); projectGate.Release(); }
    }

    public async Task<JsonNode?> ClearGoalAsync(string id)
    {
        await AuthorizeAsync(id);
        var result = await _rpc.CallAsync("thread/goal/clear", Json.Object(("threadId", id), ("origin", "user")));
        _sessions[id].Goal = null;
        return result;
    }

    public async Task<JsonObject> UsageAsync(string id, CancellationToken cancellationToken)
    {
        await AuthorizeAsync(id, cancellationToken);
        return Json.Object(("tokenUsage", _sessions[id].Usage.Copy()));
    }

    public async Task DeleteAttachmentAsync(string id, bool cleanup)
    {
        var file = _attachments.Get(id);
        await AuthorizeAsync(file.ThreadId);
        var state = _sessions[file.ThreadId];
        await state.Gate.WaitAsync();
        try
        {
            if (!_attachments.Get(id).Referenced)
            {
                await _attachments.DeleteAsync(id, cleanup);
                return;
            }
            var goal = await GoalAsync(file.ThreadId, CancellationToken.None);
            if (state.ActiveTurn is not null || goal?["goal"] is { } currentGoal && currentGoal.String("status") != "complete")
                throw new ApiException(409, "attachment_in_use", "任务或未完成的目标仍可能使用附件，请先结束任务并清除目标。");
            await _attachments.DeleteAsync(id, cleanup);
        }
        finally { state.Gate.Release(); }
    }
}
