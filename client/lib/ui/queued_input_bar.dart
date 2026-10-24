import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/conversation_controller.dart';

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
    if (entries.isEmpty && controller.queueError == null) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('queued-input-bar'),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.queueError != null)
            TextButton.icon(
              onPressed: controller.refreshQueue,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(controller.queueError!),
            ),
          for (final input in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.playlist_add_check_rounded,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          input['text'] as String? ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(
                        pending != null && pendingInput['id'] == input['id']
                            ? controller.queueActionBusy
                                  ? '正在处理…'
                                  : '结果待核对'
                            : '本轮结束后发送${_details(input)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (pending != null &&
                          pendingInput['id'] == input['id']) ...[
                        TextButton(
                          onPressed: controller.queueActionBusy
                              ? null
                              : controller.reconcileQueueAction,
                          child: const Text('核对结果'),
                        ),
                        TextButton(
                          onPressed: controller.queueActionBusy
                              ? null
                              : () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('取回未确认内容的副本'),
                                      content: const Text(
                                        '请先核对最新消息。这不会撤回可能已经发送的内容；再次发送可能重复执行。',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('继续核对'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('已核对，取回副本'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    await controller
                                        .restoreUnconfirmedQueueCopy();
                                  }
                                },
                          child: const Text('取回副本'),
                        ),
                      ] else ...[
                        TextButton(
                          onPressed:
                              controller.canControl &&
                                  pending == null &&
                                  !controller.sending
                              ? () => controller.actOnQueuedInput(
                                  input,
                                  sendNow: true,
                                )
                              : null,
                          child: const Text('立即发送'),
                        ),
                        TextButton(
                          onPressed:
                              controller.canControl &&
                                  pending == null &&
                                  !controller.sending
                              ? () => controller.actOnQueuedInput(
                                  input,
                                  sendNow: false,
                                )
                              : null,
                          child: const Text('撤回'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _details(JsonMap input) {
    final files = asMaps(input['attachments']).length;
    final references = asMaps(input['references']).length;
    return '${files > 0 ? ' · $files 个附件' : ''}${references > 0 ? ' · $references 个引用' : ''}';
  }
}
