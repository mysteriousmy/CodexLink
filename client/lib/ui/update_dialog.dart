import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/release_info.dart';
import '../data/update_controller.dart';

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateController controller,
) {
  unawaited(controller.check(manual: true));
  return showDialog<void>(
    context: context,
    builder: (_) => UpdateDialog(controller: controller),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.controller, this.openLink});
  final UpdateController controller;
  final Future<bool> Function(Uri)? openLink;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  String? _selectedTarget;
  String? _linkError;

  Future<void> _open(Uri uri) async {
    try {
      final opened =
          await (widget.openLink?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (mounted) setState(() => _linkError = opened ? null : '无法打开下载链接，请重试。');
    } catch (_) {
      if (mounted) setState(() => _linkError = '无法打开下载链接，请重试。');
    }
  }

  String _comparison(String? current) {
    final release = widget.controller.release;
    final installed = parseVersion(current);
    if (installed == null || release == null) return '尚未完成版本比较';
    if (release.version > installed) return '可更新至 v${release.version}';
    if (release.version < installed) return '当前版本高于最新正式版';
    return '已是最新版本';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final release = c.release;
      final target = c.server?.target ?? _selectedTarget;
      final serverAsset = release?.serverAsset(target);
      final appAsset = release?.appAsset(c.client);
      final isWeb = c.client?.isWeb == true;
      return AlertDialog(
        title: const Text('检查更新'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.checking) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text('正在检查 GitHub Release…'),
                ] else if (release != null)
                  Text(
                    '最新正式版 v${release.version}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                if (c.releaseError != null) _error(c.releaseError!),
                const SizedBox(height: 16),
                Text(
                  isWeb ? '网页端' : 'App',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text('当前版本：${c.client?.version ?? '未知'}'),
                Text(_comparison(c.client?.version)),
                if (c.clientError != null) _error(c.clientError!),
                if (c.appUpdateAvailable && isWeb)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('网页随服务端一起更新。升级服务端后，刷新页面即可使用新版本。'),
                  ),
                if (c.appUpdateAvailable && !isWeb)
                  if (appAsset != null)
                    _download('下载 App', appAsset)
                  else
                    const Text('此 Release 暂无适用于当前 App 平台的安装包。'),
                const Divider(height: 32),
                Text('服务端', style: Theme.of(context).textTheme.titleSmall),
                Text('当前版本：${c.server?.version ?? '未知'}'),
                if (c.server?.target != null)
                  Text(serverTargets[c.server!.target]!),
                Text(_comparison(c.server?.version)),
                if (c.serverError != null) _error(c.serverError!),
                if (c.serverUpdateAvailable) ...[
                  if (c.server?.target == null &&
                      c.server?.platform == null) ...[
                    const Text('旧服务端未提供平台信息，请选择电脑的系统和架构。'),
                    DropdownButton<String>(
                      key: const ValueKey('server-update-platform'),
                      isExpanded: true,
                      value: _selectedTarget,
                      hint: const Text('选择服务端平台'),
                      items: serverTargets.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _selectedTarget = value),
                    ),
                  ],
                  if (serverAsset != null)
                    _download('下载服务端', serverAsset)
                  else if (target != null)
                    const Text('此 Release 暂无对应服务端平台的安装包。'),
                  if (target == null && c.server?.platform != null)
                    Text(
                      '此 Release 暂无 ${c.server!.platform} ${c.server!.architecture ?? ''} 服务端安装包。',
                    ),
                ],
                const Divider(height: 32),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动检查更新'),
                  subtitle: const Text('连接与返回前台时检查，间隔 6 小时'),
                  value: c.automatic,
                  onChanged: (value) => unawaited(c.setAutomatic(value)),
                ),
                if (c.checkedAt != null)
                  Text(
                    '上次成功检查：${_time(c.checkedAt!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (_linkError != null) _error(_linkError!),
                if (c.preferenceError != null) _error(c.preferenceError!),
                if (release != null)
                  TextButton.icon(
                    onPressed: () => _open(release.page),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('查看 GitHub Release'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton.tonal(
            onPressed: c.checking
                ? null
                : () => unawaited(c.check(manual: true)),
            child: const Text('重新检查'),
          ),
        ],
      );
    },
  );

  Widget _error(String message) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  Widget _download(String label, ReleaseAsset asset) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          onPressed: () => _open(asset.url),
          icon: const Icon(Icons.download_rounded),
          label: Text(label),
        ),
        Text(asset.name, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );

  String _time(DateTime time) {
    final local = time.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${pad(local.hour)}:${pad(local.minute)}';
  }
}
