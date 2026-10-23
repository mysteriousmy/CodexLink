# 实施与验收记录

日期：2026-10-23。当前达到本机可运行、Android/Web 可用的阶段；外网入口与实机网络验证仍需部署条件。

## 环境与产物

- Linux x64（CachyOS），.NET SDK 10.0.302 / runtime 10.0.10，Codex CLI 0.163.0，共享 app-server 0.157.1。
- Flutter 3.47.5 / Dart 3.13.4；Web release，Android release 个人签名。
- `artifacts/linux-x64/`：内嵌 Flutter Web 的 Native AOT ELF 单文件可执行程序和示例配置。
- `artifacts/android/`：arm64-v8a、armeabi-v7a、x86_64 APK；`apksigner verify` 通过，签名为 `CodexLink Personal`。
- iOS 工程及 Keychain entitlement 已配置；当前 Linux 不能执行 Apple 签名/真机验证。

## 自动验证

服务端使用独立 Python stdio / Unix WebSocket 替身，不访问真实账号、不调用模型；同一黑盒套件可针对 Managed DLL 或已发布原生二进制。最终 Release 与 Debug 原生版本各通过 **32 项**测试。Flutter 通过 **36 项**单元/Widget 测试与 **2 项** Chrome 剪贴板测试；`flutter analyze` 无问题。

| Requirement | Evidence |
| --- | --- |
| 手机会话列表获得主要高度，菜单/筛选/账号仍可访问 | `mobile_sidebar_prioritizes_threads`：390×690、320×568、字体 1.2 倍时列表均占可用高度超过 70%，至少 5 条可点击，键盘缩小后不溢出；浏览器 390×690 实际可见约 7 条 |
| 网页剪贴板文件和图片上传，保留普通文本粘贴 | Chrome `clipboard_files_replace_path_text_once`、`clipboard_plain_text_and_unfocused_editor_keep_default_behavior`；浏览器 `browser_clipboard_files_images_and_plaintext`：文件字节一致、真实 Ctrl+V 图片上传 201、原草稿保留、普通文本追加且无重复上传 |
| App 系统返回先回会话列表并保留草稿 | `system_back_returns_to_list_and_preserves_draft`；新 Android APK 的 `android_system_back_returns_to_thread_list`、`android_back_closes_keyboard_first`、`android_back_preserves_draft_on_reentry`：先收键盘、再回列表，重进保留草稿 |
| Codex 原生项目读取/创建同步、目录选取 | `test_codex_projects`；`test_project_creation`；`test_directory_navigation`；`test_directory_thread`；`test_startup_without_gateway_projects`；Flutter `Codex project selection uses native identity and root`、`host directory picker navigates parents and confirms cwd`、`creating project saves to Codex before starting its thread` |
| 网页字体不再反复请求 CDN | 浏览器 `web_console_no_external_fonts`：阻断字体 CDN 后，真实图片和长会话外部资源 0、控制台错误 0；`test_web_is_embedded_with_correct_types_and_no_sidecar` 验证 4 种字体均由内嵌资源提供 |
| 输入框 Goal 开关，发送执行/取消与提交失败保留 | Flutter `composer goal toggle submits draft only on send and supports pause`；`goal send preserves rejected drafts and cancels back to normal messages`；`uncertain goal submission reconciles native state without resending`；`goal submission keeps newer text and does not silently consume references` |
| 历史 Goal 隐藏、输入框上方简栏与图标操作 | Flutter `completed goal is hidden and active goal has compact icon controls` |
| 中途/最终 Diff 与全屏彩色内容 | Flutter `diff parsing distinguishes additions deletions hunks and line numbers`；`live and final turn diff stays available with history fallback`；`file click opens full screen colored diff` |
| 会话自动加载下一页 | Flutter `thread list scroll automatically loads the next page once` |
| 历史自动加载并保留阅读位置 | Flutter `older messages load on upward scroll and preserve reading position` |
| 默认全 IPv4 监听、启动密钥/地址、局域网登录 | `test_init_defaults_to_all_ipv4_interfaces`；`test_startup_prints_gui_key_and_interface_urls`；`test_private_lan_login_and_unassigned_host_rejection` |
| 全部目录会话、分页、原会话接续、保留运行配置 | `test_all_threads_pagination_filter_and_existing_external_workspace`；`test_shared_attach_preserves_running_turn_and_owner_survives_gateway` |
| 另一客户端审批完成同步、空共享线程 | `test_other_client_approval_resolution_removes_pending_request`；`test_new_shared_thread_snapshot_does_not_query_unmaterialized_turns` |
| 归档与显式恢复 | `test_archived_thread_is_read_only_until_unarchived` |
| 指令使用真实技能/文件/MCP，拒绝伪造技能 | `test_skills_files_and_mcp_use_real_protocol_and_validate_selection`；Flutter `slash commands open features without submitting prompt text` |
| 原生 Goal 明确入口和按钮交互 | Flutter `composer goal toggle submits draft only on send and supports pause` |
| 图片转二进制、SVG、文件访问边界 | `test_media_is_binary_not_base64_text_and_workspace_links_are_guarded` |
| 中途回复、历史同步竞态、带引用 steer | Flutter `history reload retains intermediate commentary and later final events`；`intermediate commentary renders as a separate visible message`；`skill and file selections travel with steer and clear only on acceptance` |
| 手机键盘和指令面板 | Flutter `command palette stays usable on phone with goal and keyboard` |
| 单文件内嵌 Web、JS/WASM MIME 和缓存 | `test_web_is_embedded_with_correct_types_and_no_sidecar`，Release 和 Debug AOT 都运行 |
| 旧配置省略新字段仍保留正确默认值 | `test_omitted_json_settings_keep_declared_defaults` |
| 鉴权、Cookie、来源与项目边界 | `test_auth_origin_cookie_and_allowlist` |
| 空会话与并发 RPC 不串线 | `test_empty_thread_and_concurrent_rpc_pairing` |
| requestId 去重及内容冲突 | `test_idempotency_and_conflicting_payload` |
| steer 轮次冲突、同项目执行互斥 | `test_steer_expected_turn_and_project_serialization` |
| 断线后任务继续、事件重放与 Unicode 偏移 | `test_disconnect_does_not_cancel_and_replay_has_offsets`；Flutter `snapshot plus replayed Unicode deltas never duplicate text` |
| 重放溢出与慢连接隔离 | `test_replay_overflow_requests_snapshot`；`test_slow_consumer_is_disconnected_without_blocking_rpc` |
| 附件原始字节、归属、大小、清理 | `test_attachment_binary_binding_limits_and_cleanup`；`test_images_use_local_image_input` |
| Goal 预算省略/移除、暂停、中断与项目互斥 | `test_goal_budget_omission_pause_and_interrupt`；`test_active_goal_reserves_project_and_pause_releases_it` |
| 审批重连与只处理一次 | `test_approval_survives_reconnect_and_resolves_once` |
| 用量错误保持未知、缓存不伪装成功 | `test_account_unavailable_is_not_zero_and_error_is_cached` |
| 子进程退出、未知请求与服务关闭 | `test_process_exit_leaves_operation_unknown_and_restarts`；`test_shutdown_closes_websocket_and_releases_child_promptly` |
| 统计不混用累计/上下文、缺 5h 隐藏 | Flutter `context uses latest usage and preserves unknown values`；`missing five hour quota is hidden with weekly quota and unknown today` |
| 流式局部更新、发送和切换竞态 | Flutter `100 streaming deltas repaint one item once without rebuilding page`；`accepted message preserves newer draft while request was in flight`；`HTTP 502 is uncertain and keeps the original draft`；`late project response cannot replace a newly selected project` |
| 手机/宽屏、字体放大、键盘区域 | Flutter `conversation fits 390px with larger text and keyboard`；`conversation fits 1280px with larger text and keyboard`；`desktop sidebar and chat share one screen` |

复现：根目录 `scripts/test-gateway.sh --aot`，以及 `client` 内 `flutter --no-version-check test` 和 `flutter --no-version-check test --platform chrome test/web/clipboard_test.dart`（本机需 `CHROME_EXECUTABLE=/opt/google/chrome/chrome`）。完整测试名见源码，不以覆盖率百分比代替行为证据。

## 真实 Codex 与界面验收

只在 `.local/smoke-workspace`、`.local/shared-probe/workspace` 专用工作区执行小型验收，没有让模型修改用户真实项目。

- 普通文本附件由 Codex 的文件工具读取，正确返回 `ORANGE-427`。
- 原生 Goal 自动启动并以 `complete` 结束，返回 `GOAL-OK`。
- 活跃 turn 接收携带新文件的 steer，保持同一 turn，正确返回 `STEER-OK`。
- 网关重新启动后通过 `thread/resume` 和分页历史恢复消息，恢复官方 Token/上下文用量。
- Web release 验证中文文件选择、桌面拖放、上传完成、PNG 预览、390 px 手机布局及宽屏明暗主题。
- Android release APK 安装到只读 Pixel 模拟器，登录后通过系统文件选择器上传普通文件，发送真实任务并得到 `APP-OK`。强制结束 App 后重新打开，安全存储的令牌成功恢复并重新连接。
- 官方账号今日/累计和额度接口已接通；本次当天日桶未返回时界面显示待更新，不以 0 替代。

实际发现并修复了：CLI 轮次列表 RPC 运行时不支持、旧进程关闭时写锁释放延迟、慢连接队列按字节限制与取消、发送后的草稿竞态、账号缓存失效和网页脚本升级缓存。常规中文字体由同源资源提供，避免 Google Fonts 超时影响阅读；中文 WOFF2 约 9.6 MiB，仅增加 Web 首次加载成本并可缓存。发布命令同时关闭 Flutter Web 资源 CDN，使 CanvasKit 也从网关加载。屏蔽 `fonts.gstatic.com` 与 `www.gstatic.com` 后，release 页面仍正常连接，资源记录中没有外部请求，浏览器控制台无错误。

## 本轮修订的实际检查

- 真实共享服务首页 30 条、16 个工作目录，存在下一页，未按项目/来源/提供商隐式排除。
- 新共享会话返回 `SHARED-OK`；另一独立 WebSocket 客户端先开启任务，网关按原 ID 接入并识别同一活动 turn，steer 被接受，最终返回 `SHARED-STEER-OK`。真实原生 Goal 暂停状态和 1000 Token 预算读写通过。
- 只读检查用户已有图片/SVG 会话：1 个 imageGeneration、2 个 imageView 均得到预览资源，两个会话都含 commentary。没有重跑这些用户任务。
- 浏览器实际完成 Goal 创建/暂停，技能与文件选择、提交原生 skill 和文件引用，MCP 目录、生成图片预览、SVG Markdown 链接、下载。SVG 两帧截图内容不同，证明声明式动画在运行。
- 最新 Android release APK 在模拟器打开 SVG 预览，两次间隔约 350 ms 的截图中蓝色圆心从 x≈672 移至 x≈1033，确认原生端动画实际运行；PNG 预览也已核验。
- 最终包增加约 228 KiB 本地符号字体；重新打开包含图片、SVG 和模型菜单的 release 页面，中文/等宽/符号字体都来自本网关，外部资源请求为 0，控制台错误为 0。
- Debug/Release AOT 均将 Web、CanvasKit、字体嵌入；把单个二进制复制到独立目录、没有 wwwroot，仍可访问页面和 JS/WASM。运行不解包静态资源。Native AOT/Debug UI 的 Material 父级断言已修复。
- CLI 共享进程生命周期、默认配置值和快照竞态分别有独立回归；原共享 daemon 从未被重启或停止。

## 项目与阅读体验修订验收

- 真实共享 Codex 当前有 3 个原生项目；网关列表与独立官方 WebSocket 的 project/list ID 集合一致。在专用目录创建临时项目后，另一个客户端可用 project/read 读取相同名称和 roots；新建线程返回正确 projectId/cwd。没有调用模型，验收后删除临时项目。
- 浏览器实际滚动本机会话列表到底部触发带 cursor 的下一页请求；在已有长会话上滑到历史顶部也自动触发更早 items 请求，无需点击加载按钮。
- 项目/目录选择器在浏览器展示真实主机目录，实际从主目录进入 Documents；失败目录不能继续确认。正式界面不再显示网关配置中自造的项目。
- 浏览器和新 Android release APK（Pixel 模拟器）均实际打开全屏 Diff，新增绿色、删除红色、块头和行号可辨；输入框上方暂停 Goal 简栏与纯图标按钮正常。桌面 1280×900、手机 Web 390×844 均无溢出。
- 在用户已有猫图会话中定位到外部 Noto Color Emoji 请求反复失败。增加约 1.9 MiB 内置 COLRv1 Emoji 字体后，在阻断字体 CDN 的浏览器中渲染 🐈/✅/🚀/🎨，字体全部从本网关加载；同源登录后的页面控制台错误为 0，没有外部资源请求。首次无效 Cookie 的单次 401 仍是正常的重新登录流程。
- 新的输入框 Goal 旗帜在手机 Web 实际验证：预先输入目标、开启/取消均不发请求且文字保留；点击发送后才产生一次原生 Goal PUT，成功后清空草稿并显示进行中简栏，顶部不再有目标设置按钮。Android 更新包在模拟器同样完成输入框开关与发送；服务端读回目标与输入一致，成功后输入清空、开关回到普通模式。
- Release/Debug AOT 各运行同一 32 项黑盒测试，Flutter 36 项、Chrome 剪贴板 2 项及 analyze 通过；Android 三种架构重新构建并校验个人签名。
- 正式运行实例默认 0.0.0.0:47821，启动输出已有有效 GUI 密钥与所有已启用接口的 IPv4 URL；<LAN-IP>:47821 的浏览器 Cookie 登录通过，密钥未更换，共享 Codex daemon 未重启。

## 性能记录

以下为首版基线；图片/共享传输修订不冒充同一次测量。`tests/benchmark_gateway.py` 对发布 AOT 二进制使用独立 stdio 替身：1000 个事件，间隔约 1 ms，每个事件正文 256 字符，loopback WebSocket 接收端计时。

| 指标 | 本次观测 |
| --- | --- |
| 转发 p50 | 0.202 ms |
| 转发 p95 | 0.509 ms |
| 最大值 | 4.322 ms |
| 网关 RSS，回放前 / 后 | 54.7 / 62.9 MiB |
| 替身环境启动至 API ready | 58.7 ms |

这些数包含本机 JSON 处理、进程与网络调度，不包含模型推理、真实手机网络、Codex 子进程内存或手机渲染。不是跨环境性能承诺。Flutter 的自动测试证明 100 个增量只引起一次消息通知且不重建会话页面；真实手机 p50/p95 帧时间与两小时稳定性测试尚未完成。

## 仍待外部环境验证

- 手机蜂窝网络、实际 Wi-Fi 切换、长时间后台、电脑休眠/断网。
- 选定的 HTTPS 入口、代理上传限制、WebSocket 空闲超时。
- iOS 签名和真机；Windows/macOS 产品运行。
- 持续负载和真实移动设备的帧时间/内存基线。

后续按用户要求完成本机正式安装：`/opt/codexlink` 的 root 所有单文件程序、`/var/lib/codexlink` 的私有状态，以及系统级 `codexlink.service`（以 jack 运行、开机启动、Restart=always）。结束服务主进程后 systemd 实际自动恢复，旧 Codex daemon 未受影响。47 个迁移数据文件的 SHA-256 一致，旧附件路径通过兼容链接保留；新登录密钥成功、旧密钥在本机及 LAN 均返回 401。没有配置公网入口或修改全局 Codex 配置。

Flutter Web 的开发热重启在当前 SDK 的 DWDS 里返回模块 JSON/视图销毁错误；已尝试独立重启，正式验收使用 release 页面、静态分析与 Widget 测试，未把该开发工具步骤写为通过。Android Gradle 输出本机 JDK native-access / 文件监控提示，发布和签名校验成功。

## 手机列表、粘贴与返回键修订

- 手机列表压缩为顶栏、搜索/范围筛选及一行账号入口，更多菜单保留 Goal/归档/刷新/主题/退出；完整统计在账号面板中查看。
- 剪贴板使用 paste 事件携带的文件/Blob，无须额外剪贴板读取权限，复用大小限制、流式上传、进度、取消和移除。只有路径文字时浏览器无法读取本地源文件，保持文本粘贴；真实文件与路径同时存在时只上传。
- Android 使用 PopScope 在会话页处理系统返回，列表页保留正常退出行为。已发布 APK 在 Pixel 模拟器实际按返回键验证。
- 本次 Release/Debug AOT 各 32 项、Flutter 36 项和 Chrome 2 项测试通过；APK 三种架构重建并通过签名验证。

本轮更新已原子替换 `/opt/codexlink/CodexLink.Server` 并执行 `systemctl restart codexlink`。服务 active/running、enabled，localhost 与 <LAN-IP> 的已登录 API 均 ready/shared；两处 main.dart.js 的 SHA-256 与新 Release 嵌入版本一致。配置与密钥哈希未变，原共享 daemon 保持运行；旧程序留在 `/opt/codexlink/CodexLink.Server.previous`。


## v0.1.0 公开发布构建检查

- `scripts/build-release.py` 生成两个 musl 静态 Linux tar.gz、两个 Windows Native AOT ZIP、四个签名 Android APK 与 SHA256SUMS；Linux 包包含可执行的 `install-systemd.sh`。
- Linux x64/ARM64 在 UPX 前后均无 ELF INTERP/NEEDED，`ldd` 显示非动态程序；两者在不含任何系统库的 scratch 容器内完成 `--init`。OpenSSL 静态链接，ICU 已移除。
- Linux x64 的实际 UPX 产物通过 32 项网关黑盒契约；普通 AOT Debug 脚本产物也通过 32 项。Flutter 静态分析、36 项 VM 单元/组件测试与 2 项 Chrome 粘贴测试通过。
- `install-systemd.sh` 在独立 Ubuntu 容器中验证默认 `/opt/codexlink`、`/var/lib/codexlink`、普通账号/权限、Codex 路径、初次初始化、升级保留配置/令牌，以及启用/重启命令。systemctl 使用记录调用的替身，生成 unit 另经宿主 `systemd-analyze verify` 检查；没有改动本机正式服务。
- 四个 APK 经 apksigner 校验签名一致，ABI 分别为 arm64-v8a、armeabi-v7a、x86_64 和三者合集；最低 API 24。
- 公共源码使用 Gitleaks 扫描，并用本机实际凭据的值对源码、未压缩原生文件、APK 内部成员做只报告命中数量的检查。打包采用文件白名单，模板不含可用令牌。Git 提交使用 GitHub noreply 地址。
- `docs/screenshots/` 为独立假 Codex 数据：虚构旅行清单项目、会话、用量和 demo@example.invalid。PC 图来自运行中的 Web；手机图来自 Android Release APK 的模拟器运行，不含真实用户会话、账号或凭据。
- ARM64 的 QEMU 编译使用单线程 ILC 规避模拟器中的编译器线程故障；本地 QEMU 整套网关测试存在启动超时，不能当作目标硬件运行结论。本地 Wine 的 Windows 初始化未通过，因此不将 Wine 视为 Windows 验收。`.github/workflows/release-smoke.yml` 可针对指定 Release，在原生 Linux x64/ARM64、Windows x64/ARM64 runner 校验摘要并运行实际包；后续结果以该工作流为准。
