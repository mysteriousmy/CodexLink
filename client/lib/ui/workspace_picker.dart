import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/conversation_controller.dart' show newRequestId;

import '../data/app_controller.dart';
import '../data/api_client.dart';

class WorkspaceTarget {
  const WorkspaceTarget({this.projectId, required this.path});
  final String? projectId;
  final String path;
}

Future<WorkspaceTarget?> showWorkspacePicker(
  BuildContext context,
  AppController controller,
) => showDialog<WorkspaceTarget>(
  context: context,
  builder: (_) => _WorkspacePicker(controller: controller),
);

class _WorkspacePicker extends StatefulWidget {
  const _WorkspacePicker({required this.controller});
  final AppController controller;
  @override
  State<_WorkspacePicker> createState() => _WorkspacePickerState();
}

class _WorkspacePickerState extends State<_WorkspacePicker> {
  bool _loading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.controller.loadProjects();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _directory() async {
    final path = await showHostDirectoryPicker(context, widget.controller);
    if (mounted && path != null) {
      Navigator.pop(context, WorkspaceTarget(path: path));
    }
  }

  Future<void> _project() async {
    final target = await showDialog<WorkspaceTarget>(
      context: context,
      builder: (_) => _CreateProjectDialog(controller: widget.controller),
    );
    if (mounted && target != null) Navigator.pop(context, target);
  }

  @override
  Widget build(BuildContext context) => _PickerFrame(
    title: '选择新会话工作区',
    actions: [
      IconButton(
        tooltip: '刷新 Codex 项目',
        onPressed: _loading ? null : _reload,
        icon: const Icon(Icons.refresh),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                onPressed: _directory,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择主机目录'),
              ),
              OutlinedButton.icon(
                onPressed: _project,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建 Codex 项目'),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Text(
            'Codex 项目',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: widget.controller.projects.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _loading
                          ? '正在读取 Codex 项目…'
                          : '暂无 Codex 项目\n可以选择主机目录，或新建项目。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: widget.controller.projects.length,
                  itemBuilder: (context, index) {
                    final project = widget.controller.projects[index];
                    final roots = asMaps(project['roots']);
                    void select(String path) => Navigator.pop(
                      context,
                      WorkspaceTarget(
                        projectId: project['id'] as String,
                        path: path,
                      ),
                    );
                    if (roots.length > 1) {
                      return ExpansionTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(project['name'] as String),
                        subtitle: Text('${roots.length} 个工作目录'),
                        children: [
                          for (final root in roots)
                            ListTile(
                              title: Text(root['path'] as String),
                              onTap: () => select(root['path'] as String),
                            ),
                        ],
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(project['name'] as String),
                      subtitle: Text(
                        roots.isEmpty
                            ? '项目没有工作目录'
                            : roots.first['path'] as String,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: !_loading && roots.isNotEmpty,
                      onTap: () => select(roots.first['path'] as String),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

Future<String?> showHostDirectoryPicker(
  BuildContext context,
  AppController controller, {
  String? initialPath,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _DirectoryPicker(controller: controller, initialPath: initialPath),
);

class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker({required this.controller, this.initialPath});
  final AppController controller;
  final String? initialPath;
  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  final _address = TextEditingController();
  final _search = TextEditingController();
  Timer? _debounce;
  JsonMap _listing = {};
  List<JsonMap> _entries = [];
  bool _loading = true, _hidden = false;
  String? _error;
  int _generation = 0;
  String? get _path => _listing['path'] as String?;
  @override
  void initState() {
    super.initState();
    unawaited(_load(widget.initialPath));
  }

  Future<void> _load(
    String? path, {
    bool more = false,
    bool navigation = true,
  }) async {
    final generation = ++_generation;
    if (navigation) {
      _debounce?.cancel();
      _search.clear();
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.directories(
        path: path,
        hidden: _hidden,
        search: _search.text,
        offset: more ? (_listing['nextOffset'] as num?)?.toInt() ?? 0 : 0,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _listing = result;
        _entries = more
            ? [..._entries, ...asMaps(result['entries'])]
            : asMaps(result['entries']);
        _address.text = _path!;
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _newFolder() async {
    final name = await _askName(context, '新建文件夹', '文件夹名称');
    if (!mounted || name == null || _path == null) return;
    setState(() => _loading = true);
    try {
      final path = await widget.controller.createDirectory(_path!, name);
      if (mounted) await _load(path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _PickerFrame(
    title: '选择主机目录',
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _address,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '主机目录路径',
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '转到目录',
                onPressed: _loading ? null : () => _load(_address.text.trim()),
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
            onSubmitted: (value) => _load(value.trim()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: '主目录',
                onPressed: _loading ? null : () => _load(null),
                icon: const Icon(Icons.home_outlined),
              ),
              IconButton(
                tooltip: '上一级目录',
                onPressed: _loading || _listing['parentPath'] == null
                    ? null
                    : () => _load(_listing['parentPath'] as String),
                icon: const Icon(Icons.drive_folder_upload_outlined),
              ),
              IconButton(
                tooltip: '新建文件夹',
                onPressed: _loading || _path == null ? null : _newFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
              IconButton(
                tooltip: _hidden ? '隐藏隐藏目录' : '显示隐藏目录',
                isSelected: _hidden,
                onPressed: _loading
                    ? null
                    : () {
                        _hidden = !_hidden;
                        _load(_path, navigation: false);
                      },
                icon: const Icon(Icons.visibility_outlined),
              ),
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '筛选文件夹',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 300),
                      () => _load(_path, navigation: false),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _entries.isEmpty
              ? Center(child: Text(_loading ? '正在读取目录…' : '没有子目录'))
              : ListView.builder(
                  itemCount:
                      _entries.length +
                      (_listing['nextOffset'] == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (index == _entries.length) {
                      return TextButton(
                        onPressed: _loading
                            ? null
                            : () => _load(_path, more: true, navigation: false),
                        child: const Text('加载更多目录'),
                      );
                    }
                    final dir = _entries[index];
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(dir['name'] as String),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _loading
                          ? null
                          : () => _load(dir['path'] as String),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loading || _path == null || _error != null
                  ? null
                  : () => Navigator.pop(context, _path),
              icon: const Icon(Icons.check),
              label: const Text('确认使用此目录'),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _debounce?.cancel();
    _address.dispose();
    _search.dispose();
    super.dispose();
  }
}

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog({required this.controller});
  final AppController controller;
  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  final _name = TextEditingController();
  final _requestId = newRequestId();
  String? _path, _error;
  bool _saving = false;
  Future<void> _choose() async {
    final path = await showHostDirectoryPicker(
      context,
      widget.controller,
      initialPath: _path,
    );
    if (mounted && path != null) {
      setState(() {
        _path = path;
        if (_name.text.trim().isEmpty) {
          _name.text =
              path
                  .split(RegExp(r'[/\\]'))
                  .where((s) => s.isNotEmpty)
                  .lastOrNull ??
              '新项目';
        }
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final project = await widget.controller.createProject(
        _name.text.trim(),
        _path!,
        _requestId,
      );
      if (mounted) {
        Navigator.pop(
          context,
          WorkspaceTarget(projectId: project['id'] as String, path: _path!),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建 Codex 项目'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              maxLength: 120,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '项目名称'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _saving ? null : _choose,
              icon: const Icon(Icons.folder_open),
              label: Text(_path ?? '选择项目目录'),
            ),
            const SizedBox(height: 12),
            const Text(
              '项目将保存到本机 Codex，可在 Codex 的项目列表中使用。',
              style: TextStyle(fontSize: 12),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving || _path == null || _name.text.trim().isEmpty
            ? null
            : _save,
        child: Text(_saving ? '正在创建…' : '创建并开始会话'),
      ),
    ],
  );
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }
}

class _PickerFrame extends StatelessWidget {
  const _PickerFrame({
    required this.title,
    required this.child,
    this.actions = const [],
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 640,
        height: math.min(
          640,
          math.max(240, media.size.height - media.viewInsets.bottom - 48),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ...actions,
                  IconButton(
                    tooltip: '关闭选择器',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

Future<String?> _askName(BuildContext context, String title, String label) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, label: label),
    );

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.label});
  final String title, label;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _text = TextEditingController();
  void _submit() {
    if (_text.text.trim().isNotEmpty) Navigator.pop(context, _text.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _text,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('创建')),
    ],
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
