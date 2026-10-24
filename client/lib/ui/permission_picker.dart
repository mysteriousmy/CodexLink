import 'package:flutter/material.dart';

import '../data/conversation_controller.dart';
import '../data/api_client.dart';

class PermissionPicker extends StatelessWidget {
  const PermissionPicker({
    super.key,
    required this.controller,
    required this.onError,
  });
  final ConversationController controller;
  final void Function(Object) onError;

  Future<void> _open(BuildContext context) async {
    final threadId = controller.threadId;
    if (threadId == null) return;
    final options = controller.loadPermissionOptions();
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('会话权限'),
        contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        content: SizedBox(
          width: 440,
          child: FutureBuilder<List<JsonMap>>(
            future: options,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('无法读取权限：${snapshot.error}');
              if (!snapshot.hasData) {
                return const SizedBox(
                  height: 80,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '当前：${controller.permissionLabel} · 对后续轮次生效',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final option in snapshot.data!)
                      ListTile(
                        enabled: option['allowed'] == true,
                        selected:
                            option['id'] == controller.permissions['preset'],
                        leading: Icon(
                          option['id'] == controller.permissions['preset']
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        title: Text(option['label'] as String),
                        subtitle: Text(
                          option['allowed'] == true
                              ? option['description'] as String
                              : option['reason'] as String,
                        ),
                        onTap: option['allowed'] == true
                            ? () =>
                                  Navigator.pop(context, option['id'] as String)
                            : null,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    try {
      await controller.setPermissionPreset(selected, threadId);
    } catch (error) {
      onError(error);
    }
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: controller.canChangePermissions
        ? '切换会话权限'
        : '权限：${controller.permissionLabel}；执行结束并暂停 Goal 后可切换',
    child: TextButton.icon(
      key: const ValueKey('permission-picker'),
      onPressed: controller.canChangePermissions ? () => _open(context) : null,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      icon: controller.permissionsBusy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              controller.permissions['preset'] == 'full-access'
                  ? Icons.shield_rounded
                  : Icons.shield_outlined,
              size: 17,
            ),
      label: Text(
        controller.permissionLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );
}
