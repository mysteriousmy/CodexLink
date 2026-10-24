import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/file_diff.dart';

class FileDiffCard extends StatelessWidget {
  const FileDiffCard({
    super.key,
    required this.files,
    this.title = '文件变更',
    this.running = false,
    this.isAggregate = false,
    this.changes,
    this.currentFiles,
  });
  final List<FileDiff> files;
  final String title;
  final bool running, isAggregate;
  final Listenable? changes;
  final List<FileDiff> Function()? currentFiles;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                if (running)
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Icon(
                    Icons.difference_outlined,
                    size: 18,
                    color: colors.primary,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${files.length} 个文件',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (files.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text('等待文件变更内容…', style: TextStyle(fontSize: 12)),
            ),
          for (final file in files)
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  fullscreenDialog:
                      kIsWeb || defaultTargetPlatform != TargetPlatform.android,
                  builder: (_) => FileDiffScreen(
                    file: file,
                    aggregate: isAggregate,
                    changes: changes,
                    currentFile: () =>
                        currentFiles
                            ?.call()
                            .where((f) => f.path == file.path)
                            .firstOrNull ??
                        file,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
                child: Row(
                  children: [
                    _KindBadge(file: file),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          if (file.previousPath != null)
                            Text(
                              '原路径：${file.previousPath}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          if (file.operations > 1)
                            Text(
                              '${file.operations} 次修改记录',
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Counts(file: file),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

Color _added(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff80d7a6)
    : const Color(0xff177245);
Color _removed(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xffffa4ad)
    : const Color(0xffb52c42);

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.file});
  final FileDiff file;
  @override
  Widget build(BuildContext context) {
    final color = file.kind == 'add'
        ? _added(context)
        : file.kind == 'delete'
        ? _removed(context)
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        file.label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.file});
  final FileDiff file;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '+${file.additions}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _added(context),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        '−${file.deletions}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _removed(context),
        ),
      ),
    ],
  );
}

class FileDiffScreen extends StatefulWidget {
  const FileDiffScreen({
    super.key,
    required this.file,
    this.aggregate = false,
    this.changes,
    this.currentFile,
  });
  final FileDiff file;
  final bool aggregate;
  final Listenable? changes;
  final FileDiff Function()? currentFile;
  @override
  State<FileDiffScreen> createState() => _FileDiffScreenState();
}

class _FileDiffScreenState extends State<FileDiffScreen> {
  bool _wrap = true;
  final _horizontal = ScrollController();
  @override
  Widget build(BuildContext context) => widget.changes == null
      ? _content(context)
      : AnimatedBuilder(
          animation: widget.changes!,
          builder: (context, _) => _content(context),
        );
  Widget _content(BuildContext context) {
    final file = widget.currentFile?.call() ?? widget.file;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: () => Navigator.pop(context)),
        title: Text(file.path, style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            tooltip: _wrap ? '关闭自动换行' : '自动换行',
            isSelected: _wrap,
            onPressed: () => setState(() => _wrap = !_wrap),
            icon: const Icon(Icons.wrap_text),
          ),
          IconButton(
            tooltip: '复制 Diff',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: file.diff));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Diff 已复制')));
              }
            },
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: colors.surfaceContainerLow,
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _KindBadge(file: file),
                _Counts(file: file),
                Text(
                  widget.aggregate
                      ? '本轮合并 Diff'
                      : file.operations > 1
                      ? '按时间排列的修改记录'
                      : '此次文件修改',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: file.lines.isEmpty
                ? const Center(child: Text('Codex 未提供此文件的文本 Diff。'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      Widget list(double width) => SizedBox(
                        width: width,
                        child: SelectionArea(
                          child: ListView.builder(
                            key: const ValueKey('diff-lines'),
                            itemCount: file.lines.length,
                            itemBuilder: (context, index) =>
                                _DiffRow(line: file.lines[index], wrap: _wrap),
                          ),
                        ),
                      );
                      if (_wrap) return list(constraints.maxWidth);
                      final columns = file.lines.fold<int>(
                        0,
                        (max, line) => math.max(
                          max,
                          line.text.runes.fold<int>(
                            0,
                            (n, rune) => n + (rune > 0x2e80 ? 2 : 1),
                          ),
                        ),
                      );
                      return Scrollbar(
                        controller: _horizontal,
                        thumbVisibility: true,
                        notificationPredicate: (n) =>
                            n.metrics.axis == Axis.horizontal,
                        child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: list(
                            math.max(constraints.maxWidth, 120 + columns * 8.0),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line, required this.wrap});
  final DiffLine line;
  final bool wrap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = switch (line.kind) {
      DiffLineKind.addition => _added(context),
      DiffLineKind.deletion => _removed(context),
      DiffLineKind.hunk => colors.primary,
      DiffLineKind.metadata => colors.onSurfaceVariant,
      _ => colors.onSurface,
    };
    final background = switch (line.kind) {
      DiffLineKind.addition ||
      DiffLineKind.deletion => foreground.withValues(alpha: .1),
      DiffLineKind.hunk => colors.primaryContainer.withValues(alpha: .45),
      DiffLineKind.metadata => colors.surfaceContainerLow,
      _ => Colors.transparent,
    };
    final marker = line.kind == DiffLineKind.addition
        ? '+'
        : line.kind == DiffLineKind.deletion
        ? '−'
        : ' ';
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 39,
            child: Text(
              '${line.oldLine ?? ''}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 39,
            child: Text(
              '${line.newLine ?? ''}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 16,
            child: Text(
              marker,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                line.text.isEmpty ? ' ' : line.text,
                softWrap: wrap,
                style: TextStyle(
                  fontFamily: kIsWeb ? 'CodexLinkMono' : 'monospace',
                  fontSize: 12,
                  height: 1.55,
                  color: foreground,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
