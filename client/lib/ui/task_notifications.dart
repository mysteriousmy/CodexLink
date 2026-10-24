import 'dart:async';

import 'package:flutter/material.dart';

import '../data/task_notification_controller.dart';

class TaskNotificationToasts extends StatelessWidget {
  const TaskNotificationToasts({super.key, required this.controller});
  final TaskNotificationController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.warning != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                child: Row(
                  children: [
                    Expanded(child: Text(controller.warning!)),
                    IconButton(
                      tooltip: '关闭通知提示',
                      onPressed: controller.dismissWarning,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
        for (final notice in controller.notices)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              key: ValueKey('task-notice-${notice.id}'),
              elevation: 6,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => controller.open(notice),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
                  child: Row(
                    children: [
                      Icon(
                        notice.question
                            ? Icons.help_outline
                            : notice.failed
                            ? Icons.error_outline
                            : Icons.task_alt,
                        color: notice.failed
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              notice.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              notice.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭任务提醒',
                        onPressed: () => controller.dismiss(notice.id),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

Future<void> showTaskNotificationSettings(
  BuildContext context,
  TaskNotificationController controller,
) async {
  await controller.refresh();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => _NotificationStatusWatch(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final settings = controller.settings;
          final supported = controller.serverSupported;
          final systemEnabled =
              settings.enabled && settings.permission == 'granted';
          return AlertDialog(
            title: const Text('任务通知'),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !settings.available
                          ? '此平台暂不支持后台任务通知。'
                          : !supported
                          ? '电脑服务需升级后才能开启任务通知。'
                          : settings.android
                          ? '开启后，Codex 提问、任务完成或失败会显示手机通知。提问通知包含问题摘要，点按可打开对应会话。系统会保留一条后台连接提示。'
                          : '页面打开时接收提问、任务完成或失败提醒。有通知权限时弹系统通知，否则在页面右上角显示气泡。点按问题摘要可打开对应会话。',
                    ),
                    if (settings.available && supported) ...[
                      const SizedBox(height: 14),
                      Text(
                        systemEnabled
                            ? '系统通知已开启'
                            : settings.browser
                            ? '当前使用页面气泡提示'
                            : '后台通知未开启',
                      ),
                      if (settings.enabled && settings.android)
                        Text(switch (settings.connection) {
                          'connected' => '提醒连接正常',
                          'connecting' => '正在连接提醒服务…',
                          'reconnecting' => '提醒连接中断，正在重连…',
                          _ => '提醒服务未运行，请重新开启',
                        }),
                      if (settings.enabled &&
                          settings.android &&
                          settings.connection != 'connected')
                        TextButton.icon(
                          onPressed: controller.busy ? null : controller.enable,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('立即重连'),
                        ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: controller.busy
                            ? null
                            : systemEnabled
                            ? controller.disable
                            : controller.enable,
                        icon: Icon(
                          systemEnabled
                              ? Icons.notifications_off_outlined
                              : Icons.notifications_active_outlined,
                        ),
                        label: Text(
                          systemEnabled
                              ? settings.browser
                                    ? '改用页面气泡'
                                    : '关闭后台通知'
                              : '开启系统通知',
                        ),
                      ),
                      if (settings.permission == 'denied' ||
                          settings.permission == 'unavailable') ...[
                        const SizedBox(height: 8),
                        Text(
                          settings.browser &&
                                  settings.permission == 'unavailable'
                              ? '此地址或浏览器不支持系统通知；HTTPS 或 localhost 可申请权限。'
                              : '通知权限未允许，可在系统或浏览器设置中修改。',
                        ),
                        TextButton(
                          onPressed: controller.notificationSettings,
                          child: const Text('查看通知权限设置'),
                        ),
                      ],
                      if (settings.android) ...[
                        const Divider(height: 24),
                        Text(
                          settings.batteryExempt
                              ? '已允许锁屏后台运行'
                              : '要在锁屏后及时提醒，还需允许后台运行。',
                        ),
                        if (!settings.batteryExempt)
                          OutlinedButton(
                            onPressed: controller.backgroundAccess,
                            child: const Text('允许锁屏后台运行'),
                          ),
                        const SizedBox(height: 8),
                        const Text(
                          '部分手机还需在系统中允许自启动与后台活动。强行停止 App 后，需重新打开才能接收提醒。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ],
                    if (settings.error != null ||
                        controller.warning != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        controller.warning ?? settings.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _NotificationStatusWatch extends StatefulWidget {
  const _NotificationStatusWatch({
    required this.controller,
    required this.child,
  });
  final TaskNotificationController controller;
  final Widget child;
  @override
  State<_NotificationStatusWatch> createState() =>
      _NotificationStatusWatchState();
}

class _NotificationStatusWatchState extends State<_NotificationStatusWatch> {
  Timer? _refresh;
  @override
  void initState() {
    super.initState();
    // Only read the local Android service while the settings route is visible.
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) {
      if (widget.controller.settings.android) {
        unawaited(widget.controller.refresh());
      }
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
