import 'dart:convert';
import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/app_controller.dart';
import 'package:codex_link/ui/workspace_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  http.Response response(Object data, [int status = 200]) => http.Response(jsonEncode(data), status, headers: {'content-type':'application/json; charset=utf-8'});
  Widget harness(AppController app, void Function(WorkspaceTarget?) selected) => MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
    TextButton(onPressed: () async => selected(await showWorkspacePicker(context, app)), child: const Text('选择工作区')))));

  testWidgets('Codex project selection uses native identity and root', (t) async {
    final app = AppController(api: ApiClient(client: MockClient((r) async => response([
      {'id':'native-id','name':'真实项目','roots':[{'path':'/host/code'}]},
    ]))))..authenticated = true;
    addTearDown(app.dispose);
    WorkspaceTarget? selected;
    await t.pumpWidget(harness(app, (value) => selected = value));
    await t.tap(find.text('选择工作区')); await t.pumpAndSettle();
    expect(find.text('真实项目'), findsOneWidget);
    await t.tap(find.text('真实项目')); await t.pumpAndSettle();
    expect(selected?.projectId, 'native-id'); expect(selected?.path, '/host/code');
  });

  testWidgets('host directory picker navigates parents and confirms cwd', (t) async {
    final paths = <String?>[];
    final app = AppController(api: ApiClient(client: MockClient((r) async {
      if (r.url.path == '/api/projects') return response([]);
      final path = r.url.queryParameters['path'] ?? '/host'; paths.add(path);
      if (path == '/missing') return response({'detail':'目录不存在'}, 404);
      return response({'path':path, 'homePath':'/host', 'parentPath': path == '/host' ? '/' : '/host',
        'entries': path == '/host' ? [{'name':'code','path':'/host/code'}] : []});
    })))..authenticated = true;
    addTearDown(app.dispose);
    WorkspaceTarget? selected;
    await t.pumpWidget(harness(app, (value) => selected = value));
    await t.tap(find.text('选择工作区')); await t.pumpAndSettle();
    await t.tap(find.text('选择主机目录')); await t.pumpAndSettle();
    await t.tap(find.text('code')); await t.pumpAndSettle();
    expect(find.text('/host/code'), findsOneWidget);
    await t.tap(find.byTooltip('上一级目录')); await t.pumpAndSettle();
    expect(paths.last, '/host');
    await t.enterText(find.widgetWithText(TextField, '主机目录路径'), '/missing');
    await t.tap(find.byTooltip('转到目录')); await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '确认使用此目录')).onPressed, isNull);
    await t.tap(find.byTooltip('主目录')); await t.pumpAndSettle();
    await t.tap(find.text('code')); await t.pumpAndSettle();
    await t.tap(find.text('确认使用此目录')); await t.pumpAndSettle();
    expect(selected?.projectId, isNull); expect(selected?.path, '/host/code');
    expect(t.takeException(), isNull);
  });

  testWidgets('creating project saves to Codex before starting its thread', (t) async {
    JsonMap? submitted;
    final app = AppController(api: ApiClient(client: MockClient((r) async {
      if (r.url.path == '/api/projects' && r.method == 'GET') return response([]);
      if (r.url.path == '/api/projects') {
        submitted = asMap(jsonDecode(r.body));
        return response({'project':{'id':'created-in-codex','name':submitted!['name'],'roots':[{'path':submitted!['path']}]}});
      }
      return response({'path':'/host/new','parentPath':'/host','entries':[]});
    })))..authenticated = true;
    addTearDown(app.dispose);
    WorkspaceTarget? selected;
    await t.pumpWidget(harness(app, (value) => selected = value));
    await t.tap(find.text('选择工作区')); await t.pumpAndSettle();
    await t.tap(find.text('新建 Codex 项目')); await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '项目名称'), '同步项目');
    await t.tap(find.text('选择项目目录')); await t.pumpAndSettle();
    await t.tap(find.text('确认使用此目录')); await t.pumpAndSettle();
    await t.tap(find.text('创建并开始会话')); await t.pumpAndSettle();
    expect(submitted?['name'], '同步项目'); expect(submitted?['path'], '/host/new');
    expect(submitted?['requestId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(selected?.projectId, 'created-in-codex'); expect(app.projects.single['id'], 'created-in-codex');
  });
}
