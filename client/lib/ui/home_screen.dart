import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/app_controller.dart' as app;
import '../data/models.dart';
import 'conversation_screen.dart';
import 'usage_panels.dart';
import 'workspace_picker.dart';
import 'task_notifications.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final app.AppController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showConversation = false;
  final _search = TextEditingController();
  final _threadScroll = ScrollController();
  Timer? _searchDebounce;
  app.AppController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.error.addListener(_showError);
    controller.notifications.openedThread.addListener(_openNotification);
    _threadScroll.addListener(_loadMoreThreads);
  }

  void _openNotification() {
    if (!mounted || controller.notifications.openedThread.value == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final thread = controller.notifications.openedThread.value;
      if (!mounted || !controller.usable || thread == null) return;
      controller.notifications.openedThread.value = null;
      unawaited(_select(thread));
    });
    // A system notification can be clicked while the page is already focused.
    // Post-frame callbacks alone do not request a new frame in an idle UI.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _loadMoreThreads() {
    if (!mounted ||
        !_threadScroll.hasClients ||
        controller.loadingThreads ||
        controller.threadCursor == null ||
        controller.threadListError != null) {
      return;
    }
    if (_threadScroll.position.extentAfter < 280) {
      unawaited(controller.loadThreads(more: true));
    }
  }

  void _showError() {
    final message = controller.error.value;
    if (!mounted || message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 6),
          showCloseIcon: true,
        ),
      );
      controller.error.value = null;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      controller.reportError(error);
    }
  }

  Future<void> _select(String id) async {
    setState(() => _showConversation = true);
    await _perform(() => controller.selectThread(id));
  }

  Future<void> _create({bool goal = false}) async {
    final target = await showWorkspacePicker(context, controller);
    if (target == null || !mounted) return;
    try {
      await controller.createThread(
        project: target.projectId,
        path: target.path,
      );
      if (!mounted) return;
      setState(() => _showConversation = true);
      if (goal && controller.conversation.threadId != null) {
        controller.conversation.setGoalMode(true);
      }
    } catch (error) {
      controller.reportError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMoreThreads());
    if (controller.notifications.openedThread.value != null) {
      _openNotification();
    }
    if (!controller.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!controller.authenticated) {
      return ConnectionPage(controller: controller);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        return PopScope(
          canPop: wide || !_showConversation,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && !wide && _showConversation) {
              setState(() => _showConversation = false);
            }
          },
          child: Scaffold(
            body: SafeArea(
              child: Stack(
                children: [
                  Row(
                    children: [
                      if (wide || !_showConversation)
                        SizedBox(
                          width: wide ? 288 : constraints.maxWidth,
                          child: _sidebar(context, compact: !wide),
                        ),
                      if (wide) const VerticalDivider(width: 1),
                      if (wide || _showConversation)
                        Expanded(
                          child: ConversationScreen(
                            appController: controller,
                            onBack: wide
                                ? null
                                : () =>
                                      setState(() => _showConversation = false),
                            onCreate: _create,
                          ),
                        ),
                    ],
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    width: (constraints.maxWidth - 24).clamp(0, 360).toDouble(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: (constraints.maxHeight - 24).clamp(
                          0,
                          double.infinity,
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: TaskNotificationToasts(
                          controller: controller.notifications,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sidebar(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: Column(
        children: [
          if (compact)
            _mobileHeader(context)
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 12, 18),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.terminal_rounded,
                      color: colors.onPrimary,
                      size: 23,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'CodexLink',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.6,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: controller.dark ? '浅色模式' : '深色模式',
                    onPressed: controller.toggleTheme,
                    icon: Icon(
                      controller.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: controller.busy || !controller.usable
                      ? null
                      : _create,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建会话'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: controller.busy || !controller.usable
                      ? null
                      : () => _create(goal: true),
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('新建 Goal'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: DropdownButtonFormField<String>(
                key: ValueKey(controller.projectId),
                initialValue: controller.projectId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '会话范围',
                  prefixIcon: Icon(Icons.folder_outlined),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部本机会话')),
                  ...controller.projects.map(
                    (p) => DropdownMenuItem(
                      value: p['id'] as String,
                      child: Text(
                        p['name'] as String,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) => _perform(
                  () => controller.selectProject(value == '' ? null : value),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: '搜索会话标题',
                  prefixIcon: Icon(Icons.search_rounded),
                  isDense: true,
                ),
                onChanged: (value) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 350),
                    () => controller.searchThreads(value),
                  );
                },
                onSubmitted: (value) {
                  _searchDebounce?.cancel();
                  controller.searchThreads(value);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 10, 2),
              child: Row(
                children: [
                  Text(
                    controller.archivedThreads ? '已归档会话' : '本机会话',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: controller.archivedThreads ? '查看未归档会话' : '查看已归档会话',
                    onPressed: () => _perform(
                      () => controller.showArchivedThreads(
                        !controller.archivedThreads,
                      ),
                    ),
                    icon: Icon(
                      controller.archivedThreads
                          ? Icons.inbox_outlined
                          : Icons.archive_outlined,
                      size: 19,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新会话',
                    onPressed: () => _perform(controller.loadThreads),
                    icon: const Icon(Icons.refresh_rounded, size: 19),
                  ),
                ],
              ),
            ),
          ],
          if (controller.loadingThreads)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: RefreshIndicator(
              onRefresh: controller.loadThreads,
              child: controller.threads.isEmpty
                  ? CustomScrollView(
                      key: const ValueKey('thread-list'),
                      controller: _threadScroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                controller.loadingThreads
                                    ? '正在读取本机会话…'
                                    : '没有匹配的会话\n可切换范围或清除搜索条件',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      key: const ValueKey('thread-list'),
                      controller: _threadScroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount:
                          controller.threads.length +
                          (controller.threadCursor == null ? 0 : 1),
                      itemBuilder: (context, index) {
                        if (index == controller.threads.length) {
                          if (controller.threadListError != null) {
                            return TextButton.icon(
                              onPressed: () =>
                                  controller.loadThreads(more: true),
                              icon: const Icon(Icons.refresh),
                              label: const Text('加载失败，重试'),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Center(
                              child: controller.loadingThreads
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const SizedBox(height: 20),
                            ),
                          );
                        }
                        final thread = controller.threads[index];
                        final selected =
                            controller.conversation.threadId == thread['id'];
                        final title = threadTitle(thread);
                        final active =
                            asMap(thread['status'])['type'] == 'active';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: ListTile(
                            selected: selected,
                            selectedTileColor: colors.secondaryContainer
                                .withValues(alpha: .7),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            leading: Icon(
                              active
                                  ? Icons.motion_photos_on_rounded
                                  : Icons.chat_bubble_outline_rounded,
                              size: 19,
                            ),
                            title: Text(
                              title.replaceAll('\n', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: Text(
                              '${threadLocation(thread)} · ${threadSourceLabel(thread)}\n${_time(thread['updatedAt'])}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () => _select(thread['id'] as String),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const Divider(height: 1),
          if (compact)
            _mobileFooter(context)
          else ...[
            _accountCard(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 12, 10),
              child: Row(
                children: [
                  Flexible(child: ConnectionIndicator(controller: controller)),
                  const Spacer(),
                  IconButton(
                    tooltip: '任务通知',
                    onPressed: () => showTaskNotificationSettings(
                      context,
                      controller.notifications,
                    ),
                    icon: const Icon(Icons.notifications_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: '退出连接',
                    onPressed: () => _perform(controller.logout),
                    icon: const Icon(Icons.logout_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mobileHeader(BuildContext context) {
    final project = controller.projects
        .where((p) => p['id'] == controller.projectId)
        .firstOrNull;
    final scope = project?['name'] as String? ?? '全部本机会话';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  controller.archivedThreads ? '已归档会话' : 'CodexLink',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: '新建会话',
                onPressed: controller.busy || !controller.usable
                    ? null
                    : _create,
                icon: const Icon(Icons.add_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: '更多会话操作',
                onSelected: (value) {
                  switch (value) {
                    case 'goal':
                      _create(goal: true);
                    case 'archive':
                      _perform(
                        () => controller.showArchivedThreads(
                          !controller.archivedThreads,
                        ),
                      );
                    case 'refresh':
                      _perform(controller.loadThreads);
                    case 'theme':
                      controller.toggleTheme();
                    case 'notifications':
                      showTaskNotificationSettings(
                        context,
                        controller.notifications,
                      );
                    case 'logout':
                      _perform(controller.logout);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'goal',
                    enabled: !controller.busy && controller.usable,
                    child: const Text('新建 Goal'),
                  ),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(
                      controller.archivedThreads ? '查看未归档会话' : '查看已归档会话',
                    ),
                  ),
                  const PopupMenuItem(value: 'refresh', child: Text('刷新会话')),
                  PopupMenuItem(
                    value: 'theme',
                    child: Text(controller.dark ? '浅色模式' : '深色模式'),
                  ),
                  const PopupMenuItem(
                    value: 'notifications',
                    child: Text('任务通知'),
                  ),
                  const PopupMenuItem(value: 'logout', child: Text('退出连接')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: project == null ? '搜索会话标题' : '搜索 · $scope',
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  onChanged: (value) {
                    _searchDebounce?.cancel();
                    _searchDebounce = Timer(
                      const Duration(milliseconds: 350),
                      () => controller.searchThreads(value),
                    );
                  },
                  onSubmitted: (value) {
                    _searchDebounce?.cancel();
                    controller.searchThreads(value);
                  },
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '会话范围：$scope',
                initialValue: controller.projectId ?? '',
                icon: Badge(
                  isLabelVisible: controller.projectId != null,
                  child: const Icon(Icons.filter_list_rounded),
                ),
                onSelected: (value) => _perform(
                  () => controller.selectProject(value == '' ? null : value),
                ),
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: '',
                    checked: controller.projectId == null,
                    child: const Text('全部本机会话'),
                  ),
                  ...controller.projects.map(
                    (p) => CheckedPopupMenuItem<String>(
                      value: p['id'] as String,
                      checked: controller.projectId == p['id'],
                      child: Text(
                        p['name'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mobileFooter(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        Expanded(child: ConnectionIndicator(controller: controller)),
        TextButton.icon(
          onPressed: () => showAccountPanel(context, controller),
          icon: const Icon(Icons.account_circle_outlined, size: 20),
          label: const Text('账号与用量'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ],
    ),
  );

  Widget _accountCard(BuildContext context) {
    final account = asMap(asMap(controller.accountUsage['account'])['account']);
    final tokens = asMap(controller.accountUsage['tokens']);
    final summary = asMap(tokens['summary']);
    final today = asMaps(tokens['dailyUsageBuckets'])
        .where((b) => b['startDate'] == controller.accountUsage['today'])
        .firstOrNull;
    return InkWell(
      onTap: () => showAccountPanel(context, controller),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_circle_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    account['email'] as String? ?? '本机 Codex 账号',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 17),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _smallStat(
                    '今日 Token',
                    compactNumber(today?['tokens'] as num?),
                  ),
                ),
                Expanded(
                  child: _smallStat(
                    '累计 Token',
                    compactNumber(summary['lifetimeTokens'] as num?),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallStat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 11)),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
      ),
    ],
  );
  String _time(dynamic seconds) {
    if (seconds is! num) return '尚未开始';
    final date = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000)
        .toLocal();
    return '${date.month}月${date.day}日 · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _threadScroll.dispose();
    controller.error.removeListener(_showError);
    controller.notifications.openedThread.removeListener(_openNotification);
    super.dispose();
  }
}

class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key, required this.controller});
  final app.AppController controller;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: controller.foreground,
    borderRadius: BorderRadius.circular(20),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: controller.usable
                  ? const Color(0xff389b70)
                  : Theme.of(context).colorScheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              controller.connectionLabel,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, required this.controller});
  final app.AppController controller;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final TextEditingController _address = TextEditingController(
    text: widget.controller.address,
  );
  final _token = TextEditingController();
  bool _visible = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      Icons.terminal_rounded,
                      size: 36,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 30),
                  const Text(
                    '工作，随时接续。',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '连接你的电脑，让 Codex 的任务和进度\n随时出现在手边。',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 16,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _address,
                    readOnly: kIsWeb,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '服务地址',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _token,
                    obscureText: !_visible,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => widget.controller.login(
                      _address.text,
                      _token.text.trim(),
                    ),
                    decoration: InputDecoration(
                      labelText: '设备访问密钥',
                      prefixIcon: const Icon(Icons.key_rounded),
                      suffixIcon: IconButton(
                        tooltip: _visible ? '隐藏密钥' : '显示密钥',
                        onPressed: () => setState(() => _visible = !_visible),
                        icon: Icon(
                          _visible
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: widget.controller.busy
                          ? null
                          : () => widget.controller.login(
                              _address.text,
                              _token.text.trim(),
                            ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                      child: widget.controller.busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('连接 CodexLink'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '使用主机生成的设备访问密钥。远程连接请使用 HTTPS 地址。',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }
}
