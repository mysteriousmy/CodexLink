import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/conversation_controller.dart';
import 'composer_status_bar.dart';

class QueuedInputBar extends StatelessWidget {
  const QueuedInputBar({super.key, required this.controller});
  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final pending = controller.pendingQueueAction;
    final pendingInput = asMap(pending?['submission']);
    final entries = [
      ...controller.queuedInputs,
      if (pending != null &&
          !controller.queuedInputs.any((q) => q['id'] == pendingInput['id']))
        pendingInput,
    ];
    if (entries.isEmpty &&
        controller.acceptedSteers.isEmpty &&
        controller.queueError == null) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const ValueKey('queued-input-bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final input in controller.acceptedSteers)
          ComposerStatusBar(
            key: ValueKey('accepted-steer-${input['id']}'),
            icon: Icons.hourglass_top_rounded,
            title: controller.activeTurnId == input['turnId']
                ? '已提交给 Codex · 等待处理'
                : '已提交给 Codex · 等待同步确认',
            subtitle: input['text'] as String? ?? '',
            onTap: () => _showSubmitted(context),
            actions: [
              IconButton(
                tooltip: '同步补充指令状态',
                onPressed: controller.loading ? null : controller.reload,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        if (controller.queueError != null)
          ComposerStatusBar(
            icon: Icons.error_outline,
            title: '待发送 · 暂时无法同步',
            subtitle: controller.queueError!,
            onTap: controller.refreshQueue,
            actions: [
              IconButton(
                tooltip: '刷新待发送内容',
                onPressed: controller.refreshQueue,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        for (final input in entries)
          _entry(context, input, pendingInput, pending != null),
      ],
    );
  }

  Widget _entry(
    BuildContext context,
    JsonMap input,
    JsonMap pendingInput,
    bool hasPending,
  ) {
    final isPending = hasPending && pendingInput['id'] == input['id'];
    final enabled = controller.canControl && !hasPending && !controller.sending;
    final state = isPending
        ? controller.queueActionBusy
              ? '正在处理…'
              : '结果待核对'
        : '本轮结束后发送';
    final text = input['text'] as String? ?? '';
    final details = _details(input);
    return ComposerStatusBar(
      icon: Icons.playlist_add_check_rounded,
      title: '待发送 · $state',
      subtitle: text.isEmpty ? details : text,
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('待发送 · $state'),
          content: SingleChildScrollView(
            child: SelectableText(
              [
                if (text.isNotEmpty) text,
                if (details.isNotEmpty) details,
              ].join('\n\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
      actions: isPending
          ? [
              IconButton(
                tooltip: '核对结果',
                onPressed: controller.queueActionBusy
                    ? null
                    : controller.reconcileQueueAction,
                icon: const Icon(Icons.refresh, size: 20),
              ),
              IconButton(
                tooltip: '取回副本',
                onPressed: controller.queueActionBusy
                    ? null
                    : () => _restoreCopy(context),
                icon: const Icon(Icons.content_copy_outlined, size: 18),
              ),
            ]
          : [
              IconButton(
                tooltip: controller.activeTurnId == null ? '立即发送' : '立即 steer',
                onPressed: enabled
                    ? () => controller.actOnQueuedInput(input, sendNow: true)
                    : null,
                icon: const Icon(Icons.send_outlined, size: 18),
              ),
              IconButton(
                tooltip: '撤回',
                onPressed: enabled
                    ? () => controller.actOnQueuedInput(input, sendNow: false)
                    : null,
                icon: const Icon(Icons.undo_rounded, size: 20),
              ),
            ],
    );
  }

  Future<void> _showSubmitted(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('已提交给 Codex'),
      content: const Text(
        '这条补充已经交给 Codex，等待处理或同步确认。已提交的内容无法撤回，也无需再次发送。右侧按钮只刷新处理状态。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  Future<void> _restoreCopy(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取回未确认内容的副本'),
        content: const Text('请先核对最新消息。这不会撤回可能已经发送的内容；再次发送可能重复执行。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续核对'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('已核对，取回副本'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.restoreUnconfirmedQueueCopy();
  }

  String _details(JsonMap input) {
    final files = asMaps(input['attachments']).length;
    final references = asMaps(input['references']).length;
    return [
      if (files > 0) '$files 个附件',
      if (references > 0) '$references 个引用',
    ].join(' · ');
  }
}
