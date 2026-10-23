# CodexLink 服务端发布包

[English](README.md) | [简体中文](README.zh-CN.md)

本包为 .NET 10 Native AOT 单文件网关，Flutter 网页、CanvasKit 和字体均在可执行文件中。运行时不需要 .NET，也不需要旁置网页目录；需要自行安装、登录 Codex CLI，并满足 Codex 自身的运行依赖。

## 包内文件及放置位置

| 文件 | 用途与位置 |
| --- | --- |
| `CodexLink.Server` / `CodexLink.Server.exe` | Linux 可放 `~/.local/opt/codexlink` 或 `/opt/codexlink`；Windows 可放 `C:\Tools\CodexLink`。 |
| `config.example.json` | 设置格式参考；真实 `config.json` 由 `--init` 在私有状态目录生成。 |
| `access-token.example.txt` | 明文密钥文件格式占位，不含可用密钥。 |
| `devices.example.json` | 配置中 devices 数组的字段示例，摘要占位不可用于登录。 |
| `install-systemd.sh` | 系统服务安装/更新脚本，默认 `/opt/codexlink` 和 `/var/lib/codexlink`。 |
| `codexlink.service` | Linux 用户级服务模板，放 `~/.config/systemd/user/`。 |
| `codexlink.system.service` | Linux 系统级服务模板，先替换 `YOUR_USER`。 |
| `build-info.json` | 版本、架构、AOT/UPX 状态、压缩前后体积及 SHA-256。 |
| `LICENSE`、`THIRD_PARTY_NOTICES.md`、`licenses/` | 项目与第三方许可，分发时保留。 |

程序与私有状态分开放置。不要把密钥占位文件复制为真实 `access-token.txt`，升级时不要覆盖已有状态。

建议状态位置：Linux 用户服务 `~/.local/share/codexlink`；Linux 系统服务 `/var/lib/codexlink`；Windows `%LOCALAPPDATA%\CodexLink`。通过 `CODEXLINK_DATA` 显式指定；省略时使用系统 LocalApplicationData 下的 `codexlink`。

## Linux 首次运行

`uname -m` 为 `x86_64` 选 linux-x64，为 `aarch64` 选 linux-arm64。两个 Linux 包均为 **musl 完全静态链接 Native AOT**，OpenSSL 静态链接，ICU 已移除。`ldd ./CodexLink.Server` 显示非动态可执行文件；无需 .NET、libc 加载器或共享 OpenSSL 库。命名时区依赖系统 `tzdata`，HTTPS 证书验证使用 `ca-certificates`，需要时安装这两个数据包。Codex 是独立前置程序，有自身运行要求。

```bash
chmod +x ./CodexLink.Server
codex --version
# 先通过 Codex CLI 完成登录。
export CODEXLINK_DATA="$HOME/.local/share/codexlink"
./CodexLink.Server --init
./CodexLink.Server
```

每个全新状态目录仅初始化一次。初始化生成 32 字节随机令牌，以 64 位十六进制字符串写入 `access-token.txt`，配置只保存其大写 SHA-256 摘要。

## Windows 首次运行（PowerShell）

解压完整 ZIP，以运行网关的同一账号安装并登录 Codex：

```powershell
$env:CODEXLINK_DATA = Join-Path $env:LOCALAPPDATA 'CodexLink'
.\CodexLink.Server.exe --init
notepad (Join-Path $env:CODEXLINK_DATA 'config.json')
.\CodexLink.Server.exe
```

无法发现 Codex 时，将 `codexPath` 改为原生 `codex.exe` 的绝对路径，例如 JSON 中的 `C:\\Tools\\codex\\codex.exe`。不要使用 npm 的 `codex.cmd` 脚本作为原生可执行路径。防火墙仅允许需要的私有网络。

这是控制台程序，不是 Windows Service 宿主；可前台运行，或用同一账号的任务计划程序管理，不要直接 `sc.exe create`。Windows ARM64 和 x64 是不同原生架构的包。

## 网页与 Android 连接

默认监听 `http://0.0.0.0:47821`。本机打开 `http://127.0.0.1:47821`；手机用启动时输出的主机局域网 IPv4 地址。`0.0.0.0` 是监听地址，不能作为浏览器目标。使用生成的网关密钥登录，不是 OpenAI API Key。

启动控制台会显示 GUI 登录密钥与地址，日志和 systemd journal 应作为私有凭据保管。网页用同源 HttpOnly Cookie；Android 用安全存储和 Bearer 请求头。

仅本机和私有局域网允许直接 HTTP 登录。远程访问需自行配置 HTTPS 反向代理或私网 HTTPS 入口，并将 `publicOrigin` 设为精确源，如 `https://codex.example.com`。代理需转发 WebSocket，上传限制不小于 `maxFileBytes`。只通过本机代理访问时，可将监听地址改为 `127.0.0.1`。

## 密钥管理

```bash
./CodexLink.Server --create-token --name "我的手机" --output /私有目录/phone-token.txt
./CodexLink.Server --revoke-token 设备ID
```

Windows 改用 `.\CodexLink.Server.exe` 和 Windows 私有路径。命令更新配置后退出，需要重启网关生效。新增密钥不会自动撤销旧设备；省略 `--output` 会覆盖默认的明文密钥文件。格式见 `devices.example.json`，建议使用管理命令而非手写摘要。

## systemd

默认系统级安装，在解压目录运行：

```bash
sudo ./install-systemd.sh
# 按需显式指定运行账号和原生 Codex 路径：
sudo ./install-systemd.sh --user YOUR_USER --codex /absolute/path/to/codex
```

默认取 `SUDO_USER` 为运行账号，禁止 root 账号运行服务。程序安装到 `/opt/codexlink`，私有状态放 `/var/lib/codexlink`；仅在没有配置时初始化，更新保留已有配置与密钥。旧程序和旧 unit 保存为 `.previous`，写入 `/etc/systemd/system/codexlink.service` 后启用开机自启并重启。运行账号应已登录 Codex；`--codex` 只用于首次初始化，已有配置请显式编辑。

可用 `--prefix /绝对路径`、`--data-dir /绝对路径` 修改目录；脚本路径参数限不含空格的 ASCII 路径，复杂路径请手动维护 unit。直接 root shell 没有 `SUDO_USER` 时必须传 `--user`。需要 Bash、systemd、coreutils、`getent` 和 `runuser`（通常由 util-linux 提供）。脚本不安装或登录 Codex。用 `sudo systemctl status codexlink.service` 查看状态，journal 中的 GUI 密钥须保密。

用户级安装：程序放 `~/.local/opt/codexlink/`，初始化 `~/.local/share/codexlink`，然后：

```bash
mkdir -p "$HOME/.config/systemd/user"
cp codexlink.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now codexlink
systemctl --user status codexlink
```

系统级安装：程序放 `/opt/codexlink/CodexLink.Server`；替换系统模板中所有 `YOUR_USER`，以该账号初始化 `/var/lib/codexlink`，将模板安装为 `/etc/systemd/system/codexlink.service`，执行 `systemctl daemon-reload` 和 `systemctl enable --now codexlink`。该账号必须拥有状态目录及 Codex 登录。不要同时运行两个模板占用同一端口；服务 PATH 不同于终端时配置绝对 `codexPath`。

Linux 状态目录/文件权限为 `0700`/`0600`；Windows 使用私有账号目录及适当 ACL。不要为了访问 Codex 而以 root 运行网关。

## 升级、备份与体积优化

停止服务，仅替换程序文件，保留完整 `CODEXLINK_DATA`，然后重启。网关配置、密钥与附件需要单独备份；Codex 会话数据由 Codex 自己管理。

Linux 和 Windows x64 可执行文件已用 UPX 压缩；Windows ARM64 因 UPX 不支持 ARM64 PE 保留未压缩 AOT，详见 `build-info.json`。系统策略不允许压缩程序时，可用 `--no-upx` 重建，或对副本运行 `upx -d`。Windows 包没有 Authenticode 签名。

Release 优先体积，裁掉托管堆栈元数据与调试器支持，框架异常使用资源键；业务错误仍保留，需要完整托管堆栈时编译 Debug。Linux 使用 invariant globalization，移除 ICU 及区域特定的排序/格式化；UTF-8 中文、JSON、HTTPS 和 WebSocket 仍可用。IANA 时区使用系统 tzdata；Windows 保留平台国际化支持。

优先连接已有兼容 Codex daemon，否则启动自己的 stdio 子进程。停止网关不会结束共享 daemon，但会停止自己持有的 stdio 子进程。事件重放、审批和 requestId 去重为进程内缓存；重启后先核对未知结果，不盲目重复提交。

完整源码、介绍与本地编译：https://github.com/mysteriousmy/CodexLink
