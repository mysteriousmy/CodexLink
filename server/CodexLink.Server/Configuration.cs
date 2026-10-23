using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexLink.Server;

public sealed record ProjectConfig(string Id, string Name, string Path);
public sealed record DeviceConfig(string Id, string Name, string TokenHash);
// Source-generated JSON uses setters so omitted fields keep these defaults.
public sealed record GatewayConfig
{
    public string ListenUrl { get; set; } = "http://0.0.0.0:47821";
    public string? PublicOrigin { get; set; }
    public string CodexPath { get; set; } = "codex";
    public string[] CodexArguments { get; set; } = ["app-server", "--listen", "stdio://"];
    public bool PreferSharedDaemon { get; set; } = true;
    public string? CodexSocketPath { get; set; }
    public DeviceConfig[] Devices { get; set; } = [];
    public long MaxFileBytes { get; set; } = 25 * 1024 * 1024;
    public long MaxStorageBytes { get; set; } = 1024L * 1024 * 1024;
    public string TimeZone { get; set; } = TimeZoneInfo.Local.Id;
}

public sealed class Configuration(string dataDirectory, GatewayConfig value)
{
    public string DataDirectory { get; } = dataDirectory;
    public GatewayConfig Value { get; } = value;
    public ProjectConfig ProjectForPath(string path)
    {
        if (!System.IO.Path.IsPathFullyQualified(path)) throw new ApiException(409, "invalid_thread_directory", "Codex 会话没有有效的工作目录。");
        var full = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path));
        return new ProjectConfig("local-" + HashToken(OperatingSystem.IsWindows() ? full.ToUpperInvariant() : full)[..16],
                new DirectoryInfo(full).Name, full);
    }

    public static string HashToken(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    public static async Task<Configuration?> LoadOrManageAsync(string[] args)
    {
        var dir = Environment.GetEnvironmentVariable("CODEXLINK_DATA")
            ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "codexlink");
        dir = System.IO.Path.GetFullPath(dir);
        Directory.CreateDirectory(dir);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var file = System.IO.Path.Combine(dir, "config.json");
        var config = File.Exists(file)
            ? JsonSerializer.Deserialize(await File.ReadAllTextAsync(file), JsonContext.Default.GatewayConfig)!
            : new GatewayConfig();
        string? Arg(string name) => Array.IndexOf(args, name) is var i && i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        if (args.Contains("--init"))
        {
            if (File.Exists(file)) throw new InvalidOperationException($"配置已存在：{file}。请编辑它或使用 --create-token。");
        }
        if (args.Contains("--init") || args.Contains("--create-token"))
        {
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            var id = Guid.NewGuid().ToString("N");
            config = config with { Devices = [.. config.Devices, new(id, Arg("--name") ?? "我的设备", HashToken(token))] };
            await WritePrivateAsync(file, JsonSerializer.Serialize(config, JsonContext.Default.GatewayConfig));
            var tokenFile = System.IO.Path.GetFullPath(Arg("--output") ?? System.IO.Path.Combine(dir, "access-token.txt"));
            await WritePrivateAsync(tokenFile, token + "\n");
            Console.WriteLine($"配置：{file}\n访问密钥已写入：{tokenFile}\n设备 ID：{id}\n密钥仅用于连接 CodexLink，不是 Codex 账号密钥。");
            return null;
        }
        if (Arg("--revoke-token") is { } revoke)
        {
            config = config with { Devices = config.Devices.Where(d => d.Id != revoke).ToArray() };
            await WritePrivateAsync(file, JsonSerializer.Serialize(config, JsonContext.Default.GatewayConfig));
            Console.WriteLine("设备已移除；重启网关后生效。");
            return null;
        }
        if (!File.Exists(file) || config.Devices.Length == 0)
            throw new InvalidOperationException("请先运行 --init，生成配置和访问密钥。");
        if (config.MaxFileBytes <= 0 || config.MaxStorageBytes < config.MaxFileBytes) throw new InvalidOperationException("附件容量配置无效。");
        _ = TimeZoneInfo.FindSystemTimeZoneById(config.TimeZone);
        return new Configuration(dir, config);
    }

    public static async Task WritePrivateAsync(string path, string content)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Options = FileOptions.Asynchronous };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            await using (var stream = new FileStream(temporary, options))
            await using (var writer = new StreamWriter(stream)) await writer.WriteAsync(content);
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
