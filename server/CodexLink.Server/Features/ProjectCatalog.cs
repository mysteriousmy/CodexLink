using System.Text.Json.Nodes;
using CodexLink.Server.Codex;

namespace CodexLink.Server.Features;

// Project identities and membership belong to Codex, never to gateway config.
public sealed class ProjectCatalog(CodexRpc rpc)
{
    public async Task<JsonArray> ListAsync(CancellationToken ct)
    {
        var projects = new JsonArray();
        string? cursor = null;
        do
        {
            var page = await rpc.CallAsync("project/list", Json.Object(("cursor", cursor), ("limit", 100)), ct);
            if (page?["data"] is JsonArray data)
                foreach (var project in data) projects.Add(project.Copy());
            cursor = page.String("nextCursor");
        } while (cursor is not null);
        return projects;
    }

    public async Task<JsonNode> ReadAsync(string id, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(id) || id.Length > 200)
            throw new ApiException(400, "invalid_project", "请选择有效的 Codex 项目。");
        var response = await rpc.CallAsync("project/read", Json.Object(("projectId", id)), ct);
        return response?["project"]?.DeepClone()
            ?? throw new ApiException(404, "project_not_found", "Codex 项目不存在，请刷新项目列表。");
    }

    public async Task<JsonNode?> CreateAsync(CreateProjectRequest request)
    {
        var name = request.Name?.Trim();
        if (string.IsNullOrEmpty(name) || name.Length > 120 || name.Any(char.IsControl))
            throw new ApiException(400, "invalid_project_name", "项目名称需要 1–120 个可见字符。");
        if (!Guid.TryParse(request.RequestId, out _))
            throw new ApiException(400, "invalid_request_id", "项目创建请求需要有效的 requestId。");
        var path = HostDirectories.Existing(request.Path);
        return await rpc.CallAsync("project/create", Json.Object(("name", name),
            ("idempotencyKey", "codexlink-" + request.RequestId),
            ("roots", new JsonArray(Json.Object(("path", path))))));
    }
}

public static class HostDirectories
{
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string Existing(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || path.IndexOf('\0') >= 0)
            throw new ApiException(400, "invalid_directory", "请选择主机上的绝对目录路径。");
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (!Directory.Exists(full)) throw new ApiException(404, "directory_not_found", "目录不存在或无法访问，请重新选择。");
        return full;
    }

    public static JsonObject List(string? path, bool hidden, string? search, int offset)
    {
        var current = Existing(string.IsNullOrEmpty(path) ? Home : path);
        if (offset < 0) throw new ApiException(400, "invalid_offset", "目录分页无效。");
        try
        {
            // Only one level, only directories. Paging bounds the response/UI.
            var dirs = Directory.EnumerateDirectories(current)
                .Select(p => new DirectoryInfo(p))
                .Where(p => (hidden || (!p.Name.StartsWith('.') && !p.Attributes.HasFlag(FileAttributes.Hidden))) &&
                    (string.IsNullOrWhiteSpace(search) || p.Name.Contains(search, StringComparison.OrdinalIgnoreCase)))
                .OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase).Skip(offset).Take(201).ToArray();
            return Json.Object(("path", current), ("parentPath", Directory.GetParent(current)?.FullName), ("homePath", Home),
                ("entries", new JsonArray(dirs.Take(200).Select(p => (JsonNode)Json.Object(("name", p.Name), ("path", p.FullName))).ToArray())),
                ("nextOffset", dirs.Length > 200 ? JsonValue.Create(offset + 200) : null));
        }
        catch (UnauthorizedAccessException) { throw new ApiException(403, "directory_forbidden", "当前主机用户无权读取该目录。"); }
        catch (IOException) { throw new ApiException(409, "directory_unavailable", "目录已变化或暂时无法读取，请重试。"); }
    }

    public static JsonObject Create(CreateDirectoryRequest request)
    {
        var parent = Existing(request.ParentPath);
        var name = request.Name?.Trim();
        if (string.IsNullOrEmpty(name) || name is "." or ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Contains('/') || name.Contains('\\'))
            throw new ApiException(400, "invalid_directory_name", "请输入单个文件夹名称，不包含路径分隔符。");
        var path = Path.Combine(parent, name);
        if (Path.Exists(path)) throw new ApiException(409, "directory_exists", "此名称已存在，请选择其他名称。");
        try { Directory.CreateDirectory(path); }
        catch (UnauthorizedAccessException) { throw new ApiException(403, "directory_forbidden", "当前主机用户无权在此创建目录。"); }
        catch (IOException) { throw new ApiException(409, "directory_unavailable", "无法创建目录，请刷新后重试。"); }
        return Json.Object(("path", path));
    }
}
