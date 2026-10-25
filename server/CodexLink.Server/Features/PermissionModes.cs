using System.Text.Json.Nodes;
using CodexLink.Server.Codex;

namespace CodexLink.Server.Features;

/// <summary>Four explicit presets over Codex's sandbox and approval controls.</summary>
public static class PermissionModes
{
    private sealed record Mode(string Id, string Label, string Description, string Profile, string Policy, string Reviewer, string Sandbox);
    private static readonly Mode[] Modes =
    [
        new("read-only", "只读", "默认只读文件；写入或越过沙箱边界时请求你批准。", ":read-only", "on-request", "user", "read-only"),
        new("default", "默认", "可读写工作区、运行命令；越过沙箱边界时请求你批准。", ":workspace", "on-request", "user", "workspace-write"),
        new("auto-review", "自动审查", "保持工作区沙箱；由 Codex 自动审查需要升级权限的请求。", ":workspace", "on-request", "auto_review", "workspace-write"),
        new("full-access", "完全访问", "关闭沙箱与常规审批，可访问主机文件和网络。仅在信任当前任务时使用。", ":danger-full-access", "never", "user", "danger-full-access")
    ];

    public static JsonObject Parameters(string? preset)
    {
        var mode = Modes.FirstOrDefault(m => m.Id == preset)
            ?? throw new ApiException(400, "invalid_permissions", "请选择只读、默认、自动审查或完全访问。");
        return Json.Object(("permissions", mode.Profile), ("approvalPolicy", mode.Policy), ("approvalsReviewer", mode.Reviewer));
    }

    public static JsonObject Read(JsonNode? settings)
    {
        var sandbox = settings?["sandboxPolicy"] ?? settings?["sandbox"];
        var profile = settings?["activePermissionProfile"].String("id");
        var policy = settings?["approvalPolicy"];
        var reviewer = settings.String("approvalsReviewer");
        var kind = sandbox.String("type");
        // Preserve custom profiles and approval policies; never call them a preset.
        var inferredProfile = profile ?? (kind switch
        {
            "readOnly" when sandbox?["networkAccess"]?.GetValue<bool>() != true => ":read-only",
            "workspaceWrite" when sandbox?["networkAccess"]?.GetValue<bool>() != true && sandbox?["writableRoots"] is JsonArray { Count: 0 } => ":workspace",
            "dangerFullAccess" => ":danger-full-access",
            _ => null
        });
        var mode = Modes.FirstOrDefault(m => m.Profile == inferredProfile &&
            kind == (m.Sandbox switch { "read-only" => "readOnly", "workspace-write" => "workspaceWrite", _ => "dangerFullAccess" }) &&
            (kind == "dangerFullAccess" || sandbox?["networkAccess"]?.GetValue<bool>() != true) &&
            JsonNode.DeepEquals(policy, JsonValue.Create(m.Policy)) && m.Reviewer == reviewer);
        return Json.Object(("preset", mode?.Id), ("label", mode?.Label ?? (sandbox is null ? "权限未知" : "自定义权限")),
            ("approvalPolicy", policy.Copy()), ("approvalsReviewer", reviewer), ("sandboxPolicy", sandbox.Copy()),
            ("activePermissionProfile", settings?["activePermissionProfile"].Copy()));
    }

    public static async Task<JsonArray> OptionsAsync(CodexRpc rpc, string cwd, CancellationToken ct = default)
    {
        var profilesTask = rpc.CallAsync("permissionProfile/list", Json.Object(("cwd", cwd), ("limit", 100)), ct);
        var requirementsTask = rpc.CallAsync("configRequirements/read", new JsonObject(), ct);
        await Task.WhenAll(profilesTask, requirementsTask);
        var profiles = (await profilesTask)?["data"]?.AsArray();
        var requirements = (await requirementsTask)?["requirements"];
        var options = new JsonArray();
        foreach (var mode in Modes)
        {
            var available = profiles?.Any(p => p.String("id") == mode.Profile && p?["allowed"]?.GetValue<bool>() == true) == true;
            var allowed = available && Allows(requirements?["allowedApprovalPolicies"], mode.Policy) &&
                Allows(requirements?["allowedApprovalsReviewers"], mode.Reviewer) &&
                Allows(requirements?["allowedSandboxModes"], mode.Sandbox);
            options.Add((JsonNode)Json.Object(("id", mode.Id), ("label", mode.Label), ("description", mode.Description),
                ("allowed", allowed), ("reason", allowed ? null : "当前 Codex 环境或管理策略不允许此权限。")));
        }
        return options;
    }

    private static bool Allows(JsonNode? values, string expected) => values is not JsonArray array ||
        array.Any(value => JsonNode.DeepEquals(value, JsonValue.Create(expected)));
}
