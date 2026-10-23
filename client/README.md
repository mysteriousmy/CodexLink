# Flutter 客户端

一个工程共享 Android/iOS/Web UI 和状态，Material 3 明暗主题。小于 960 dp 时列表与会话切换，宽屏同时显示侧栏和会话。当前 Android 和 Web 已构建；iOS 工程与 Keychain entitlement 已准备，需要 macOS/Xcode 完成签名和运行验证。

- `data/app_controller.dart`：连接、认证、项目/会话、事件订阅与重连、账号数据。
- `data/conversation_controller.dart`：当前会话、分页、草稿、附件、消息/steer、Goal 和审批。
- `data/models.dart`：Token 语义与每条消息的局部更新；流式增量合并后约每 40 ms 通知。
- `ui/workspace_picker.dart`：Codex 原生项目/创建同步、主机目录选择。
- `data/file_diff.dart` / `ui/diff_view.dart`：增删/重命名与行号解析、实时/最终摘要、全屏彩色 Diff。
- `ui/composer_commands.dart`：技能与文件选择、MCP 目录；/goal 切换输入框目标模式。
- `ui/file_preview.dart` / `platform/svg_preview_*`：鉴权图片/工作区文件预览与下载；Web 图片上下文、移动端禁脚本 WebView 保留 SVG 动画。
- `platform/transport_*`：原生安全存储/Bearer、Web Cookie、二进制上传、文件下载与拖放。
- `ui/`：会话、输入区、审批、图片预览、用量面板与连接页。

流式文本完成后解析 Markdown；生成期间避免每个 token 重新解析整段 Markdown。长历史按页取回并惰性构建。文件不以 Base64 携带；浏览器利用 Blob，原生端使用字节流。

```bash
flutter --no-version-check pub get
flutter --no-version-check analyze
flutter --no-version-check test
flutter --no-version-check build web --release
flutter --no-version-check build apk --release --split-per-abi
```

`--no-version-check` 用于避开本次机器 Flutter 安装目录的版本检查问题，不改变应用行为。Web 应由网关同源托管；单独的 Flutter 开发 Web 服务器没有网关 API，需要开发代理才能完整登录。

个人发布签名先运行仓库根 `python3 scripts/prepare-android-signing.py`。缺少签名文件时普通 Flutter release 构建会使用 debug key，正式分发请用根目录的 `scripts/build-release.sh --android`。

Web 自带 Roboto 和 Noto 中文、等宽、符号和彩色 Emoji 字体，避免常规页面依赖 Google Fonts。中文 WOFF2 约 9.6 MiB，符号字体约 228 KiB、Emoji 字体约 1.9 MiB，仅随 Web 发布并由浏览器缓存，不增加 APK 体积；字体许可证随包提供。

后端 Debug/Release build/publish 会自动构建同模式的 Web 并嵌入可执行文件。独立 `flutter build web` 仍可用于前端开发，但交付不需要复制 `build/web`。

## 手机会话页与网页粘贴

宽度不足 960 px 时，会话列表使用紧凑顶栏、搜索和项目筛选按钮；账号与 Token/额度详情从底部一行入口打开，次要操作收进更多菜单。会话列表保留惰性构建和滚动自动分页。

Web 输入框获得焦点时，粘贴事件中的真实文件/图片直接进入现有流式上传队列，带有文件的同次粘贴不会再插入路径文字；普通文本保持原有粘贴行为。监听器随输入框销毁清理，在弹窗或其他输入框中不接管粘贴。浏览器仅提供路径字符串时无法读取该路径指向的本地文件，此时需用文件选择或拖放。

浏览器专项测试：`flutter --no-version-check test --platform chrome test/web/clipboard_test.dart`（必要时设置 `CHROME_EXECUTABLE`）。

手机会话页用 `PopScope` 接管系统返回，返回列表并保留会话、草稿和附件；列表页正常允许退出。账号/预览等路由先关闭自身，输入法先由系统收起。
