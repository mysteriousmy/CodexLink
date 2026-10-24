import 'package:flutter/material.dart';

import '../data/conversation_controller.dart';
import '../data/api_client.dart';

class TaskActivity extends StatelessWidget {
  const TaskActivity({
    super.key,
    required this.controller,
    required this.connected,
  });
  final ConversationController controller;
  final bool connected;
  @override
  Widget build(BuildContext context) {
    final waiting = controller.approvals.any(
      (a) =>
          a['method'] != 'item/tool/requestUserInput' ||
          asMap(a['params'])['isBlocking'] != false,
    );
    final active = connected && controller.activeTurnId != null && !waiting;
    final label = !connected
        ? '连接已断开 · 正在重新同步'
        : controller.sending
        ? '正在提交'
        : waiting
        ? '等待你的回复或审批'
        : active
        ? controller.activity ?? '正在执行'
        : controller.goal?['status'] == 'active'
        ? 'Goal 已启用 · 等待下一步'
        : null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: label == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey(label),
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Row(
                children: [
                  if (active || controller.sending)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  else
                    Icon(
                      waiting ? Icons.pending_actions_outlined : Icons.sync,
                      size: 15,
                    ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
