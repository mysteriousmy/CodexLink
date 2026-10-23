# CodexLink server package

[English](README.md) | [简体中文](README.zh-CN.md)

A self-contained .NET 10 Native AOT gateway with the Flutter web client, CanvasKit and fonts embedded in the executable. You do **not** need the .NET runtime or a separate web directory. You **do** need a separately installed and authenticated Codex CLI, plus any OS data and dependencies needed by Codex itself.

## Package contents and placement

| File | Purpose / where to put it |
| --- | --- |
| `CodexLink.Server` / `CodexLink.Server.exe` | Executable. Linux: a user-owned app directory, or `/opt/codexlink`. Windows: e.g. `C:\Tools\CodexLink`. |
| `config.example.json` | Settings reference only. `--init` generates your real `config.json` in the state directory. |
| `access-token.example.txt` | Describes the single-line plaintext token file; it contains no usable key. |
| `devices.example.json` | Describes entries in `config.json` → `devices`. The placeholder is not a valid digest. |
| `install-systemd.sh` | Install/update a system service; defaults to `/opt/codexlink` + `/var/lib/codexlink`. |
| `codexlink.service` | Optional Linux **user** systemd unit. Install to `~/.config/systemd/user/`. |
| `codexlink.system.service` | Optional Linux **system** unit template. Replace `YOUR_USER` before installing. |
| `build-info.json` | Architecture, version, Native AOT/UPX status, original/final binary size and SHA-256. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md`, `licenses/` | Project license and third-party notices. Keep them when redistributing. |

Keep **program files** and **private state** separate. Never copy the example key into a live `access-token.txt` and never overwrite an existing state directory during upgrades.

Recommended state locations:

- Linux user service: `~/.local/share/codexlink`.
- Linux system service: `/var/lib/codexlink`, owned by the non-root account running Codex.
- Windows: `%LOCALAPPDATA%\CodexLink`.
- Override with the `CODEXLINK_DATA` environment variable. Without an override the program uses the OS local application-data directory followed by `codexlink`.

## Linux quick start

Use the archive matching `uname -m`: `x86_64` → linux-x64; `aarch64` → linux-arm64. Both Linux packages are **fully static musl Native AOT** executables, with statically linked OpenSSL and no ICU. `ldd ./CodexLink.Server` reports that it is not a dynamic executable. They run on compatible Linux kernels without a .NET runtime, libc loader or shared OpenSSL library. Named time zones use OS `tzdata`, and HTTPS certificate validation uses `ca-certificates`; install these data packages when needed. Codex is a separate prerequisite with its own requirements.

```bash
chmod +x ./CodexLink.Server
codex --version
# Complete Codex login using the Codex CLI first.
export CODEXLINK_DATA="$HOME/.local/share/codexlink"
./CodexLink.Server --init
./CodexLink.Server
```

Run `--init` only once per new state directory. It generates a random 32-byte token represented by 64 hexadecimal characters. It writes the plaintext to `access-token.txt` and only its uppercase SHA-256 digest to `config.json`.

## Windows quick start (PowerShell)

Extract the complete ZIP. Install and sign in to Codex as the same Windows user that will run the gateway.

```powershell
$env:CODEXLINK_DATA = Join-Path $env:LOCALAPPDATA 'CodexLink'
.\CodexLink.Server.exe --init
notepad (Join-Path $env:CODEXLINK_DATA 'config.json')
.\CodexLink.Server.exe
```

If Codex is not discoverable, set `codexPath` to the absolute path of the native **`codex.exe`**, for example `C:\\Tools\\codex\\codex.exe` in JSON. An npm `codex.cmd` shim is not a native executable and should not be used as `codexPath`. Windows firewall access, if needed, should be limited to your intended private network.

This executable is a console program, not a Windows Service host. Use an interactive console or a Task Scheduler task running under your Codex user. Do not register it directly with `sc.exe create`. Windows ARM64 is a native ARM64 package; Windows x64 is a separate x64 package.

## Connect a browser or Android client

The default listener is `http://0.0.0.0:47821`. Open `http://127.0.0.1:47821` on the host, or a printed LAN IPv4 address from your phone. `0.0.0.0` is a bind address, not a browser destination. Use the generated gateway token to log in. This is **not** your OpenAI API key.

The startup console prints the active GUI login key and interface URLs. Console logs and systemd journal output therefore contain a credential; keep them private. Web authentication uses an HttpOnly same-origin cookie. Android uses protected token storage and a Bearer header.

Only loopback/private-LAN HTTP login is supported directly. For remote access, put the server behind your own HTTPS reverse proxy or private-network HTTPS endpoint, and set `publicOrigin` to the exact browser origin, e.g. `https://codex.example.com`. Forward WebSocket upgrades and allow uploads at least as large as `maxFileBytes`. Binding only to `127.0.0.1` is appropriate when a local proxy is the sole entry point.

## Token management

```bash
./CodexLink.Server --create-token --name "My phone" --output /private/path/phone-token.txt
./CodexLink.Server --revoke-token DEVICE_ID
```

On Windows use `.\CodexLink.Server.exe` and a private Windows path. Management commands exit after updating configuration; restart the gateway for changes to take effect. `--create-token` without `--output` updates the default `access-token.txt` but does not revoke earlier device entries. The `devices.example.json` file explains the structure; use the commands instead of hand-writing hashes.

## Optional systemd services

For the default **system service**, run from the extracted Linux package:

```bash
sudo ./install-systemd.sh
# Explicit account/native Codex path when needed:
sudo ./install-systemd.sh --user YOUR_USER --codex /absolute/path/to/codex
```

The script uses `SUDO_USER` by default, requires a non-root Codex account, installs the executable at `/opt/codexlink`, and keeps private state in `/var/lib/codexlink`. It generates credentials only if configuration is absent, preserves existing configuration/tokens on upgrades, saves the previous executable/unit, installs `/etc/systemd/system/codexlink.service`, enables startup and restarts the service. The selected account should already be logged in to Codex. `--codex` is applied only during first initialization; edit an existing `config.json` explicitly if changing that path.

Optional `--prefix /absolute/path` and `--data-dir /absolute/path` change the two directories. Paths with spaces require a manually maintained unit. Root shells without `SUDO_USER` must supply `--user`. The installer needs Bash, systemd, standard coreutils, `getent` and `runuser` (normally util-linux); it does not install Codex or authenticate it for you. Review `sudo systemctl status codexlink.service`; journal output contains the GUI token.

For a **user service**, copy the executable to `~/.local/opt/codexlink/`, initialize `~/.local/share/codexlink`, then:

```bash
mkdir -p "$HOME/.config/systemd/user"
cp codexlink.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now codexlink
systemctl --user status codexlink
```

For a **system service**, install the binary at `/opt/codexlink/CodexLink.Server`, edit every `YOUR_USER` in `codexlink.system.service`, initialize `/var/lib/codexlink` as that account, and install the unit as `/etc/systemd/system/codexlink.service`. The account must own the state directory and have access to its Codex login. Use `systemctl daemon-reload` then `systemctl enable --now codexlink`. Never run both templates on the same port. Set an absolute `codexPath` if the service PATH differs from your shell.

Linux state directories/files are created as `0700`/`0600`. On Windows, use a private user directory and appropriate Windows ACLs. Do not run the gateway as root just to access Codex.

## Updating, backups and size options

Stop the gateway, replace only its program files, retain the complete `CODEXLINK_DATA`, then restart. Back up that state directory separately from Codex's own conversation data. The gateway stores configuration and attachments; it does not copy the Codex conversation database.

Linux and Windows x64 release binaries are UPX-packed. Windows ARM64 is not, because UPX has no ARM64 PE support. `build-info.json` records this precisely. If local security policy rejects packed executables, rebuild with `--no-upx` or use `upx -d` on a copy. Official Windows packages are not Authenticode-signed.

Release builds favor size, omit managed stack-trace metadata/debugger support and use framework resource keys. Application error messages remain available, but detailed managed stack traces require a Debug build. Linux uses invariant globalization: ICU and culture-specific formatting/collation are omitted; UTF-8 Chinese text, JSON, HTTPS and WebSockets remain supported. IANA time zones use OS tzdata. Windows retains platform globalization support.

The gateway attaches to an existing compatible Codex daemon when available; otherwise it owns a stdio app-server subprocess. Stopping the gateway leaves a shared daemon running; stopping a gateway-owned stdio process may interrupt its work. Replay, approval and request-deduplication caches are memory-only, so check unknown operations after a restart instead of blindly resubmitting them.

Source, full usage and local builds: https://github.com/mysteriousmy/CodexLink
