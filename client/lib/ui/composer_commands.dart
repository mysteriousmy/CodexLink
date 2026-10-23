import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/conversation_controller.dart';

const composerCommands = <(String, String, IconData)>[
  ('/skills', '选择此工作区可用的技能', Icons.auto_awesome_outlined),
  ('@', '搜索并引用工作区文件', Icons.alternate_email),
  ('/mcp', '查看 MCP 连接、工具和资源', Icons.extension_outlined),
  ('/goal', '切换目标模式，发送输入内容后执行', Icons.flag_outlined),
];

class CommandPalette extends StatelessWidget {
  const CommandPalette({
    super.key,
    required this.query,
    required this.onSelected,
  });
  final String query;
  final void Function(String) onSelected;
  @override
  Widget build(BuildContext context) {
    final matches = composerCommands.where(
      (c) =>
          query.isEmpty ||
          c.$1.startsWith(query) ||
          query.startsWith('@') && c.$1 == '@',
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            (MediaQuery.viewInsetsOf(context).bottom > 0 ||
                View.of(context).viewInsets.bottom > 0)
            ? 96
            : 190,
      ),
      child: Material(
        color: Colors.transparent,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final command in matches)
              ListTile(
                dense: true,
                leading: Icon(command.$3, size: 19),
                title: Text(command.$1),
                subtitle: Text(command.$2),
                onTap: () => onSelected(command.$1),
              ),
            if (matches.isEmpty)
              const ListTile(
                dense: true,
                title: Text('没有匹配的指令'),
                subtitle: Text('可用：/skills、@文件、/mcp、/goal'),
              ),
          ],
        ),
      ),
    );
  }
}

Future<JsonMap?> selectComposerReference(
  BuildContext context,
  ConversationController controller, {
  required bool skill,
  String query = '',
}) => showDialog<JsonMap>(
  context: context,
  builder: (_) =>
      _ReferencePicker(controller: controller, skill: skill, query: query),
);

class _ReferencePicker extends StatefulWidget {
  const _ReferencePicker({
    required this.controller,
    required this.skill,
    required this.query,
  });
  final ConversationController controller;
  final bool skill;
  final String query;
  @override
  State<_ReferencePicker> createState() => _ReferencePickerState();
}

class _ReferencePickerState extends State<_ReferencePicker> {
  late final _search = TextEditingController(text: widget.query);
  List<JsonMap> _entries = [];
  bool _loading = true;
  String? _error;
  Timer? _debounce;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = widget.skill
          ? await widget.controller.skills(refresh: refresh)
          : await widget.controller.searchFiles(_search.text);
      if (mounted && request == _request) setState(() => _entries = entries);
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = e.toString());
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.skill
        ? _entries
              .where(
                (e) => '${e['name']} ${e['description']}'
                    .toLowerCase()
                    .contains(_search.text.toLowerCase()),
              )
              .toList()
        : _entries;
    return AlertDialog(
      title: Text(widget.skill ? '选择技能' : '引用工作区文件'),
      content: SizedBox(
        width: 620,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: widget.skill ? '搜索名称或描述' : '文件名或路径',
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (_) {
                setState(() {});
                if (!widget.skill) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 250), _load);
                }
              },
            ),
            const SizedBox(height: 10),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: entries.isEmpty && !_loading
                  ? const Center(child: Text('没有匹配的结果'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final name =
                            (widget.skill ? entry['name'] : entry['file_name'])
                                as String? ??
                            '';
                        final enabled =
                            !widget.skill || entry['enabled'] == true;
                        return ListTile(
                          enabled: enabled,
                          leading: Icon(
                            widget.skill
                                ? Icons.auto_awesome_outlined
                                : Icons.description_outlined,
                          ),
                          title: Text(name),
                          subtitle: Text(
                            widget.skill
                                ? '${enabled ? '' : '已禁用 · '}${entry['description'] ?? ''}'
                                : entry['path'] as String? ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            var path = entry['path'] as String;
                            if (!widget.skill &&
                                !path.startsWith('/') &&
                                !RegExp(r'^[A-Za-z]:').hasMatch(path)) {
                              path = '${entry['root']}/$path';
                            }
                            Navigator.pop(context, <String, dynamic>{
                              'type': widget.skill ? 'skill' : 'file',
                              'name': name,
                              'path': path,
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _load(refresh: true),
          child: const Text('刷新'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }
}

Future<void> showMcpCatalog(
  BuildContext context,
  ConversationController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _McpCatalog(controller: controller),
);

class _McpCatalog extends StatefulWidget {
  const _McpCatalog({required this.controller});
  final ConversationController controller;
  @override
  State<_McpCatalog> createState() => _McpCatalogState();
}

class _McpCatalogState extends State<_McpCatalog> {
  final List<JsonMap> _servers = [];
  String? _cursor, _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.mcp(cursor: more ? _cursor : null);
      if (!mounted) return;
      setState(() {
        if (!more) _servers.clear();
        _servers.addAll(asMaps(result['data']));
        _cursor = result['nextCursor'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('MCP 工具与资源'),
    content: SizedBox(
      width: 680,
      height: 460,
      child: Column(
        children: [
          const Text(
            '来自当前会话的实际 MCP 配置。工具由 Codex 按任务调用，权限和审批沿用当前会话。',
            style: TextStyle(fontSize: 12),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null) Text(_error!),
          Expanded(
            child: ListView(
              children: [
                if (!_loading && _servers.isEmpty && _error == null)
                  const ListTile(title: Text('没有可用的 MCP 服务')),
                for (final server in _servers)
                  ExpansionTile(
                    title: Text(server['name'] as String? ?? 'MCP'),
                    subtitle: Text(
                      '${server['runtimeStatus'] ?? '状态未知'} · ${server['authStatus'] ?? '认证未知'} · ${asMap(server['tools']).length} 个工具',
                    ),
                    children: [
                      if (server['toolsError'] != null)
                        ListTile(title: Text(server['toolsError'].toString())),
                      for (final tool in asMap(server['tools']).entries)
                        ExpansionTile(
                          dense: true,
                          title: Text(tool.key),
                          subtitle: Text(
                            asMap(tool.value)['description'] as String? ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                asMap(tool.value)['description'] as String? ??
                                    '无说明',
                              ),
                            ),
                          ],
                        ),
                      for (final resource in [
                        ...asMaps(server['resources']),
                        ...asMaps(server['resourceTemplates']),
                      ])
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(resource['name'] as String? ?? '资源'),
                          subtitle: Text(
                            (resource['uri'] ?? resource['uriTemplate'] ?? '')
                                .toString(),
                          ),
                        ),
                    ],
                  ),
                if (_cursor != null)
                  TextButton(
                    onPressed: _loading ? null : () => _load(more: true),
                    child: const Text('加载更多服务'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: _loading ? null : _load, child: const Text('刷新')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
