# 服务端

`CodexLink.Server` 是一个 .NET 10 Minimal API 可执行项目，默认发布 Native AOT，JSON 使用源生成，反射序列化回退关闭。MSBuild SDK 使用固定版本 `StuDev.AotAnywhere`。

代码按实际职责分组：

- `Codex/CodexRpc.cs`：官方共享 Unix WebSocket/自有 stdio 两种传输、RPC 请求配对、审批、事件与有限重启。
- `Realtime/EventHub.cs`：WebSocket、8 MiB/5 分钟重放、每连接 4 MiB/512 帧队列，慢连接重同步。
- `Features/SessionService.cs`：全部本机会话、保留原配置的恢复、turn/steer、Goal、项目内执行互斥。
- `Features/AttachmentStore.cs`：流式上传、图片识别、归属、容量、保留和显式清理。
- `Features/ComposerCatalog.cs`：skills、工作区文件搜索、MCP 目录和提交引用校验。
- `Features/MediaStore.cs` / `WorkspaceFiles.cs`：图片结果规范化、512 MiB/24 小时预览缓存、路径和符号链接边界。
- `Web/EmbeddedWeb.cs` / `FlutterWeb.targets`：Debug/Release 网页在构建时嵌入，流式返回，无运行时解包。
- `Features/Operations.cs`：设备内 requestId 去重和未知结果查询，1024 项/30 分钟。
- `Features/AccountUsage.cs`：官方账号统计与额度，60 秒缓存、账号变化失效。
- `Security/DeviceAuth.cs`：设备令牌摘要、Cookie/Bearer、同源检查与登录限流。

主机配置和附件元数据为小型 JSON 文件；会话历史由 Codex 提供。没有 SQLite/ORM，也不扫描 Codex 私有日志。

```bash
dotnet build server/CodexLink.Server -c Release
python3 scripts/build-release.py --rids linux-musl-x64
```

设置 `CODEXLINK_DATA` 选择状态目录；`CODEXLINK_WEB_ROOT` 可覆盖 Web 目录，默认直接使用可执行文件内嵌资源。默认监听 `0.0.0.0:47821`，启动输出 GUI 登录密钥和所有 IPv4 访问地址；远程 HTTPS 代理须配置 `publicOrigin`。

读请求可以取消；已受理的写操作不与 HTTP 断开绑定。轮次超时或 Codex 退出后不自动重发。去重记录和事件重放只在当前网关进程有效。

已验证共享服务 0.157.1 的 `thread/turns/list` 可获取订阅之前已开始的活动轮次；独立 CLI 0.163.0 对该 RPC 返回不支持，因此 stdio 使用实时事件/恢复响应状态。历史采用 `thread/items/list` 分页，恢复时订阅用量通知。不要未经运行验证就仅凭 schema 启用接口。

正式分发使用根目录发布脚本：Linux 在固定 Alpine 容器中以原生 clang 静态链接 musl/OpenSSL、去除 ICU；Windows 由 AotAnywhere 交叉编译。Flutter Web 先构建一次，容器经 `PrebuiltFlutterWebDirectory` 只读嵌入该产物，普通 Debug/Release build 仍自动生成 Web。详细参数见根 README 和 [Native AOT 说明](../docs/native-aot.md)。
