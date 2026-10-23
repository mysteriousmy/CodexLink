# Native AOT 与发布构建

服务端使用 .NET 10 Minimal APIs、`CreateSlimBuilder`、原生 WebSocket 和 System.Text.Json 源生成。禁用 JSON 反射回退，完整裁剪与 AOT 警告作为错误处理，不依赖动态程序集、运行时代理、MVC 或 ORM。

## 两条构建路径

| 路径 | 命令 | 说明 |
| --- | --- | --- |
| 正式发布 | `python3 scripts/build-release.py --all --android` | Linux musl 完全静态、Windows AOT，UPX、双语部署说明、密钥占位模板、APK、SHA256SUMS |
| 普通 AOT | `python3 scripts/build-aot.py --rids linux-x64 --configuration Debug` | 保留常规 glibc/Windows 工具链，Debug/Release，无 Docker/UPX |

正式发布输出 `artifacts/v<版本>/`；普通 AOT 输出 `artifacts/aot/<配置>/<RID>/`，不会互相覆盖。Bash 包装脚本分别为 `build-release.sh`、`build-aot.sh`，Windows 使用 Python 入口。

## Linux 静态 musl

实际 RID 为 `linux-musl-x64` / `linux-musl-arm64`，对外压缩包名保留 `linux-x64` / `linux-arm64`。固定摘要的 Alpine SDK 10.0.402 容器安装 clang、构建工具、OpenSSL 静态库与 zlib 静态库。每个架构原生构建；x64 主机上的 ARM64 容器需要 binfmt/QEMU。

MSBuild 在 musl RID 下启用：

- `StaticExecutable=true`、`PositionIndependentExecutable=false`。
- `StaticOpenSslLinking=true`，使用 SDK 的原生加密 shim 构建流程。
- `DirectPInvoke Include="libc"`，避免 libc 的延迟动态加载。
- `InvariantGlobalization=true`，按发布需求移除 ICU。

容器以匹配的构建用户运行，只挂载最小服务端源码、只读 Web 产物、构建缓存和输出；不挂载用户 HOME、正式运行状态或 Android 签名。容器使用原生 clang 工具链，通过 `UseNativeAotToolchain=true` 跳过 AotAnywhere 导入。主机普通构建仍固定 SDK 10.0.302。

压缩前后都用 `readelf -l` / `readelf -d` 检查不存在 ELF INTERP 或 NEEDED，并打印 `ldd` 结果。静态链接检查还需配合运行测试，因为 `ldd` 本身不能证明不存在代码中的 `dlopen` 路径。

没有动态库依赖不等于包含整个宿主环境：Codex 是独立程序；命名时区使用 tzdata，HTTPS 证书校验使用信任库。UTF-8 中文与 JSON 不依赖 ICU；区域特定排序/格式化被移除。Windows 保留平台国际化支持与时区映射。

## 常规 AOT 与 Windows

普通 glibc Linux / Windows 构建保留 StuDev.AotAnywhere 1.1.0，按 MSBuild SDK 的 props/targets 导入，版本在 `global.json` 中固定；它会恢复配套 Zig。此处显式导入以便 Alpine 原生构建条件性跳过该 SDK，不使用普通 PackageReference 代替其工具链恢复流程。

Windows x64/ARM64 是完整产品 AOT 产物，编译与运行结果分开记录。UPX 支持 Windows x64，不支持 ARM64 PE；后者保留未压缩 AOT。Windows ZIP 本身仍使用 Deflate 压缩。交叉链接不会消除平台差异，也不能代替真实 Windows 硬件测试。上游注明跨 Windows 链接不保留部分 MSVC CFG/CET 标记，包没有 Authenticode 签名。

## 体积优化

Release 开启 `TrimMode=full`、`OptimizationPreference=Size`、相同方法折叠、IlcDehydrate，关闭托管堆栈元数据、Debugger、MetadataUpdater、EventSource、无用编码/旧序列化支持，框架异常改用资源键。Debug 保留诊断能力，不将 Debug 大小或速度作为 Release 性能结论。

Flutter bootstrap 固定通用 CanvasKit；内嵌时排除 Chromium/WebParagraph/Skwasm/Wimp 变体、`.symbols` 和 source map，保留必要字体及许可证。`upx --best --lzma` 后运行 `upx -t`，各包 `build-info.json` 记录压缩前后字节数与 SHA-256。

## Web 内嵌

`FlutterWeb.targets` 在 `AssignTargetPaths` 前动态加入 EmbeddedResource，保留资源相对路径。普通 Debug/Release 构建自动产生对应 Web，使用输入文件清单/时间戳跟踪变更，并登记 FileWrites。

发布脚本先构建一次 Release Web，再通过 `PrebuiltFlutterWebDirectory` 给各架构只读复用；目标会校验 Web 主文件和 CanvasKit 存在。预构建目录不登记为 MSBuild 所有的清理产物。运行时直接流式返回内嵌资源，不落地解包、不依赖旁置 wwwroot。

## 验证与限制

已有 Linux 产品验证覆盖 32 项网关黑盒契约、真实 Codex 的附件/steer/Goal/用量，以及 Android/Web；详细证据和最新发布产物检查见 [验证记录](verification.md)。正式发布要求测试实际压缩后的产物，并区分本机运行、QEMU/Wine 模拟和仅编译。没有 macOS/iOS 发布包。

AOT 可以改善部署和启动，并不保证所有长期吞吐高于 JIT；模型生成耗时也不属于网关优化结果。长时间负载、真实手机网络和不同附件体积的内存曲线仍需持续验证。

## 参考

- [ASP.NET Core Native AOT](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot?view=aspnetcore-10.0)
- [.NET Native AOT 编译实现与说明](https://github.com/dotnet/runtime/tree/v10.0.0/src/coreclr/nativeaot)
- [System.Text.Json 源生成](https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation)
- [AotAnywhere 支持矩阵](https://github.com/StuDevLabs/AotAnywhere)
- [musl 静态 Native AOT 构建参考](https://www.cnblogs.com/hez2010/p/18813775/dotnet-nativeaot-distroless-statically-linked-app)
