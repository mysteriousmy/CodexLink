import 'package:flutter/material.dart';

import 'dart:convert';

import '../data/api_client.dart';
import '../platform/svg_preview.dart';
import '../platform/transport.dart' as transport;

import '../data/conversation_controller.dart';

Uri workspaceFileUri(
  ConversationController controller,
  String path, {
  bool download = false,
}) => controller.api.uri('/api/threads/${controller.threadId}/file', {
  'path': path,
  if (download) 'download': 'true',
});

Future<void> openConversationLink(
  BuildContext context,
  ConversationController controller,
  String href,
  void Function(Object) onError,
) async {
  final uri = Uri.tryParse(href);
  if (uri == null || !['', 'file', 'sandbox'].contains(uri.scheme)) return;
  var path = Uri.decodeFull(href);
  // Source links may include line anchors; those aren't part of the filename.
  path = path
      .replaceFirst(RegExp(r'#L?\d+.*$'), '')
      .replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');
  final name = path.split('/').last;
  await showFilePreview(
    context,
    controller,
    workspaceFileUri(controller, path),
    name,
    onError,
    downloadUri: workspaceFileUri(controller, path, download: true),
  );
}

Future<void> showFilePreview(
  BuildContext context,
  ConversationController controller,
  Uri uri,
  String name,
  void Function(Object) onError, {
  Uri? downloadUri,
}) => showDialog<void>(
  context: context,
  builder: (_) => _FileDialog(
    controller: controller,
    uri: uri,
    downloadUri: downloadUri ?? uri,
    name: name,
    onError: onError,
  ),
);

class _FileDialog extends StatefulWidget {
  const _FileDialog({
    required this.controller,
    required this.uri,
    required this.downloadUri,
    required this.name,
    required this.onError,
  });
  final ConversationController controller;
  final Uri uri, downloadUri;
  final String name;
  final void Function(Object) onError;
  @override
  State<_FileDialog> createState() => _FileDialogState();
}

class _FileDialogState extends State<_FileDialog> {
  late final _file = widget.controller.api.getFile(widget.uri);
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 960,
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '下载文件',
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () async {
                    try {
                      await transport.downloadFile(
                        widget.downloadUri,
                        widget.controller.api.token,
                        widget.name,
                      );
                    } catch (e) {
                      widget.onError(e);
                    }
                  },
                ),
                IconButton(
                  tooltip: '关闭预览',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder(
                future: _file,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(snapshot.error.toString()));
                  }
                  final file = snapshot.data;
                  if (file == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final type = file.headers['content-type'] ?? '';
                  if (type.contains('image/svg+xml')) {
                    return SvgPreview(bytes: file.bodyBytes);
                  }
                  if (type.startsWith('image/')) {
                    return InteractiveViewer(
                      child: Center(
                        child: Image.memory(
                          file.bodyBytes,
                          fit: BoxFit.contain,
                        ),
                      ),
                    );
                  }
                  if (type.startsWith('text/') || type.contains('json')) {
                    return SingleChildScrollView(
                      child: SelectableText(
                        utf8.decode(
                          file.bodyBytes.take(1024 * 1024).toList(),
                          allowMalformed: true,
                        ),
                      ),
                    );
                  }
                  return const Center(child: Text('此类型支持下载后打开。'));
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MediaPreview extends StatelessWidget {
  const MediaPreview({
    super.key,
    required this.controller,
    required this.media,
    required this.onError,
  });
  final ConversationController controller;
  final JsonMap media;
  final void Function(Object) onError;
  @override
  Widget build(BuildContext context) {
    final uri = controller.api.uri('/api/media/${media['id']}');
    final name = media['name'] as String? ?? '图片';
    return InkWell(
      onTap: () => showFilePreview(
        context,
        controller,
        uri,
        name,
        onError,
        downloadUri: uri.replace(queryParameters: {'download': 'true'}),
      ),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (media['contentType'] == 'image/svg+xml')
              const SizedBox(
                height: 120,
                child: Center(child: Icon(Icons.animation, size: 42)),
              )
            else
              Image.network(
                uri.toString(),
                headers: controller.api.headers,
                height: 260,
                width: 480,
                fit: BoxFit.contain,
                cacheWidth: 960,
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('图片预览不可用，点击查看详情。'),
                ),
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const SizedBox(
                        height: 260,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.open_in_full, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      media['contentType'] == 'image/svg+xml'
                          ? '打开 SVG 动画'
                          : '查看图片',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const Icon(Icons.download_outlined, size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ConversationImage extends StatelessWidget {
  const ConversationImage({
    super.key,
    required this.controller,
    required this.source,
    required this.name,
    required this.onError,
  });
  final ConversationController controller;
  final Uri source;
  final String name;
  final void Function(Object) onError;
  @override
  Widget build(BuildContext context) {
    final local = ['', 'file', 'sandbox'].contains(source.scheme);
    if (!local && !['https', 'http'].contains(source.scheme)) {
      return const Text('不支持此图片地址。');
    }
    final uri = local
        ? workspaceFileUri(controller, Uri.decodeFull(source.toString()))
        : source;
    final svg = source.path.toLowerCase().endsWith('.svg');
    return InkWell(
      onTap: () {
        if (local) {
          openConversationLink(context, controller, source.toString(), onError);
        }
      },
      child: svg
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.animation),
                  SizedBox(width: 8),
                  Text('打开 SVG 动画'),
                ],
              ),
            )
          : Image.network(
              uri.toString(),
              headers: local ? controller.api.headers : null,
              height: 260,
              fit: BoxFit.contain,
              cacheWidth: 960,
              errorBuilder: (_, _, _) => Text('$name · 无法加载，点击查看详情'),
            ),
    );
  }
}

class AttachmentPreview extends StatelessWidget {
  const AttachmentPreview({
    super.key,
    required this.controller,
    required this.id,
    required this.name,
    this.compact = false,
  });
  final ConversationController controller;
  final String id, name;
  final bool compact;

  Widget picture({bool full = false}) => Image.network(
    controller.api.uri('/api/attachments/$id', {'preview': 'true'}).toString(),
    headers: controller.api.headers,
    width: full
        ? null
        : compact
        ? 38
        : 180,
    height: full
        ? null
        : compact
        ? 38
        : 120,
    cacheWidth: full ? 1600 : 360,
    fit: full ? BoxFit.contain : BoxFit.cover,
    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    loadingBuilder: (_, child, progress) => progress == null
        ? child
        : const SizedBox(
            width: 38,
            height: 38,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
  );

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '预览 $name',
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭预览',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Flexible(child: InteractiveViewer(child: picture(full: true))),
              ],
            ),
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: picture(),
      ),
    ),
  );
}
