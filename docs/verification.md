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
- iOS 签名和真机；macOS 产品运行，以及 Windows 上的真实 Codex 长任务。
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
- ARM64 的 QEMU 编译使用单线程 ILC 规避模拟器中的编译器线程故障；本地 QEMU 整套网关测试存在启动超时，不能当作目标硬件运行结论。本地 Wine 的 .NET 产品初始化未通过，因此不将 Wine 视为 Windows 产品验收。最终验收使用下述原生 runner。

- [四平台原生 Release 验证](https://github.com/mysteriousmy/CodexLink/actions/runs/39974648441)全部通过：Linux x64/ARM64、Windows x64/ARM64 下载实际发布归档并核对 SHA-256，验证初始化、令牌摘要、鉴权、原生假 Codex 子进程、内嵌 Web/CanvasKit/中文字体、创建会话与提交轮次；两个 Linux 架构另外各通过完整 32 项黑盒契约。这里使用假 Codex，不代表 Windows 上的真实模型与长任务验收。
- 原生 Windows x64 检查发现 AotAnywhere 1.1.0 的 /GS cookie helper 破坏返回值，未压缩与 UPX 程序均受影响。仅对 x64 交叉链接替换该 helper，保留 cookie 校验与 fast-fail；修复后压缩包通过上面的原生检查。另用小型 C/汇编探针对照原 helper 返回值被破坏、修复后保留、错误 cookie 终止三个行为；这项底层探针在 Wine 执行，未混称为产品原生验收。

## v0.1.1 会话权限

- App/Web 新增只读、默认、自动审查、完全访问选择器。切换等待 Codex 的设置事件确认，管理策略禁用的选项不可提交；既有会话/自定义配置原样恢复，执行中的轮次或活跃 Goal 禁止切换。
- 权限契约覆盖：`test_four_permission_presets_confirm_actual_settings_and_persist_for_turns`、`test_custom_existing_permissions_are_displayed_and_never_overwritten_on_resume`、`test_permission_changes_reject_active_turn_and_active_goal`、`test_permissions_respect_managed_profiles_reviewers_and_authentication`、`test_external_permission_change_updates_snapshot_and_live_clients`。
- Flutter 覆盖选择器提交及管理策略禁用、真实确认前不更新状态、执行中禁用、320/390/1100px 与 1.3 倍字号，以及 `new_permission_events_win_over_older_http_responses` 防止旧 HTTP 结果覆盖新事件。静态分析无问题，40 项 Flutter 测试与 2 项 Chrome 粘贴测试通过。
- 本机真实共享 Codex 在独立临时目录中验证四档更新，检查原生 sandbox、approvalPolicy、approvalsReviewer、activePermissionProfile；没有提交模型轮次或修改用户原有会话。musl x64 的 UPX 程序同样完成这条真实协议验证。
- [v0.1.1 四平台原生 Release 验证](https://github.com/mysteriousmy/CodexLink/actions/runs/40047630023)全部通过。Linux x64/ARM64、Windows x64/ARM64 下载实际归档并核对 SHA-256，各自验证初始化、鉴权、内嵌 Web、轮次与四档权限；两个 Linux 架构另各通过完整 37 项黑盒契约。本机最终 UPX 压缩的 musl x64 产物同样通过 37 项测试。Windows 检查使用假 Codex，不代替真实模型长任务验收。
- 四个 Android APK 的版本为 0.1.1，ABI 正确且签名证书与 v0.1.0 相同。只读 Pixel 模拟器先安装并登录 v0.1.0，再覆盖安装新 x86_64 APK，登录状态保留；App 显示 Web 已设置的自动审查，切换只读后服务器确认，已打开的 Web 页面实时同步。该流程只使用独立虚构会话。
- 全部八个安装包及 SHA256SUMS 的 GitHub 资产摘要与本地文件一致。源码、未压缩原生文件及归档内部共 1778 份内容的实际私密值检查为 0 命中；源码 Gitleaks 检查同样通过。

## v0.1.2 会话列表下拉刷新

- App/Web 会话列表顶部支持下拉刷新，包括空列表和短列表；复用现有列表读取协议，保留搜索、项目/归档筛选、当前会话与草稿。
- 组件测试通过：`pull_refresh_empty_list`、`pull_refresh_short_list`、`pull_refresh_preserves_filters_and_ignores_stale_page`、`pull_refresh_failure_keeps_list_and_allows_retry`。通过实际下拉手势验证加载动画、一次请求、结果替换、旧分页不覆盖新结果，以及失败提示和重试。
- Flutter 静态分析无问题，44 项单元/组件测试与 2 项 Chrome 剪贴板测试通过；原有会话自动分页、历史加载和手机布局回归仍通过。
- 手机尺寸的实际 Web 页面通过触摸下拉刷新，分别从已有列表、单条列表和空列表读取新结果；每次手势均只有一次列表请求。
- Android 模拟器先登录 v0.1.1，再覆盖安装 v0.1.2 x86_64 Release APK，登录状态保留。实际下拉同样完成已有列表、短列表和空列表三种更新，均验证服务器请求次数及界面新内容。全部使用独立虚构会话，不访问用户真实账号或模型。
- [v0.1.2 四平台原生验证](https://github.com/mysteriousmy/CodexLink/actions/runs/40059821509)全部通过；两个 Linux 架构各通过 37 项完整网关契约。本机最终 UPX x64 发布包也通过相同 37 项测试。四个 APK 的 ABI/签名与递增版本号验证通过，GitHub 上 9 个资产的 SHA-256 与本地一致；源码及包内共 1779 份内容的私密值检查为 0 命中。

## v0.1.3 后台连接问题排查与修复（2026-10-24）

- 使用只读 Pixel Android 模拟器、v0.1.2 正式 APK、独立假 Codex 网关及记录事件的本机代理。不访问用户真实会话，不执行模型任务。
- 原版复现：后台重连的 `/api/status` 请求仍在等待时，回到前台建立新连接并显示“已连接”；再让旧 HTTP 连接失败，界面仍弹出 `ClientException: Connection closed before full header was received`，且新连接又被重连流程替换。这证明旧请求未受连接代次保护；测试没有声称复现真机完全相同的 `errno=110`。
- Wi-Fi/移动数据开关不关闭，强制 Android Doze：Wi-Fi 仍连接，`mNetworkConnected=true`、`mState=IDLE`；CodexLink UID 的网络策略明确为 `effective=DOZE`。唤醒后可以恢复任务结果。这证明系统能在网络仍连接时限制 App 网络，但不能仅据此确定用户真机当时的具体休眠策略。
- 原版 v0.1.2 普通后台及 Doze 下完成假任务均没有 Android 系统通知。Manifest、安装包权限和通知管理器检查与源码一致：没有 `POST_NOTIFICATIONS`、通知渠道、任务完成通知实现或推送接入。这是独立的功能缺失，不是已实现的通知被本次超时取消。
- 修复版在隐藏/暂停时释放订阅和定时器，回前台重新读取当前任务；HTTP 重连与快照请求均检查连接代次。过期成功、超时、401 和销毁后的响应不再影响新会话；当前真实 401 仍要求登录，自动重连中的传输异常保留断线状态但不反复弹出底层异常。
- `flutter --no-version-check test test/connection_lifecycle_test.dart` 通过 11 项；完整 Flutter 套件在前 10 项加入后通过 54 项，随后补充的取消定时重连用例同样通过。`flutter --no-version-check analyze` 无问题。
- 本地 `0.1.3-dev` x86_64 Release APK 覆盖安装后保留登录。同样的旧 HTTP 故障不会再弹异常或替换新连接；后台观察期间没有客户端请求/心跳，回前台重新连接成功。再次强制 Doze 并在后台完成假任务，唤醒后界面显示新完成结果与“已连接”，没有底层异常。这是加入通知前的连接修复测试，修复已纳入 v0.1.3；本机生产服务仍按用户要求保留原版。

| Requirement | Evidence |
| --- | --- |
| 旧 HTTP 成功/失败不能干扰新连接 | `stale_retry_timeout_cannot_replace_resumed_connection`、`stale_retry_unauthorized_cannot_replace_resumed_connection`、`stale_retry_success_cannot_replace_resumed_connection`、`stale_resync_failure_cannot_disconnect_new_session` |
| 暂停重试、恢复真实任务和草稿 | `background_cancels_scheduled_reconnect`、`background_defers_network_and_resume_reconciles_task`、`app_forwards_suspension_and_resume_but_not_focus_loss` |
| 当前鉴权错误与传输恢复保持正确 | `current_retry_unauthorized_requires_login`、`retry_timeout_recovers_without_error_snackbar`、`failed_resync_retries_with_full_snapshot`、`disposed_connection_ignores_pending_retry_failure` |

## v0.1.3 任务通知验证

使用独立假 Codex、临时设备密钥、Android 16 模拟器和 Chromium，未执行真实模型任务或修改用户会话。通知不包含回复正文。

- .NET Release 构建无警告；完整 managed 网关契约 44 项通过，其中通知专项 7 项覆盖基线/实时/补收、去重、正常重启持久化、容量/过期、损坏 journal 和鉴权。
- Flutter 全套 61 项测试通过，包含通知设置、气泡/点击、清理与此前 11 项生命周期回归。真实 Chromium 首次配置发现 Dart Web 位移导致随机数上限变为零，已修复并加入浏览器回归。浏览器专项合计 3 项通过。
- Android Release 测试包实际操作：先拒绝通知权限，确认保持关闭；再次开启并允许后，连接状态正常。点击锁屏后台运行按钮通过系统电池授权。进入 Doze 后完成假任务，0.65 秒出现任务通知，采样时屏幕仍关闭且 `mState=IDLE`。服务为 specialUse 前台服务，UID 网络策略 `effective=NONE` 且包含电池白名单允许项。唤醒后从通知栏点击，打开正确会话。网关重启后仍在后台收到新任务通知，采样延迟 0.33 秒。
- Web default/denied 权限下，实际完成事件产生右上角气泡；390 px 宽度时气泡边界为 x=18、y=12、宽 360，未溢出。重复完成事件仅显示一条，点击打开正确会话。授予权限后，实际 service worker 注册成功且系统通知队列包含正确的失败状态和线程 ID，页面不重复显示气泡。自动化验证系统通知的注册/队列；不能据此声称已人工看到所有操作系统的通知弹窗。
- 测试发现前台空闲网页点击系统通知后没有请求新帧，导致打开会话延后；现显式请求界面更新，并加入 `system_notification_click_schedules_idle_ui_and_opens_matching_thread` 回归。
- 最终 UPX Linux x64 发布包通过全部 44 项网关契约和原生冒烟检查；其内嵌网页与最终构建的 JavaScript 摘要一致。在此包中再次完成真实任务通知入队，再通过 service worker 的通知点击事件打开对应会话，确认请求和界面均正确，无需调整窗口。该点击由自动化合成，浏览器因此拒绝主动抢焦点；本次验证证明事件路由，不等于人工点击桌面通知。denied 权限下气泡去重、关闭也通过最终包复测。
- 在 App 后台撤销测试设备凭据并重启独立网关后，`android_unauthorized_notification_feed_stops_background_service` 验证后台服务在 1.54 秒内停止，不继续无限鉴权重试。
- 正式 x86_64 APK 再次覆盖安装后登录与权限保留；修正开启服务瞬间误报“未运行”的状态快照，并实际验证 `android_enable_reports_starting_without_false_stopped_error`。`android_doze_task_notification_before_wake` 在最终 APK 中再次通过：0.56 秒收到新会话的完成通知，采样时仍处于 Doze 且尚未唤醒。
- `android_notification_click_and_logout_clear_service_and_cards` 验证正式 APK 的通知打开对应会话；退出连接后回到登录页，后台服务与活动通知均已清除。
- [v0.1.3 四平台原生 Release 验证](https://github.com/mysteriousmy/CodexLink/actions/runs/40071167179)全部通过，包含通知 JSON/SSE 补收及内嵌 worker 检查；两个 Linux 架构各通过完整 44 项网关契约。四个 APK 的 ABI、递增版本号及与旧版一致的签名验证通过；GitHub 上 9 个资产的 SHA-256 与本地一致。源码和包内共 1800 份内容的私密值检查为 0 命中，源码及 Git 历史扫描无密钥泄漏。
- 真机厂商冻结、蜂窝漫游、主机休眠、长时间后台稳定性仍需实际设备验证。模拟器 Doze 结果不代表所有手机都能以相同延迟送达；强行停止 App 后需重新打开。Web 实时提醒要求页面打开，iOS 后台推送未实现。

| Requirement | Evidence |
| --- | --- |
| 基线、实时和断线补收，不携带正文 | `test_notification_baseline_live_delivery_and_replay_are_private` |
| 同轮去重，主动中断不报完成 | `test_notification_duplicate_and_interrupted_turns_do_not_alert_twice` |
| 重启持久化、损坏恢复 | `test_notification_cursor_and_history_survive_gateway_restart`、`test_notification_corrupt_journal_resets_epoch_without_breaking_startup` |
| 有界历史与显式丢失提示 | `test_notification_retention_is_bounded_and_reports_delivery_gap`、`test_notification_expired_history_and_changed_epoch_are_explicit` |
| 通知 API 鉴权/Origin/游标校验 | `test_notification_endpoints_require_authentication_and_valid_cursor` |
| 气泡有界去重，后台保留、点击与关闭 | `notification_bubbles_deduplicate_replace_and_bound_backlog`、`notification_bubble_opens_exact_thread_and_dismisses_without_opening` |
| 显式权限动作、旧服务器升级说明 | `notification_settings_request_permissions_only_after_user_action`、`notification_old_server_explains_upgrade_without_enable_action` |
| 退出清理及异步授权隔离 | `notification_logout_clears_pending_clicks_and_ignores_late_permission_result` |
| 空闲前台系统通知点击立即打开会话 | `system_notification_click_schedules_idle_ui_and_opens_matching_thread` |
| 浏览器未授权仍启动通知通道，登出清除 | `notification_browser_starts_feed_without_permission_and_clears_session` |

复现命令：`flutter test`；`flutter test --platform chrome test/web`；`.local/test-venv/bin/python -m unittest discover -s tests -v`。浏览器需要可用的 Chrome，独立前端开发服务器不提供网关通知 API。

## v0.1.4 选项问答（2026-10-24）

- Flutter 静态检查无问题，全量 **74 项**单元/Widget 测试与 **3 项** Chrome 平台测试通过；新增问答测试 13 项。服务端全量 **49 项** Managed 契约通过，最终 UPX Linux x64 包通过同一 49 项契约（61.987 秒）及扩展后的原生冒烟检查。
- 原生 `item/tool/requestUserInput` 保留问题 ID、选项说明、多问题、自由/私密字段和阻塞标记；提交验证失败保留请求，同一请求并发回答仅发送一次。旧轮次完成不清理新轮次的问题，其他客户端解决后及时失效。
- 异步 `agentMessage.questions` 在正文为空时也展示。运行中用原生 steer，空闲用新轮次，轮次冲突不自动转换；提交结果未知先查询，不重复发送，也不清空原有聊天草稿、引用和 Goal 状态。
- Android 16 x86_64 Release APK 在模拟器实测三题选择/其他回答/私密输入，键盘弹出后可滚动并提交；同时验证异步问题显示与原生 steer 回传、覆盖安装保留登录。实际截图发现并修复了选项边框越过弹窗标题的绘制问题，修复后再次检查标题、滚动裁剪与提交。
- 最终 x64 包的内嵌网页在 390×844 视口实测原生多问题选项/说明/其他回答/私密输入；关闭弹窗再打开后的答案通过原生 RPC 正确返回。异步问题分别实测 `/turn/steer` 和新轮次路径，聊天草稿与 Goal 开关保留。修复后的最终网页另外在 390×590 视口滚动复测，标题裁剪与提交正确；JavaScript 摘要与最终构建一致，浏览器无 warning/error。Widget 另外验证 320×640 与键盘占用时无布局异常。

| Requirement | Evidence |
| --- | --- |
| 手机选项说明、多题必填、自由/私密回答与不落盘 | `question_options_show_descriptions_validate_all_answers_and_hide_secrets` |
| 失败/关闭保留答案，提交期间防重复 | `question_failure_keeps_answers_when_dismissed_and_prevents_duplicate_submit` |
| 远端解决与 HTTP 失效后禁止回答 | `question_resolved_remotely_disables_open_dialog`、`native_expiry_response_removes_stale_prompt_without_losing_other_requests` |
| 重连、切换会话、退出时的草稿边界 | `question_reload_preserves_in_memory_draft_and_runtime_exit_expires_native_request`、`question_drafts_are_isolated_by_thread_and_logout_clears_them` |
| 异步空正文问题可见且支持其他回答 | `async_message_renders_questions_with_empty_text_and_allows_custom_answer` |
| 异步回答按轮次路由且保留聊天输入/Goal | `async_question_starts_idle_turn_preserving_composer`、`async_question_steers_active_turn_preserving_composer` |
| 未知结果核对、明确失败后手动重试、轮次冲突不转新任务 | `async_unknown_submission_reconciles_without_replaying_or_changing_answer`、`async_unknown_and_failed_operations_never_resend_until_explicit_retry`、`async_turn_change_preserves_answer_and_never_falls_back_to_new_turn` |
| 非阻塞问题不显示为任务暂停 | `nonblocking_question_keeps_task_running_indicator` |
| 鉴权、原生答案/长度/选项验证、并发只发一次 | `test_invalid_answers_and_unauthorized_requests_preserve_pending_question`、`test_native_questions_reconnect_and_exact_reply_once` |
| 按轮次清理、共享客户端解决与历史恢复 | `test_only_matching_turn_completion_expires_question`、`test_other_client_answer_resolves_pending_native_question`、`test_async_questions_survive_history_and_nonblocking_flag_survives_snapshot` |

测试使用独立 stdio / Unix WebSocket 假 Codex，不调用计费模型。协议字段另从本机 Codex CLI 0.163.0 生成的 schema 核对。异步答案是带问题标题的用户消息，不声称存在专用的结构化回答 RPC；问答草稿与异步已回答状态不保证跨客户端重启保留。物理手机、iOS 和移动网络下的表现不以模拟器/浏览器结果替代。

- [v0.1.4 四平台原生 Release 验证](https://github.com/mysteriousmy/CodexLink/actions/runs/40087525450)全部通过：实际安装包在 Linux x64/ARM64、Windows x64/ARM64 上验证原生问题回答与异步问题历史/steer，同时保留原有权限、通知及内嵌网页检查。两个 Linux 架构另各通过完整 49 项契约。
- 最终四个 APK 的 ABI、签名及递增版本号验证通过，签名与旧版一致。最终 x86_64 APK 覆盖安装后再次验证登录保留和完整三题原生回传。GitHub 上 9 个资产的 SHA-256 与本地一致；源码、原生文件和包内共 1804 份内容的私密值检查为 0 命中，源码及 Git 历史扫描无密钥泄漏。

## v0.1.5 输入恢复与问题同步（2026-10-24）

- 发送请求的生命周期与会话历史刷新解耦。旧实现中，发送/steer 未返回时重连同步会改变历史代次，HTTP 成功、明确失败和未知结果都可能跳过 `sending` 清理，使所有会话输入框持续只读。修复前这三项复现测试失败，修复后可继续输入和切换；未知结果仍需查询，不能自动重发。
- 原生/异步问题聚合为输入框上方的一行扁平提示条，显示待答数量，滚动聊天不移动提示条。320px 宽度下高度不超过 52px；回答后消失，正文只保留实际消息文本。
- 使用官方 Codex `rust-v0.163.0`（`83086188ae0614bd882818ff1aa23f3194962012`）的 [TUI 回答解析器](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/tui/src/async_question_reply.rs)格式。实际 Dart 生成的两题答案已交给未修改的上游 Rust 解析器验证，原始问题 ID、非连续索引、中文、引号、换行、结束标签文本及可读显示均正确。这是解析器互通验证，未声称实际操作了用户的 TUI。
- 回答状态从实时用户消息与加载的历史恢复，支持逐题/整消息旧 ID、答案先于问题到达，以及其他客户端在回答弹窗打开时提交。已回答部分不重新编号，不清除其他问题的草稿；嵌入示例、非法 JSON、额外文本或附件不会误清待答项。

| Requirement | Evidence |
| --- | --- |
| 发送过程中同步后恢复输入和会话切换，未知结果不重发 | `steer_accepted_during_sync_restores_composer_and_navigation`、`steer_rejected_during_sync_restores_composer_and_navigation`、`steer_uncertain_during_sync_restores_composer_and_navigation` |
| 旧登录请求不能影响新登录的在途输入 | `old_send_200_cannot_unlock_new_login_submission`、`old_send_504_cannot_unlock_new_login_submission`、`old_question_completion_cannot_unlock_a_new_login_submission` |
| TUI 信封、原始索引、特殊字符与完整消息识别 | `question_envelope_preserves_original_ids_unicode_and_escaping` |
| 跨端部分回答保留未答项及草稿，旧整消息 ID 兼容 | `remote_partial_answers_keep_other_questions_drafts_and_original_indices` |
| 乱序、历史重载、客户端重启不重开已答项 | `answers_before_questions_and_history_reconnect_do_not_reopen_prompts` |
| 打开的弹窗响应远端回答，保留其他草稿 | `remote_async_answer_updates_open_dialog_without_losing_other_draft` |
| 小屏扁平提示固定在输入框上方，合并原生与异步问题 | `question_strip_stays_above_composer_outside_history_on_small_screens` |
| 自定义回答提交后提示消失 | `async_question_bar_allows_custom_answer_and_disappears_after_submission` |
| 历史答案可读，嵌入示例不被解析替换 | `reply_history_shows_readable_answers_and_leaves_embedded_examples_unchanged` |
| 回答保留聊天输入、引用与 Goal，仍使用对应轮次 | `async_question_starts_idle_turn_preserving_composer`、`async_question_steers_active_turn_preserving_composer` |
| 原生多问题、选项说明、私密输入与内存边界 | `question_options_show_descriptions_validate_all_answers_and_hide_secrets` |

最终验证：`flutter analyze` 无问题，`flutter test` **86 项**通过；Chrome 执行三个相关测试文件 **25 项**及 `test/web` **3 项**通过。最终 UPX Linux x64 安装包通过 **50 项**完整网关契约（74.681 秒）及扩展的原生冒烟检查；`test_structured_async_replies_preserve_ids_and_echo_into_history` 另验证新轮次/steer 的信封保持原文并进入可恢复历史。

Android 16 x86_64 模拟器先在 v0.1.4 复现：延迟 8 秒的 steer 期间切到后台再返回，完成后仍显示“正在提交”且不能输入。覆盖安装最终 v0.1.5 APK 保留登录，同一操作完成后可输入 `works-after-steer`，切换另一会话可输入 `works-in-other-thread`。键盘弹出时提示条固定在输入框上方；网页回答后，Android 提示条同步消失并显示可读答案。实际网页在 390×844 下验证选项与自由回答、保留聊天草稿、提交后继续输入及刷新历史不重现待答项；实际内嵌 JavaScript 摘要与最终构建一致，刷新后的控制台无 warning/error。

四个 APK 均通过签名、ABI、v0.1.5 与递增版本号检查，签名证书与 v0.1.4 相同；四个服务端压缩包的版本、可执行文件摘要、内嵌 Web/AOT/UPX 元数据已核对。全部九个草稿 Release 文件的大小与 SHA-256 匹配本地产物。源码导出与 Git 历史 Gitleaks 无发现，1,806 项源码/归档内容的已知密钥扫描无命中。

[v0.1.5 四平台原生运行检查](https://github.com/mysteriousmy/CodexLink/actions/runs/40092561466)全部通过。Windows x64/ARM64 与 Linux x64/ARM64 均使用最终归档验证原生问答和结构化异步答案回传/历史，以及既有鉴权、权限、通知和内嵌网页；两个 Linux 架构另各通过完整 50 项契约。

## v0.1.6 Android 返回与待发送输入（2026-10-24）

代码与行为回归：

- Flutter 全量 **100 项通过**；Chrome **41 项通过**，包含原有网页导航、Diff、剪贴板、通知与新的待发送交互；`flutter analyze` 无问题。
- 服务端受控替身契约 **57 项通过**。新增 7 项验证原生队列添加/读取、幂等撤回、附件/引用与正文还原、立即发送的轮次检查、与自动消费竞争时不重复发送、明确拒绝重新排队、响应丢失保留回执及跨客户端队列事件。
- 已分别对正在运行的共享 Codex 和独立 stdio 连接执行只读 `thread/queue/list` 能力检查，均支持；没有调用模型、恢复活动线程或修改其任务。

| Requirement | Evidence |
|---|---|
| Android 会话动画与返回取消/提交保留草稿，Web 保留原切换 | `android_entry_animates_while_web_keeps_inline_conversation`、`conversation_predictive_back_cancels_then_commits_with_draft` |
| Diff 返回至同一会话，系统返回优先关闭图片与抽屉 | `diff_predictive_back_returns_to_same_conversation`、`system_back_closes_image_preview_before_conversation`、`system_back_closes_preview_and_sheet_before_conversation` |
| 正在运行时排队，立即发送不打断当前轮次、不重复提交 | `test_send_now_steers_expected_turn_without_interrupt_or_duplicate`、`test_changed_turn_and_dispatch_race_never_double_send` |
| 撤回合并草稿、附件、引用，并真正更新编辑框 | `running_messages_queue_and_withdraw_merge_draft_files_and_references`、`withdraw_button_updates_visible_editor_and_next_submission` |
| 未知结果重启后仍可查询，不自动重发 | `send_now_unknown_survives_restart_and_reconciles_without_resending`、`test_lost_steer_result_keeps_recovery_receipt_without_requeue` |
| Goal、问题、队列及键盘共存不覆盖/溢出 | `goal_questions_queue_and_keyboard_remain_scrollable_without_overlap`：390×844、320×568 和 800×400，最大键盘 240，字体缩放 1.3 |

Android 16 x86_64 模拟器实测会话和 Diff 返回手势预览、取消、完成，以及图片和附件抽屉的系统返回。v0.1.5 原版在此模拟器没有复现“图片返回直接退桌面”，因此修复记录不冒称已在该基线复现；新版本通过明确的 Android 回调及同一 Navigator 的真实路由验证弹窗优先关闭。尚未覆盖用户的具体真机与 OEM 返回手势。

三栏同时显示的实际画面已检查。按钮实测发现撤回后底层草稿更新但可见编辑框未更新，已修复外部草稿同步，并加入直接点击按钮、检查输入框文本、继续编辑并提交的组件回归。修正后 Android 实测现有草稿与撤回文本同时出现在编辑框；立即发送期间切后台再回前台，完成后队列消失、独立草稿保留。Debug 热重载用于行为检查，不作为性能证据。

三栏样式现统一为 Goal 的淡色圆角底、两行摘要、主色图标及右侧图标操作，横向边距和栏间距也相同；通过共享组件避免独立样式漂移。待发送摘要可点开查看完整内容和附件/引用数量，图标保留中文提示和无障碍标签。样式调整后重新通过 Flutter 100 项、Chrome 41 项及静态分析，并在 Android 检查三栏并存、键盘、问题与队列详情返回、长按提示及撤回恢复输入。

最终签名 x86_64 APK 从 v0.1.5 覆盖安装后，登录与既有草稿均保留；再次验证统一三栏、队列详情/问答返回、撤回合并可见草稿、立即发送期间前后台切换、会话与 Diff 预测性返回的取消/完成，以及抽屉返回。实际运行 APK 的 SHA-256 与最终发布文件一致。四个 APK 的签名、ABI、版本及递增版本号全部核对通过；四个服务端包的版本、Native AOT、内嵌网页、可执行文件摘要、静态链接/UPX 元数据通过验证，Linux x64 实际返回的网页摘要也匹配最新构建。

全部九个草稿 Release 资产的大小和 SHA-256 与本地一致。源码导出及 Git 历史 Gitleaks 无发现；1,812 项源码、原生文件及包内内容的已知私密值扫描为 0 命中。v0.1.5 的发布正文、目标提交以及九个资产的 ID、大小、摘要和更新时间均未改变。

[v0.1.6 四平台原生运行检查](https://github.com/mysteriousmy/CodexLink/actions/runs/40103494054)全部通过：Linux x64/ARM64 与 Windows x64/ARM64 均直接运行最终发布归档，覆盖原生待发送队列的添加/读取/撤回/立即发送、问答、权限、通知和内嵌网页；两个 Linux 架构各通过完整 **57 项**服务端契约。
