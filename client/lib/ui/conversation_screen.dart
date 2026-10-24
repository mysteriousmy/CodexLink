import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/api_client.dart';
import '../data/app_controller.dart' as app;
import '../data/conversation_controller.dart';
import '../data/models.dart';
import '../data/questions.dart';
import 'question_prompt.dart';
import '../platform/transport.dart' as transport;
import 'file_preview.dart';
import 'composer_commands.dart';
import 'task_activity.dart';
import 'home_screen.dart';
import 'usage_panels.dart';
import 'diff_view.dart';
import 'permission_picker.dart';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.appController,
    required this.onCreate,
    this.onBack,
  });
  final app.AppController appController;
  final Future<void> Function() onCreate;
  final VoidCallback? onBack;
  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _scroll = ScrollController();
  bool _goalBusy = false;
  final Key _historyCenter = UniqueKey();
  String? _historyBoundaryId;
  bool _follow = true;
  String? _lastThread;
  ConversationController get controller => widget.appController.conversation;
  @override
  void initState() {
    super.initState();
    _lastThread = controller.threadId;
    _historyBoundaryId = controller.items.firstOrNull?.id;
    controller.streamRevision.addListener(_updated);
    controller.addListener(_changed);
    _scroll.addListener(() {
      if (_scroll.hasClients) {
        final follow = _scroll.position.maxScrollExtent - _scroll.offset < 120;
        if (_follow != follow) setState(() => _follow = follow);
        if (!_follow) _loadOlderNearStart();
      }
    });
    _updated();
  }

  void _changed() {
    if (_lastThread != controller.threadId) {
      _lastThread = controller.threadId;
      _follow = true;
      _historyBoundaryId = null;
    }
    if (_historyBoundaryId == null && controller.items.isNotEmpty) {
      _historyBoundaryId = controller.items.first.id;
    }
    _updated();
  }

  void _loadOlderNearStart() {
    if (_scroll.hasClients &&
        _scroll.position.extentBefore < 240 &&
        !controller.loading &&
        !controller.loadingOlder &&
        controller.olderError == null &&
        controller.itemsCursor != null) {
      unawaited(controller.loadOlder());
    }
  }

  void _updated() {
    if (!_follow || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _follow) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      widget.appController.reportError(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      if (controller.threadId == null) {
        return Column(
          children: [
            if (widget.onBack != null)
              Align(
                alignment: Alignment.centerLeft,
                child: BackButton(onPressed: widget.onBack),
              ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          size: 44,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          '想从哪里开始？',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -.8,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '选择一个会话继续，或给 Codex 一个新任务。\n离开这个页面，电脑上的工作仍会继续。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            height: 1.8,
                          ),
                        ),
                        const SizedBox(height: 28),
                        FilledButton.icon(
                          onPressed: widget.appController.usable
                              ? widget.onCreate
                              : null,
                          icon: const Icon(Icons.add),
                          label: const Text('开始新会话'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Row(
              children: [
                if (widget.onBack != null) BackButton(onPressed: widget.onBack),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.title.replaceAll('\n', ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ConnectionIndicator(controller: widget.appController),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '会话附件',
                  onPressed: () => _showFiles(context),
                  icon: const Icon(Icons.folder_open_outlined, size: 21),
                ),
                IconButton(
                  tooltip: '账号用量',
                  onPressed: () =>
                      showAccountPanel(context, widget.appController),
                  icon: const Icon(Icons.account_circle_outlined, size: 23),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          InkWell(
            onTap: () => showSessionUsage(context, controller),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
              child: Row(
                children: [
                  Icon(
                    Icons.data_usage_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '会话 ${compactNumber(controller.usage.total)} Token  ·  上下文 ${controller.usage.fraction == null ? '待更新' : '约 ${(controller.usage.fraction! * 100).round()}%'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 17),
                ],
              ),
            ),
          ),
          if (!controller.canControl)
            MaterialBanner(
              content: Text(controller.controlReason ?? '此会话暂时无法控制。'),
              actions: [
                TextButton(
                  onPressed: () => _perform(
                    controller.archived
                        ? controller.unarchive
                        : controller.reload,
                  ),
                  child: Text(controller.archived ? '恢复会话' : '同步重试'),
                ),
              ],
            ),
          if (!widget.appController.usable)
            MaterialBanner(
              content: Text(
                '${widget.appController.connectionLabel}。已提交任务独立于手机连接运行。',
              ),
              actions: [
                TextButton(
                  onPressed: widget.appController.foreground,
                  child: const Text('重新连接'),
                ),
              ],
            ),
          if (controller.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Stack(
              children: [
                if (controller.items.isEmpty && !controller.loading)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(30),
                      child: Text(
                        '描述你想完成的事情，\n也可以添加文件或设置一个目标。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          height: 1.8,
                        ),
                      ),
                    ),
                  ),
                _messageList(),
                if (!_follow)
                  Positioned(
                    right: 24,
                    bottom: 16,
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() => _follow = true);
                        _updated();
                      },
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      label: const Text('最新内容'),
                    ),
                  ),
              ],
            ),
          ),
          if (controller.approvals.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                children: controller.approvals
                    .map(
                      (a) => ApprovalCard(
                        key: ValueKey(a['id']),
                        approval: a,
                        controller: controller,
                        onError: widget.appController.reportError,
                      ),
                    )
                    .toList(),
              ),
            ),
          if (controller.uncertain)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              color: colors.tertiaryContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '提交结果未知。草稿已保留，请先核对最新会话与目标。',
                    style: TextStyle(fontSize: 12),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => _perform(controller.reconcile),
                        child: const Text('核对结果'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('确认尚未执行？'),
                              content: const Text(
                                '请先检查最新消息。若旧请求已经执行，再发送会重复启动任务。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('返回检查'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('已核对，恢复草稿'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            controller.confirmNotSubmitted();
                          }
                        },
                        child: const Text('已确认未提交'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TaskActivity(
                    controller: controller,
                    connected: widget.appController.usable,
                  ),
                  if (controller.goal != null &&
                      controller.goal?['status'] != 'complete')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: _goalCard(context),
                    ),
                  Composer(appController: widget.appController),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _messageList() {
    final boundary = controller.items.indexWhere(
      (item) => item.id == _historyBoundaryId,
    );
    final split = boundary < 0 ? 0 : boundary;
    // Slivers before this stable center grow upwards. Prepending history never
    // changes the scroll coordinate of the message the user is reading.
    return NotificationListener<OverscrollNotification>(
      onNotification: (event) {
        if (event.depth == 0 && event.overscroll < 0) _loadOlderNearStart();
        return false;
      },
      child: CustomScrollView(
        key: const ValueKey('conversation-history'),
        controller: _scroll,
        center: _historyCenter,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: controller.olderError != null
                    ? TextButton.icon(
                        onPressed: controller.loadingOlder
                            ? null
                            : controller.loadOlder,
                        icon: const Icon(Icons.refresh),
                        label: const Text('更早消息加载失败，重试'),
                      )
                    : controller.loadingOlder
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const SizedBox(height: 4),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: split,
            itemBuilder: (context, index) =>
                _message(controller.items[split - 1 - index]),
          ),
          SliverList.builder(
            key: _historyCenter,
            itemCount: controller.items.length - split,
            itemBuilder: (context, index) =>
                _message(controller.items[split + index]),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
        ],
      ),
    );
  }

  Widget _message(ConversationItem item) => Center(
    key: ValueKey(item.id),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: MessageTile(
          item: item,
          controller: controller,
          onError: widget.appController.reportError,
        ),
      ),
    ),
  );

  Future<void> _goalAction(Future<void> Function() action) async {
    if (_goalBusy) return;
    setState(() => _goalBusy = true);
    try {
      await _perform(action);
    } finally {
      if (mounted) setState(() => _goalBusy = false);
    }
  }

  Widget _goalCard(BuildContext context) {
    final goal = controller.goal!;
    final colors = Theme.of(context).colorScheme;
    final enabled =
        controller.canControl && widget.appController.usable && !_goalBusy;
    return Material(
      key: const ValueKey('active-goal-bar'),
      color: colors.primaryContainer.withValues(alpha: .4),
      borderRadius: BorderRadius.circular(14),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _showGoal(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(Icons.flag_outlined, size: 18, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Goal · ${goalStatus(goal['status'] as String?)}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            (goal['objective'] as String? ?? '目标').replaceAll(
                              '\n',
                              ' ',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '编辑目标',
            onPressed: enabled ? () => _editGoal(context) : null,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
          IconButton(
            tooltip: goal['status'] == 'active' ? '暂停目标' : '继续目标',
            onPressed: enabled
                ? () => _goalAction(
                    () => controller.setGoal(
                      status: goal['status'] == 'active' ? 'paused' : 'active',
                    ),
                  )
                : null,
            icon: Icon(
              goal['status'] == 'active'
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: '删除目标',
            onPressed: enabled ? () => _goalAction(controller.clearGoal) : null,
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }

  Future<void> _showGoal(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final goal = controller.goal;
        return AlertDialog(
          title: Text('Goal · ${goalStatus(goal?['status'] as String?)}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(goal?['objective'] as String? ?? '目标已清除'),
                  const SizedBox(height: 18),
                  Text(
                    '已用 ${compactNumber(goal?['tokensUsed'] as num?)} Token${goal?['tokenBudget'] == null ? '' : ' / 预算 ${compactNumber(goal?['tokenBudget'] as num?)}'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (goal != null &&
                controller.canControl &&
                widget.appController.usable)
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _editGoal(this.context);
                },
                child: const Text('编辑目标'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );

  Future<void> _editGoal(BuildContext context) =>
      showGoalEditor(context, controller, widget.appController.reportError);

  Future<void> _showFiles(BuildContext context) async {
    await _perform(controller.reload);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '会话附件',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 21),
                ),
              ),
              if (controller.files.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('还没有上传附件。'),
                ),
              for (final file in controller.files)
                ListTile(
                  leading: Icon(
                    file['isImage'] == true
                        ? Icons.image_outlined
                        : Icons.description_outlined,
                  ),
                  title: Text(
                    file['name'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${compactNumber(file['size'] as num?)} B'),
                  onTap: () => _perform(() => controller.download(file)),
                  trailing: IconButton(
                    tooltip: '清理附件',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('清理附件？'),
                          content: const Text(
                            '历史消息将保留，但该文件将无法再次读取。正在执行的任务或未完成目标使用的附件不能清理。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('清理'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await _perform(() => controller.deleteFile(file));
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.streamRevision.removeListener(_updated);
    controller.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }
}

class Composer extends StatefulWidget {
  const Composer({super.key, required this.appController});
  final app.AppController appController;
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  String? _threadId;
  late final void Function() _stopDrop;
  late final void Function() _stopPaste;
  bool _commands = false;
  String get _commandQuery {
    final text = _text.text;
    if (text.startsWith('/') && !text.contains('\n')) {
      return text.split(' ').first;
    }
    final cursor = _text.selection.baseOffset.clamp(0, text.length);
    final match = RegExp(r'(^|\s)@([^\s]*)$')
        .firstMatch(text.substring(0, cursor));
    return match == null ? '' : '@${match.group(2)}';
  }

  Future<void> _command(String command) async {
    final query = _commandQuery;
    if (query.startsWith('/') && _text.text.startsWith(query)) {
      _text.text = _text.text.substring(query.length).trimLeft();
    } else if (query.startsWith('@')) {
      final end = _text.selection.baseOffset.clamp(0, _text.text.length);
      _text.text = _text.text.replaceRange(end - query.length, end, '');
    }
    controller.setDraft(_text.text);
    setState(() => _commands = false);
    try {
      if (command == '/goal') {
        controller.setGoalMode(!controller.goalMode);
        _focus.requestFocus();
      } else if (command == '/mcp') {
        await showMcpCatalog(context, controller);
      } else {
        final reference = await selectComposerReference(
          context,
          controller,
          skill: command == '/skills',
          query: query.startsWith('@') ? query.substring(1) : '',
        );
        if (reference != null) controller.addReference(reference);
      }
    } catch (e) {
      widget.appController.reportError(e);
    }
  }

  ConversationController get controller => widget.appController.conversation;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    _stopDrop = transport.registerFileDrop((files) {
      unawaited(
        controller
            .addFiles(files, widget.appController.maxFileBytes)
            .catchError(widget.appController.reportError),
      );
    });
    _stopPaste = transport.registerFilePaste(
      (files) => unawaited(
        controller
            .addFiles(files, widget.appController.maxFileBytes)
            .catchError(widget.appController.reportError),
      ),
      enabled: () =>
          mounted &&
          _focus.hasFocus &&
          (ModalRoute.of(context)?.isCurrent ?? false) &&
          controller.threadId != null &&
          !controller.sending &&
          !controller.uncertain,
    );
    _changed();
  }

  void _changed() {
    if (_threadId != controller.threadId ||
        (_text.text.isNotEmpty && controller.draft.isEmpty)) {
      _threadId = controller.threadId;
      _text.text = controller.draft;
    }
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    if (!widget.appController.usable) return;
    final command = _commandQuery;
    if (command.isNotEmpty) {
      final target = command.startsWith('@') ? '@' : command;
      if (composerCommands.any((c) => c.$1 == target)) {
        await _command(target);
      } else {
        widget.appController.reportError(
          const ApiError('未知指令。请选择 /skills、/mcp、/goal 或 @文件。'),
        );
      }
      return;
    }
    await controller.send();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: controller.goalMode ? colors.primary : colors.outlineVariant,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_commands || _commandQuery.isNotEmpty)
              CommandPalette(query: _commandQuery, onSelected: _command),
            if (controller.references.isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final reference in controller.references)
                    InputChip(
                      avatar: Icon(
                        reference['type'] == 'skill'
                            ? Icons.auto_awesome_outlined
                            : Icons.description_outlined,
                        size: 16,
                      ),
                      label: Text(reference['name'] as String),
                      tooltip: reference['path'] as String,
                      onDeleted: controller.sending
                          ? null
                          : () => controller.removeReference(reference),
                    ),
                ],
              ),
            if (controller.uploads.isNotEmpty)
              SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: controller.uploads.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final file = controller.uploads[index];
                    return ListenableBuilder(
                      listenable: file,
                      builder: (context, _) => Container(
                        width: 190,
                        padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            if (file.uploaded?['isImage'] == true)
                              AttachmentPreview(
                                controller: controller,
                                id: file.uploaded!['id'] as String,
                                name: file.file.name,
                                compact: true,
                              )
                            else
                              const Icon(
                                Icons.insert_drive_file_outlined,
                                size: 18,
                              ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    file.file.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  if (file.running)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: LinearProgressIndicator(
                                        value: file.progress,
                                        minHeight: 3,
                                      ),
                                    ),
                                  if (!file.running)
                                    Text(
                                      file.error != null
                                          ? '上传失败 · 点击重试'
                                          : '已就绪',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: file.error == null
                                            ? colors.primary
                                            : colors.error,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (file.error != null)
                              IconButton(
                                tooltip: '重试上传',
                                onPressed: () =>
                                    controller.uploadAttachment(file),
                                icon: const Icon(Icons.refresh, size: 16),
                                visualDensity: VisualDensity.compact,
                              ),
                            IconButton(
                              tooltip: file.running ? '取消上传' : '移除附件',
                              onPressed: () => controller.removeUpload(file),
                              icon: const Icon(Icons.close, size: 15),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            Focus(
              onKeyEvent: (node, event) {
                final desktop =
                    kIsWeb ||
                    defaultTargetPlatform == TargetPlatform.linux ||
                    defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.macOS;
                if (desktop &&
                    event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed &&
                    !_text.value.composing.isValid) {
                  if (controller.canSend || _commandQuery.isNotEmpty) _send();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _text,
                focusNode: _focus,
                readOnly: controller.sending || controller.uncertain,
                minLines: 2,
                maxLines: 6,
                maxLength: 200000,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: controller.goalMode
                      ? '描述目标，发送后开始执行…'
                      : controller.activeTurnId == null
                      ? '描述任务 · / 指令 · @ 文件'
                      : '补充当前任务的方向…',
                  filled: false,
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 12,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onChanged: (text) {
                  controller.setDraft(text);
                  setState(() {});
                },
              ),
            ),
            Row(
              children: [
                Expanded(child: _modelPicker(context)),
                PermissionPicker(
                  controller: controller,
                  onError: widget.appController.reportError,
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  tooltip: '添加文件',
                  onPressed: controller.sending
                      ? null
                      : () async {
                          try {
                            await controller.pickFiles(
                              widget.appController.maxFileBytes,
                            );
                          } catch (error) {
                            widget.appController.reportError(error);
                          }
                        },
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 23),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '输入指令',
                  onPressed: controller.canControl
                      ? () => setState(() => _commands = !_commands)
                      : null,
                  icon: const Icon(Icons.terminal_rounded, size: 20),
                ),
                IconButton(
                  tooltip: controller.goalMode ? '取消 Goal 模式' : '设为 Goal',
                  isSelected: controller.goalMode,
                  onPressed:
                      controller.canControl &&
                          !controller.sending &&
                          !controller.uncertain
                      ? () {
                          controller.setGoalMode(!controller.goalMode);
                          _focus.requestFocus();
                        }
                      : null,
                  style: IconButton.styleFrom(
                    backgroundColor: controller.goalMode
                        ? colors.primaryContainer
                        : Colors.transparent,
                    foregroundColor: controller.goalMode
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.flag_outlined, size: 21),
                  selectedIcon: const Icon(Icons.flag_rounded, size: 21),
                ),
                if (controller.activeTurnId != null)
                  IconButton(
                    tooltip: '停止当前轮次并暂停目标',
                    onPressed: () async {
                      try {
                        await controller.stop();
                      } catch (error) {
                        widget.appController.reportError(error);
                      }
                    },
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                FilledButton.icon(
                  onPressed:
                      widget.appController.usable &&
                          (controller.canSend || _commandQuery.isNotEmpty)
                      ? _send
                      : null,
                  icon: controller.sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward_rounded, size: 18),
                  label: Text(
                    _commandQuery.isNotEmpty
                        ? '打开'
                        : controller.goalMode || controller.activeTurnId == null
                        ? '发送'
                        : '补充',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelPicker(BuildContext context) {
    final selected = widget.appController.models
        .where((m) => (m['model'] ?? m['id']) == controller.model)
        .firstOrNull;
    final efforts = asMaps(selected?['supportedReasoningEfforts']);
    return PopupMenuButton<String>(
      tooltip: '模型与推理强度',
      enabled: controller.activeTurnId == null,
      onSelected: (value) {
        setState(() {
          if (value.startsWith('effort:')) {
            controller.effort = value.substring(7);
          } else {
            controller.model = value;
            final model = widget.appController.models.firstWhere(
              (m) => (m['model'] ?? m['id']) == value,
            );
            controller.effort = model['defaultReasoningEffort'] as String?;
          }
        });
      },
      itemBuilder: (context) => [
        for (final model in widget.appController.models)
          PopupMenuItem(
            value: model['model'] as String? ?? model['id'] as String,
            child: Text(
              model['displayName'] as String? ??
                  model['model'] as String? ??
                  '默认模型',
            ),
          ),
        const PopupMenuDivider(),
        for (final effort in efforts)
          PopupMenuItem(
            value: 'effort:${effort['reasoningEffort']}',
            child: Text('推理强度 · ${effort['reasoningEffort']}'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Text(
          '${controller.model ?? '默认模型'}${controller.effort == null ? '' : ' · ${controller.effort}'} ▾',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopDrop();
    _stopPaste();
    controller.removeListener(_changed);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.item,
    required this.controller,
    required this.onError,
  });
  final ConversationItem item;
  final ConversationController controller;
  final void Function(Object) onError;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: item,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      if (item.type == 'userMessage') {
        final texts = <String>[];
        final files = <JsonMap>[];
        final references = <JsonMap>[];
        for (final part in asMaps(item.data['content'])) {
          if (part['type'] == 'skill') {
            references.add(part);
            continue;
          }
          if (part['type'] != 'text') continue;
          final text = part['text'] as String? ?? '';
          if (text.contains('<codexlink_files>')) {
            try {
              references.addAll(
                asMaps(
                  jsonDecode(
                    text
                        .split('<codexlink_files>')
                        .last
                        .split('</codexlink_files>')
                        .first,
                  ),
                ),
              );
            } on FormatException {
              texts.add(text);
            }
          } else if (text.contains('<codexlink_attachments>')) {
            final raw = text
                .split('<codexlink_attachments>')
                .last
                .split('</codexlink_attachments>')
                .first;
            try {
              files.addAll(asMaps(jsonDecode(raw)));
            } on FormatException {
              texts.add(text);
            }
          } else {
            texts.add(text);
          }
        }
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 720),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: colors.secondaryContainer.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (references.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final reference in references)
                        ActionChip(
                          avatar: Icon(
                            reference['type'] == 'skill'
                                ? Icons.auto_awesome_outlined
                                : Icons.description_outlined,
                            size: 14,
                          ),
                          label: Text(reference['name'] as String? ?? '引用文件'),
                          onPressed: reference['type'] == 'skill'
                              ? null
                              : () => openConversationLink(
                                  context,
                                  controller,
                                  reference['path'] as String,
                                  onError,
                                ),
                        ),
                    ],
                  ),
                if (texts.isNotEmpty)
                  SelectableText(
                    texts.join('\n\n'),
                    style: const TextStyle(fontSize: 15, height: 1.6),
                  ),
                if (files.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final file in files)
                        if (file['isImage'] == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: AttachmentPreview(
                              controller: controller,
                              id: file['attachmentId'] as String,
                              name: file['name'] as String,
                            ),
                          ),
                    ],
                  ),
                if (files.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: files
                          .map(
                            (file) => ActionChip(
                              avatar: const Icon(Icons.attach_file, size: 14),
                              label: Text(
                                file['name'] as String? ?? '附件',
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () async {
                                try {
                                  await controller.download({
                                    'id': file['attachmentId'],
                                    'name': file['name'],
                                  });
                                } catch (error) {
                                  onError(error);
                                }
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      if (item.type == 'agentMessage') {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 15,
                  color: colors.primary,
                ),
                const SizedBox(width: 7),
                Text(
                  item.data['phase'] == 'commentary' ? 'Codex · 进展' : 'Codex',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '复制回复',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: item.text)),
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (item.streaming)
              SelectableText(
                item.text.isEmpty ? '正在处理…' : item.text,
                style: const TextStyle(fontSize: 16, height: 1.65),
              )
            else
              MarkdownBody(
                data: item.text,
                selectable: true,
                imageBuilder: (uri, title, alt) => ConversationImage(
                  controller: controller,
                  source: uri,
                  name: alt ?? title ?? '图片',
                  onError: onError,
                ),
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: TextStyle(
                        fontSize: 16,
                        height: 1.65,
                        color: colors.onSurface,
                      ),
                      code: TextStyle(
                        fontFamily: kIsWeb ? 'CodexLinkMono' : 'monospace',
                        fontSize: 13,
                        backgroundColor: colors.surfaceContainerHigh,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                onTapLink: (_, href, _) async {
                  final uri = Uri.tryParse(href ?? '');
                  if (uri != null && ['https', 'http'].contains(uri.scheme)) {
                    if (!await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    )) {
                      onError(const ApiError('无法打开链接。'));
                    }
                  } else if (href != null && context.mounted) {
                    await openConversationLink(
                      context,
                      controller,
                      href,
                      onError,
                    );
                  }
                },
              ),
            if (asMaps(item.data['questions']).isNotEmpty)
              QuestionPrompt(
                controller: controller,
                sourceId: 'message:${item.id}',
                questions: CodexQuestion.parse(
                  item.data['questions'],
                  asynchronous: true,
                ),
              ),
          ],
        );
      }
      if (item.type == 'imageGeneration' || item.type == 'imageView') {
        final media = asMap(item.data['media']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.type == 'imageGeneration' ? '生成图片' : '查看图片',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (media.isNotEmpty)
              MediaPreview(
                controller: controller,
                media: media,
                onError: onError,
              )
            else if (item.data['mediaError'] != null ||
                item.data['failure'] != null)
              Text(
                (item.data['mediaError'] ??
                        asMap(item.data['failure'])['message'] ??
                        '图片生成失败')
                    .toString(),
              )
            else if (item.streaming || item.data['status'] == 'inProgress')
              const LinearProgressIndicator(minHeight: 2)
            else
              const Text('图片结果暂不可用，请同步会话重试。'),
          ],
        );
      }
      if (item.type == 'fileChange' || item.type == 'turnDiff') {
        final summary = item.type == 'turnDiff';
        final status = item.data['status'];
        return FileDiffCard(
          files: item.fileDiffs,
          changes: item,
          currentFiles: () => item.fileDiffs,
          title: summary
              ? (item.streaming ? '本轮文件变更 · 进行中' : '本轮文件变更')
              : status == 'failed'
              ? '文件修改失败'
              : status == 'declined'
              ? '文件修改已拒绝'
              : '文件变更',
          running: item.streaming,
          isAggregate: summary && item.data['diff'] is String,
        );
      }
      if (item.type == 'reasoning') {
        final summary = (item.data['summary'] as List? ?? [])
            .whereType<String>()
            .join('\n');
        if (summary.isEmpty) return const SizedBox.shrink();
        return ExpansionTile(
          dense: true,
          title: const Text('思考摘要', style: TextStyle(fontSize: 12)),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(summary),
            ),
          ],
        );
      }
      final title = switch (item.type) {
        'commandExecution' => '执行命令',
        'fileChange' => '文件变更',
        'mcpToolCall' => '工具调用',
        'webSearch' => '搜索',
        'contextCompaction' => '已压缩上下文',
        'plan' => '任务计划',
        _ => item.type,
      };
      final detail =
          item.data['command'] ??
          item.data['text'] ??
          item.data['tool'] ??
          item.data['query'] ??
          '';
      final rawOutput =
          item.data['aggregatedOutput'] ??
          item.data['changes'] ??
          item.data['result'] ??
          item.data['text'] ??
          '';
      final mediaParts = item.type == 'mcpToolCall'
          ? asMaps(asMap(item.data['result'])['content'])
                .where((p) => asMap(p['media']).isNotEmpty)
                .toList()
          : <JsonMap>[];
      final output = item.type == 'mcpToolCall'
          ? asMaps(asMap(item.data['result'])['content'])
                .where((p) => p['type'] == 'text')
                .map((p) => p['text'] ?? '')
                .join('\n')
          : rawOutput;
      return Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .6),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            dense: true,
            leading: item.streaming
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : Icon(
                    item.type == 'fileChange'
                        ? Icons.difference_outlined
                        : Icons.terminal_rounded,
                    size: 18,
                  ),
            title: Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            subtitle: detail.toString().isEmpty
                ? null
                : Text(
                    detail.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: kIsWeb ? 'CodexLinkMono' : 'monospace',
                    ),
                  ),
            children: [
              for (final part in mediaParts)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: MediaPreview(
                    controller: controller,
                    media: asMap(part['media']),
                    onError: onError,
                  ),
                ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SelectableText(
                  output is String
                      ? output
                      : const JsonEncoder.withIndent('  ').convert(output),
                  style: const TextStyle(
                    fontFamily: kIsWeb ? 'CodexLinkMono' : 'monospace',
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> showGoalEditor(
  BuildContext context,
  ConversationController controller,
  void Function(Object) onError,
) => showDialog<void>(
  context: context,
  builder: (_) => GoalDialog(controller: controller, onError: onError),
);

class GoalDialog extends StatefulWidget {
  const GoalDialog({
    super.key,
    required this.controller,
    required this.onError,
  });
  final ConversationController controller;
  final void Function(Object) onError;
  @override
  State<GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<GoalDialog> {
  late final _objective = TextEditingController(
    text: widget.controller.goal?['objective'] as String? ?? '',
  );
  late final _budget = TextEditingController(
    text: widget.controller.goal?['tokenBudget']?.toString() ?? '',
  );
  bool _saving = false;
  Future<void> _save() async {
    final budget = _budget.text.trim().isEmpty
        ? null
        : int.tryParse(_budget.text.trim());
    if (_objective.text.trim().isEmpty ||
        (_budget.text.trim().isNotEmpty && (budget == null || budget <= 0))) {
      widget.onError(const ApiError('请填写目标，并使用正整数预算或留空。'));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.setGoal(
        objective: _objective.text.trim(),
        status: widget.controller.goal == null ? 'active' : null,
        budget: budget,
        budgetSpecified: true,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      widget.onError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.controller.goal == null ? '设置 Goal' : '编辑 Goal'),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Codex 会围绕目标持续推进。预算留空表示不设上限。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _objective,
              minLines: 3,
              maxLines: 6,
              maxLength: 4000,
              decoration: const InputDecoration(labelText: '目标'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _budget,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Token 预算（可选）'),
            ),
            if (widget.controller.goal != null)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text(
                  '替换为新目标会重置 Goal 的用量；仅调整预算会保留用量。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.controller.goal != null)
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  try {
                    await widget.controller.clearGoal();
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    widget.onError(error);
                  }
                },
          child: const Text('清除目标'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(
          _saving
              ? '保存中…'
              : widget.controller.goal == null
              ? '开始 Goal'
              : '保存目标',
        ),
      ),
    ],
  );
  @override
  void dispose() {
    _objective.dispose();
    _budget.dispose();
    super.dispose();
  }
}

class ApprovalCard extends StatefulWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.controller,
    required this.onError,
  });
  final JsonMap approval;
  final ConversationController controller;
  final void Function(Object) onError;
  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  bool _busy = false;
  Future<void> _answer(JsonMap result) async {
    setState(() => _busy = true);
    try {
      await widget.controller.answer(widget.approval['id'] as String, result);
    } catch (error) {
      widget.onError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final method = widget.approval['method'] as String;
    final parameters = asMap(widget.approval['params']);
    final userInput = method == 'item/tool/requestUserInput';
    if (userInput) {
      return QuestionPrompt(
        controller: widget.controller,
        sourceId: 'approval:${widget.approval['id']}',
        approvalId: widget.approval['id'] as String,
        questions: CodexQuestion.parse(parameters['questions']),
        blocking: parameters['isBlocking'] != false,
      );
    }
    final permissions = method == 'item/permissions/requestApproval';
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('需要你的审批', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SelectableText(
            (parameters['reason'] ??
                    parameters['command'] ??
                    (permissions
                        ? const JsonEncoder.withIndent('  ')
                              .convert(parameters['permissions'])
                        : '请确认是否允许此操作'))
                .toString(),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _answer(
                        permissions
                            ? {
                                'permissions': parameters['permissions'],
                                'scope': 'turn',
                              }
                            : {'decision': 'accept'},
                      ),
                child: const Text('允许本次'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _answer(
                        permissions
                            ? {'permissions': {}, 'scope': 'turn'}
                            : {'decision': 'decline'},
                      ),
                child: const Text('拒绝'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
