using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CodexLink.Server;

/// <summary>Device secret used to create a browser session.</summary>
public sealed record LoginRequest(string Token);
/// <summary>Start in a Codex project or an explicitly selected host directory.</summary>
public sealed record CreateThreadRequest(string? ProjectId = null, string? Model = null, string? Path = null);
public sealed record CreateProjectRequest(string Name, string Path, string RequestId);
public sealed record CreateDirectoryRequest(string ParentPath, string Name);
/// <summary>A user message with uploaded attachment IDs and a stable retry ID.</summary>
public sealed record SendMessageRequest(string RequestId, string Text, string[]? AttachmentIds = null, string? Model = null, string? Effort = null, MessageReference[]? References = null);
public sealed record MessageReference(string Type, string Name, string Path);
/// <summary>Native goal update. BudgetSpecified distinguishes no change from removing a budget.</summary>
public sealed record SetGoalRequest(string? Objective, string? Status, long? TokenBudget, bool BudgetSpecified = false);
public sealed record SetPermissionsRequest(string Preset);
/// <summary>Answer an active Codex server request.</summary>
public sealed record ApprovalRequest(JsonElement Result);
/// <summary>An uploaded file owned by a thread.</summary>
public sealed record AttachmentRecord(string Id, string Name, long Size, string ContentType, string ThreadId, string ProjectId, DateTimeOffset CreatedAt, bool Referenced, bool IsImage);
/// <summary>Stable error envelope suitable for clients and logs.</summary>
public sealed record ApiProblem(string Type, string Title, int Status, string Detail, string Code);
public sealed class ApiException(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = false)]
[JsonSerializable(typeof(GatewayConfig))]
[JsonSerializable(typeof(LoginRequest))]
[JsonSerializable(typeof(CreateThreadRequest))]
[JsonSerializable(typeof(CreateProjectRequest))]
[JsonSerializable(typeof(CreateDirectoryRequest))]
[JsonSerializable(typeof(SendMessageRequest))]
[JsonSerializable(typeof(SetGoalRequest))]
[JsonSerializable(typeof(SetPermissionsRequest))]
[JsonSerializable(typeof(ApprovalRequest))]
[JsonSerializable(typeof(AttachmentRecord))]
[JsonSerializable(typeof(AttachmentRecord[]))]
[JsonSerializable(typeof(ProjectConfig[]))]
[JsonSerializable(typeof(ApiProblem))]
[JsonSerializable(typeof(JsonObject))]
[JsonSerializable(typeof(JsonNode))]
[JsonSerializable(typeof(JsonArray))]
[JsonSerializable(typeof(JsonElement))]
public partial class JsonContext : JsonSerializerContext;

public static class Json
{
    public static JsonObject Object(params (string Key, JsonNode? Value)[] entries)
    {
        var result = new JsonObject();
        foreach (var (key, value) in entries) result[key] = value;
        return result;
    }
    public static string? String(this JsonNode? node, string key) => node?[key]?.GetValue<string>();
    public static JsonNode? Copy(this JsonNode? node) => node?.DeepClone();
    public static string Compact(JsonNode node) => node.ToJsonString(JsonContext.Default.Options);
}
