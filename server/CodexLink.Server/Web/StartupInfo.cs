using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace CodexLink.Server.Web;

public static class StartupInfo
{
    public static IPAddress[] LocalAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address)
        .Where(a => !a.IsIPv6LinkLocal).Append(IPAddress.Loopback).Distinct().ToArray();

    public static bool PrivateAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address)) return true;
        var bytes = address.GetAddressBytes();
        return address.AddressFamily == AddressFamily.InterNetwork
            ? bytes[0] == 10 || bytes[0] == 192 && bytes[1] == 168 || bytes[0] == 172 && bytes[1] is >= 16 and <= 31 ||
              bytes[0] == 169 && bytes[1] == 254 || bytes[0] == 100 && bytes[1] is >= 64 and <= 127
            : (bytes[0] & 0xfe) == 0xfc;
    }

    public static bool IsPrivateHttp(HttpContext context, Configuration config)
    {
        if (context.Request.IsHttps || config.Value.PublicOrigin is not null || context.Connection.RemoteIpAddress is not { } remote || !PrivateAddress(remote)) return false;
        var host = context.Request.Host.Host.Trim('[', ']');
        if (host == "localhost") return IPAddress.IsLoopback(remote);
        return IPAddress.TryParse(host, out var address) && PrivateAddress(address) && LocalAddresses().Contains(address);
    }

    public static void Print(Configuration config)
    {
        var listen = new Uri(config.Value.ListenUrl);
        var wildcard = listen.Host is "0.0.0.0" or "[::]" or "::";
        var addresses = wildcard ? LocalAddresses().Where(a => listen.Host != "0.0.0.0" || a.AddressFamily == AddressFamily.InterNetwork)
            .Select(a => new UriBuilder(listen.Scheme, a.ToString(), listen.Port).Uri.AbsoluteUri).ToArray() : [listen.AbsoluteUri];
        Console.WriteLine("\nCodexLink 网页访问地址：");
        foreach (var address in addresses) Console.WriteLine("  " + address);
        if (config.Value.PublicOrigin is { } origin) Console.WriteLine("  " + origin);
        var file = Path.Combine(config.DataDirectory, "access-token.txt");
        var token = File.Exists(file) ? File.ReadAllText(file).Trim() : null;
        // Explicit product requirement: show the existing GUI key on the startup
        // console. Never put it into URLs or per-request diagnostic messages.
        if (token is not null && config.Value.Devices.Any(d => d.TokenHash == Configuration.HashToken(token)))
            Console.WriteLine("GUI 登录密钥：" + token);
        else Console.WriteLine("GUI 登录密钥：使用已有设备密钥；需要新密钥时运行 --create-token。");
        Console.WriteLine();
    }
}
