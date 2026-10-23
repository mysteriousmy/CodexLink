import 'dart:convert';

import 'api_client.dart';

enum DiffLineKind { context, addition, deletion, hunk, metadata }

class DiffLine {
  const DiffLine(this.text, this.kind, {this.oldLine, this.newLine});
  final String text;
  final DiffLineKind kind;
  final int? oldLine, newLine;
}

class FileDiff {
  FileDiff({
    required this.path,
    required this.kind,
    required this.diff,
    this.previousPath,
    this.operations = 1,
  }) : lines = parseDiffLines(diff, kind);
  final String path, kind, diff;
  final String? previousPath;
  final int operations;
  final List<DiffLine> lines;
  int get additions =>
      lines.where((line) => line.kind == DiffLineKind.addition).length;
  int get deletions =>
      lines.where((line) => line.kind == DiffLineKind.deletion).length;
  String get label => previousPath != null
      ? '重命名'
      : switch (kind) {
          'add' => '新增',
          'delete' => '删除',
          _ => '修改',
        };

  factory FileDiff.fromChange(JsonMap change) {
    final kind = asMap(change['kind']);
    final source = change['path'] as String? ?? '未知文件';
    final moved = kind['move_path'] as String?;
    return FileDiff(
      path: moved ?? source,
      previousPath: moved == null ? null : source,
      kind: kind['type'] as String? ?? 'update',
      diff: change['diff'] as String? ?? '',
    );
  }
}

List<DiffLine> parseDiffLines(String diff, String kind) {
  if (diff.isEmpty) return const [];
  final raw = const LineSplitter().convert(diff);
  final hasPatch = raw.any(
    (s) =>
        s.startsWith('@@') ||
        s.startsWith('diff --git ') ||
        s.startsWith('--- '),
  );
  int? oldLine, newLine;
  final lines = <DiffLine>[];
  final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  for (final line in raw) {
    final match = hunk.firstMatch(line);
    if (match != null) {
      oldLine = int.parse(match.group(1)!);
      newLine = int.parse(match.group(2)!);
      lines.add(DiffLine(line, DiffLineKind.hunk));
    } else if (line.startsWith('diff --git ') ||
        line.startsWith('index ') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ ') ||
        line.startsWith('new file mode ') ||
        line.startsWith('deleted file mode ') ||
        line.startsWith('old mode ') ||
        line.startsWith('new mode ') ||
        line.startsWith('rename ') ||
        line.startsWith('similarity index ') ||
        line.startsWith('Binary files ') ||
        line == 'GIT binary patch' ||
        line.startsWith(r'\ No newline')) {
      lines.add(DiffLine(line, DiffLineKind.metadata));
    } else if (line.startsWith('+') || (!hasPatch && kind == 'add')) {
      lines.add(
        DiffLine(
          line.startsWith('+') ? line.substring(1) : line,
          DiffLineKind.addition,
          newLine: newLine,
        ),
      );
      if (newLine != null) newLine++;
    } else if (line.startsWith('-') || (!hasPatch && kind == 'delete')) {
      lines.add(
        DiffLine(
          line.startsWith('-') ? line.substring(1) : line,
          DiffLineKind.deletion,
          oldLine: oldLine,
        ),
      );
      if (oldLine != null) oldLine++;
    } else {
      lines.add(
        DiffLine(
          hasPatch && line.startsWith(' ') ? line.substring(1) : line,
          DiffLineKind.context,
          oldLine: oldLine,
          newLine: newLine,
        ),
      );
      if (oldLine != null) oldLine++;
      if (newLine != null) newLine++;
    }
  }
  return lines;
}

String _gitPath(String path) {
  var value = path.split('\t').first.trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    // Git quotes UTF-8 paths with octal byte escapes, not JSON escapes.
    final bytes = <int>[];
    value = value.substring(1, value.length - 1);
    for (var i = 0; i < value.length; i++) {
      if (value[i] == r'\' && i + 1 < value.length) {
        final octal = RegExp(r'^[0-7]{3}').firstMatch(value.substring(i + 1));
        if (octal != null) {
          bytes.add(int.parse(octal.group(0)!, radix: 8));
          i += 3;
        } else {
          i++;
          bytes.addAll(
            utf8.encode(switch (value[i]) {
              't' => '\t',
              'n' => '\n',
              _ => value[i],
            }),
          );
        }
      } else {
        bytes.addAll(utf8.encode(value[i]));
      }
    }
    value = utf8.decode(bytes, allowMalformed: true);
  }
  return value.startsWith('a/') || value.startsWith('b/')
      ? value.substring(2)
      : value;
}

List<FileDiff> parseUnifiedDiff(String diff) {
  final sections = <List<String>>[];
  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('diff --git ') || sections.isEmpty) sections.add([]);
    sections.last.add(line);
  }
  return sections
      .where(
        (lines) => lines.any(
          (s) => s.startsWith('diff --git ') || s.startsWith('+++ '),
        ),
      )
      .map((lines) {
        String? before, after, renameFrom, renameTo;
        var kind = 'update';
        for (final line in lines) {
          if (line.startsWith('--- ')) before = _gitPath(line.substring(4));
          if (line.startsWith('+++ ')) after = _gitPath(line.substring(4));
          if (line.startsWith('rename from ')) {
            renameFrom = _gitPath(line.substring(12));
          }
          if (line.startsWith('rename to ')) {
            renameTo = _gitPath(line.substring(10));
          }
          if (line.startsWith('new file mode ') || before == '/dev/null') {
            kind = 'add';
          }
          if (line.startsWith('deleted file mode ') || after == '/dev/null') {
            kind = 'delete';
          }
        }
        var fallback = '文件变更';
        final header = lines.firstWhere(
          (s) => s.startsWith('diff --git '),
          orElse: () => '',
        );
        final paths = RegExp(
          r'^diff --git ("(?:\\.|[^"\\])*"|a/.*?) ("(?:\\.|[^"\\])*"|b/.*)$',
        ).firstMatch(header);
        if (paths != null) fallback = _gitPath(paths.group(2)!);
        return FileDiff(
          path: renameTo ?? (after == '/dev/null' ? before : after) ?? fallback,
          previousPath: renameFrom,
          kind: kind,
          diff: lines.join('\n'),
        );
      })
      .toList();
}

List<FileDiff> combineFileChanges(Iterable<JsonMap> changes) {
  final grouped = <String, List<FileDiff>>{};
  for (final change in changes) {
    final file = FileDiff.fromChange(change);
    grouped.putIfAbsent(file.path, () => []).add(file);
  }
  return grouped.values
      .map(
        (steps) => steps.length == 1
            ? steps.single
            : FileDiff(
                path: steps.last.path,
                kind: steps.last.kind,
                previousPath: steps.last.previousPath,
                operations: steps.length,
                diff: steps.indexed
                    .map((entry) => '变更记录 ${entry.$1 + 1}\n${entry.$2.diff}')
                    .join('\n\n'),
              ),
      )
      .toList();
}
