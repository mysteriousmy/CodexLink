using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace CodexLink.Server.Features;

public static class GatewayVersion
{
    public static JsonObject Read()
    {
        var version = typeof(GatewayVersion).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0];
        var platform = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsLinux() ? "linux"
            : OperatingSystem.IsMacOS() ? "macos" : "unknown";
        var architecture = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
        return Json.Object(("version", version), ("platform", platform), ("architecture", architecture),
            ("packageTarget", platform is "linux" or "windows" && architecture is "x64" or "arm64"
                ? $"{platform}-{architecture}" : null));
    }
}
