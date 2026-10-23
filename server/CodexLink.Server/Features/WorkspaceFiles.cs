namespace CodexLink.Server.Features;

public static class WorkspaceFiles
{
    // Resolve every component, so an in-project symlink cannot expose a file
    // outside the directory authorized by the thread's own Codex metadata.
    private static string Canonical(string path)
    {
        var full = Path.GetFullPath(path);
        var current = Path.GetPathRoot(full)!;
        foreach (var part in full[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            FileSystemInfo info = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            if (info.LinkTarget is not null) current = info.ResolveLinkTarget(true)?.FullName
                ?? throw new ApiException(404, "file_missing", "文件链接已失效。");
        }
        return Path.TrimEndingDirectorySeparator(current);
    }

    public static string Resolve(string root, string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 4096 || path.Contains('\0'))
            throw new ApiException(400, "invalid_path", "文件路径无效。");
        if (path.StartsWith("sandbox:", StringComparison.Ordinal)) path = path[8..];
        if (path.StartsWith("file:", StringComparison.Ordinal) && Uri.TryCreate(path, UriKind.Absolute, out var uri)) path = uri.LocalPath;
        var target = Canonical(Path.IsPathFullyQualified(path) ? path : Path.Combine(root, path));
        var allowed = Canonical(root);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!target.StartsWith(Path.EndsInDirectorySeparator(allowed) ? allowed : allowed + Path.DirectorySeparatorChar, comparison))
            throw new ApiException(403, "file_outside_workspace", "只能访问此会话工作目录内的文件。");
        if (!File.Exists(target)) throw new ApiException(404, "file_missing", "文件不存在或已被移动。");
        return target;
    }

    public static string ContentType(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".webp" => "image/webp",
        ".gif" => "image/gif", ".svg" => "image/svg+xml", ".pdf" => "application/pdf",
        ".txt" or ".md" or ".json" or ".dart" or ".cs" or ".yaml" or ".yml" or ".log" => "text/plain; charset=utf-8",
        _ => "application/octet-stream"
    };
}
