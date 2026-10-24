import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../platform/transport.dart' as transport;
import 'api_client.dart';
import 'conversation_controller.dart';
import 'task_notification_controller.dart';

enum ConnectionState {
  offline,
  connecting,
  syncing,
  connected,
  loginRequired,
  codexUnavailable,
}

class AppController extends ChangeNotifier {
  AppController({ApiClient? api, TaskNotificationController? notifications})
    : api = api ?? ApiClient(),
      notifications = notifications ?? TaskNotificationController() {
    conversation = ConversationController(
      this.api,
      onError: reportError,
      onTurnFinished: () {
        unawaited(refreshUsage());
        unawaited(loadThreads());
      },
    );
  }
  final ApiClient api;
  final TaskNotificationController notifications;
  late final ConversationController conversation;
  ConnectionState connection = ConnectionState.offline;
  bool authenticated = false;
  bool busy = false;
  bool dark = false;
  bool initialized = false;
  String address = kIsWeb ? Uri.base.origin : 'http://127.0.0.1:47821';
  List<JsonMap> projects = [];
  int _projectsGeneration = 0;
  List<JsonMap> threads = [];
  List<JsonMap> models = [];
  JsonMap status = {};
  JsonMap accountUsage = {};
  String? projectId;
  String? threadCursor;
  bool archivedThreads = false;
  String threadSearch = '';
  bool loadingThreads = false;
  String? threadListError;
  int _threadListGeneration = 0;
  int _threadEventRevision = 0;
  final Map<String, Map<String, (int, dynamic)>> _threadChanges = {};
  final Map<String, String> _threadActions = {};
  bool get threadActionsSupported => status['threadActions'] == true;
  bool threadActionBusy(String id) => _threadActions.containsKey(id);
  final ValueNotifier<String?> error = ValueNotifier(null);
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  Timer? _heartbeat;
  DateTime _lastMessage = DateTime.now();
  int _retryCount = 0;
  int _connectionGeneration = 0;
  String? _epoch;
  int _sequence = 0;
  bool _syncing = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _usageLoading = false;
  int _accountGeneration = 0;
  final List<JsonMap> _buffer = [];
  int get maxFileBytes =>
      (status['maxFileBytes'] as num?)?.toInt() ?? 25 * 1024 * 1024;
  String get connectionLabel => switch (connection) {
    ConnectionState.offline => '连接已断开',
    ConnectionState.connecting => '正在连接',
    ConnectionState.syncing => '恢复会话中',
    ConnectionState.connected => '已连接',
    ConnectionState.loginRequired => '需要登录',
    ConnectionState.codexUnavailable => 'Codex 不可用',
  };
  bool get usable => authenticated && connection == ConnectionState.connected;

  Future<void> initialize() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      dark = preferences.getBool('dark') ?? false;
      if (!kIsWeb) address = preferences.getString('server_address') ?? address;
      final token = await transport.loadToken();
      api.configure(address, token);
      if (kIsWeb || token != null) await _loadSession();
    } catch (exception) {
      if (exception is ApiError && exception.status == 401) {
        connection = ConnectionState.loginRequired;
      } else {
        reportError(exception);
      }
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> login(String server, String token) async {
    await notifications.clear();
    _stopConnection();
    _accountGeneration++;
    _threadListGeneration++;
    _threadChanges.clear();
    _threadActions.clear();
    archivedThreads = false;
    threadCursor = null;
    threadSearch = '';
    _epoch = null;
    _sequence = 0;
    _buffer.clear();
    _syncing = false;
    conversation.reset();
    projects = [];
    threads = [];
    models = [];
    accountUsage = {};
    projectId = null;
    busy = true;
    connection = ConnectionState.connecting;
    notifyListeners();
    try {
      api.configure(server, token);
      await api.login(token);
      address = api.base.origin;
      final preferences = await SharedPreferences.getInstance();
      if (!kIsWeb) await preferences.setString('server_address', address);
      await _loadSession();
    } catch (exception) {
      reportError(exception);
      connection = ConnectionState.offline;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _loadSession() async {
    status = asMap(await api.request('GET', '/api/status'));
    conversation.queueSupported = status['queuedMessages'] == true;
    authenticated = true;
    await _configureNotifications();
    if (status['codex'] == 'ready') {
      await loadProjects().catchError(reportError);
      models = asMaps(asMap(await api.request('GET', '/api/models'))['data']);
      await loadThreads();
    }
    unawaited(refreshUsage());
    await connectEvents();
  }

  Future<void> _configureNotifications() => notifications.configure(
    api.base,
    api.token,
    status['taskNotifications'] == true,
  );

  Future<void> loadThreads({bool more = false}) async {
    if (!authenticated || (more && (loadingThreads || threadCursor == null))) {
      return;
    }
    final generation = ++_threadListGeneration;
    final selectedProject = projectId;
    final eventRevision = _threadEventRevision;
    loadingThreads = true;
    threadListError = null;
    notifyListeners();
    try {
      final result = asMap(
        await api.request(
          'GET',
          '/api/threads',
          query: {
            'projectId': ?selectedProject,
            if (more && threadCursor != null) 'cursor': threadCursor!,
            if (threadSearch.isNotEmpty) 'search': threadSearch,
            'archived': '$archivedThreads',
          },
        ),
      );
      if (generation != _threadListGeneration || !authenticated || _disposed) {
        return;
      }
      final data = asMaps(result['data']);
      for (final row in data) {
        final change = _threadChanges[row['id']];
        if (change != null) {
          for (final field in change.entries) {
            if (field.value.$1 > eventRevision) row[field.key] = field.value.$2;
          }
        }
      }
      data.removeWhere(
        (row) => row['archived'] != null && row['archived'] != archivedThreads,
      );
      if (more) {
        threads.addAll(
          data.where(
            (t) => !threads.any((existing) => existing['id'] == t['id']),
          ),
        );
      } else {
        threads = data;
      }
      threadCursor = result['nextCursor'] as String?;
    } catch (exception) {
      if (generation == _threadListGeneration) {
        threadListError = '$exception';
        reportError(exception);
      }
    } finally {
      if (generation == _threadListGeneration && !_disposed) {
        loadingThreads = false;
        notifyListeners();
      }
    }
  }

  Future<void> changeThreadLifecycle(String id, String action) async {
    if (!usable ||
        !threadActionsSupported ||
        !const {'archive', 'unarchive', 'close'}.contains(action)) {
      throw const ApiError('当前连接不支持会话操作，请更新服务端并等待连接恢复。');
    }
    if (threadActionBusy(id)) return;
    if (conversation.threadId == id &&
        (conversation.sending ||
            conversation.uncertain ||
            conversation.permissionsBusy ||
            conversation.queueActionBusy)) {
      throw const ApiError('请先等待此会话的提交完成并核对结果，再操作会话。');
    }
    final generation = _accountGeneration;
    final requestId = newRequestId();
    final eventRevision = _threadEventRevision;
    _threadActions[id] = requestId;
    notifyListeners();
    try {
      final response = asMap(
        await api.request(
          'POST',
          '/api/threads/$id/$action',
          body: {'requestId': requestId},
        ),
      );
      if (_disposed || generation != _accountGeneration || !authenticated) {
        return;
      }
      if ((_threadChanges[id]?['closedByClient']?.$1 ?? 0) > eventRevision) {
        return;
      }
      _applyThreadLifecycle(
        id,
        action == 'unarchive'
            ? 'unarchived'
            : response['state'] as String? ?? action,
      );
    } catch (error) {
      if (_disposed || generation != _accountGeneration || !authenticated) {
        return;
      }
      // Reconcile an ambiguous response without replaying a lifecycle mutation.
      if (action != 'unarchive' &&
          (error is! ApiError ||
              error.status == null ||
              error.status! >= 500)) {
        try {
          final receipt = asMap(
            await api.request('GET', '/api/operations/$requestId'),
          );
          if (_disposed || generation != _accountGeneration || !authenticated) {
            return;
          }
          if (receipt['state'] == 'accepted') {
            if ((_threadChanges[id]?['closedByClient']?.$1 ?? 0) >
                eventRevision) {
              return;
            }
            _applyThreadLifecycle(
              id,
              asMap(receipt['result'])['state'] as String,
            );
            return;
          }
        } catch (_) {
          /* Preserve the original failure and keep the row. */
        }
      }
      rethrow;
    } finally {
      if (!_disposed &&
          generation == _accountGeneration &&
          _threadActions[id] == requestId) {
        _threadActions.remove(id);
        notifyListeners();
      }
    }
  }

  void _patchThread(String id, JsonMap fields) {
    final changes = _threadChanges.putIfAbsent(id, () => {});
    final revision = ++_threadEventRevision;
    for (final field in fields.entries) {
      changes[field.key] = (revision, field.value);
    }
    if (_threadChanges.length > 1024) {
      _threadChanges.remove(_threadChanges.keys.first);
    }
    for (final row in threads.where((row) => row['id'] == id)) {
      row.addAll(fields);
    }
  }

  void _applyThreadLifecycle(String id, String state) {
    if (state == 'archived' || state == 'unarchived') {
      final archived = state == 'archived';
      _patchThread(id, {
        'archived': archived,
        'status': {'type': 'notLoaded'},
        'closePending': false,
        'closedByClient': archived,
      });
      if (archived != archivedThreads) {
        threads.removeWhere((t) => t['id'] == id);
      }
      conversation.detach(id, archived: archived);
    } else if (state == 'closing' || state == 'closed') {
      _patchThread(id, {
        'closePending': state == 'closing',
        'closedByClient': true,
        if (state == 'closed') 'status': {'type': 'notLoaded'},
      });
      conversation.detach(id);
    }
    notifyListeners();
  }

  Future<void> selectProject(String? value) async {
    projectId = value;
    threads = [];
    threadCursor = null;
    await loadThreads();
  }

  Future<void> loadProjects() async {
    final generation = ++_projectsGeneration;
    final result = asMaps(await api.request('GET', '/api/projects'));
    if (_disposed || !authenticated || generation != _projectsGeneration) {
      return;
    }
    projects = result;
    if (projectId != null && !projects.any((p) => p['id'] == projectId)) {
      projectId = null;
      unawaited(loadThreads());
    }
    notifyListeners();
  }

  Future<JsonMap> createProject(
    String name,
    String path,
    String requestId,
  ) async {
    final result = asMap(
      await api.request(
        'POST',
        '/api/projects',
        body: {'name': name, 'path': path, 'requestId': requestId},
      ),
    );
    final project = asMap(result['project']);
    projects = [...projects.where((p) => p['id'] != project['id']), project];
    notifyListeners();
    return project;
  }

  Future<JsonMap> directories({
    String? path,
    bool hidden = false,
    String search = '',
    int offset = 0,
  }) async => asMap(
    await api.request(
      'GET',
      '/api/directories',
      query: {
        'path': ?path,
        'hidden': '$hidden',
        'search': search,
        'offset': '$offset',
      },
    ),
  );

  Future<String> createDirectory(String parentPath, String name) async =>
      asMap(
            await api.request(
              'POST',
              '/api/directories',
              body: {'parentPath': parentPath, 'name': name},
            ),
          )['path']
          as String;

  Future<void> searchThreads(String value) async {
    threadSearch = value.trim();
    threadCursor = null;
    await loadThreads();
  }

  Future<void> showArchivedThreads(bool value) async {
    archivedThreads = value;
    threads = [];
    threadCursor = null;
    await loadThreads();
  }

  Future<void> selectThread(String id) async {
    _syncing = true;
    _buffer.clear();
    try {
      await conversation.select(id, archived: archivedThreads);
      for (final event in _buffer) {
        _dispatch(event);
      }
      _buffer.clear();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> createThread({String? project, String? path}) async {
    if (project == null && path == null) {
      throw const ApiError('请选择 Codex 项目或主机目录。');
    }
    busy = true;
    notifyListeners();
    try {
      final response = asMap(
        await api.request(
          'POST',
          '/api/threads',
          body: {'projectId': ?project, 'path': ?path},
        ),
      );
      archivedThreads = false;
      projectId = project;
      threadSearch = '';
      await selectThread(asMap(response['thread'])['id'] as String);
      await loadThreads();
      final created = asMap(response['thread']);
      if (!threads.any((t) => t['id'] == created['id'])) {
        threads.insert(0, created);
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> connectEvents() async {
    if (_disposed || !authenticated || !_foreground) return;
    _stopConnection();
    final generation = _connectionGeneration;
    connection = ConnectionState.connecting;
    notifyListeners();
    final socket = api.events(_epoch, _sequence);
    _socket = socket;
    _subscription = socket.stream.listen(
      (raw) {
        if (!_currentConnection(generation)) return;
        _lastMessage = DateTime.now();
        try {
          _event(asMap(jsonDecode(raw as String)));
        } catch (exception) {
          reportError(exception);
        }
      },
      onError: (Object exception) {
        if (_currentConnection(generation)) _disconnected();
      },
      onDone: () {
        if (_currentConnection(generation)) _disconnected();
      },
    );
    try {
      await socket.ready.timeout(const Duration(seconds: 15));
      if (!_currentConnection(generation)) return;
      _retryCount = 0;
      _lastMessage = DateTime.now();
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!_currentConnection(generation)) return;
        if (DateTime.now().difference(_lastMessage) >
            const Duration(seconds: 45)) {
          _disconnected();
          return;
        }
        socket.sink.add('{"type":"ping"}');
      });
    } catch (exception) {
      if (_currentConnection(generation)) _disconnected();
    }
  }

  void _event(JsonMap event) {
    final method = event['method'] as String? ?? '';
    if (method == 'stream/pong') return;
    if (method == 'stream/resync') {
      _epoch = event['epoch'] as String?;
      _sequence = (event['seq'] as num?)?.toInt() ?? 0;
      _syncing = true;
      _buffer.clear();
      connection = ConnectionState.syncing;
      notifyListeners();
      return;
    }
    if (method == 'stream/replay') {
      _epoch = event['epoch'] as String?;
      return;
    }
    if (method == 'stream/ready') {
      _epoch = event['epoch'] as String?;
      _sequence = max(_sequence, (event['seq'] as num?)?.toInt() ?? 0);
      if (_syncing) {
        unawaited(_resync());
      } else {
        connection = status['codex'] == 'ready'
            ? ConnectionState.connected
            : ConnectionState.codexUnavailable;
        notifyListeners();
      }
      return;
    }
    final sequence = (event['seq'] as num?)?.toInt();
    if (sequence != null) {
      if (sequence <= _sequence) return;
      _sequence = sequence;
    }
    if (_syncing) {
      if (_buffer.length >= 2048) {
        _buffer.clear();
        unawaited(connectEvents());
        return;
      }
      _buffer.add(event);
    } else {
      _dispatch(event);
    }
  }

  Future<void> _resync() async {
    final generation = _connectionGeneration;
    try {
      final currentStatus = asMap(await api.request('GET', '/api/status'));
      if (!_currentConnection(generation)) return;
      status = currentStatus;
      conversation.queueSupported = status['queuedMessages'] == true;
      unawaited(_configureNotifications());
      await conversation.reload();
      await loadThreads();
      if (!_currentConnection(generation)) return;
      for (final event in _buffer) {
        _dispatch(event);
      }
      _buffer.clear();
      _syncing = false;
      connection = status['codex'] == 'ready'
          ? ConnectionState.connected
          : ConnectionState.codexUnavailable;
      notifyListeners();
    } catch (exception) {
      if (!_currentConnection(generation)) return;
      _reportConnectionError(exception);
      _disconnected();
    }
  }

  void _dispatch(JsonMap event) {
    final method = event['method'] as String? ?? '';
    final parameters = asMap(event['params']);
    if (method == 'runtime/stopped') {
      connection = ConnectionState.codexUnavailable;
      conversation.runtimeStopped();
      notifyListeners();
    } else if (method == 'runtime/ready') {
      status['codex'] = 'ready';
      connection = ConnectionState.connected;
      unawaited(conversation.reload().catchError(reportError));
      unawaited(_refreshRuntimeLists().catchError(reportError));
      notifyListeners();
    } else if (method == 'project/changed') {
      unawaited(loadProjects().catchError(reportError));
    } else if (method == 'account/rateLimits/updated') {
      accountUsage = {
        ...accountUsage,
        'rateLimits': parameters,
        'limitsUpdatedAt': DateTime.now().toUtc().toIso8601String(),
        'limitsError': null,
      };
      notifyListeners();
    } else if (method == 'account/updated') {
      _accountGeneration++;
      _threadActions.clear();
      _threadChanges.clear();
      accountUsage = {};
      unawaited(refreshUsage());
    }
    final id = parameters['threadId'] as String?;
    if (id != null) {
      if (method == 'thread/lifecycle/changed') {
        _applyThreadLifecycle(id, parameters['state'] as String? ?? '');
      } else if (method == 'thread/closed' ||
          method == 'thread/archived' ||
          method == 'thread/unarchived') {
        _applyThreadLifecycle(id, method.substring('thread/'.length));
      } else if (method == 'thread/status/changed' ||
          method == 'thread/name/updated' ||
          method == 'turn/started' ||
          method == 'turn/completed') {
        final fields = <String, dynamic>{};
        if (method == 'thread/status/changed') {
          fields['status'] = parameters['status'];
          if (asMap(parameters['status'])['type'] == 'notLoaded') {
            fields['closePending'] = false;
          }
        }
        if (method == 'thread/name/updated') {
          fields['name'] = parameters['threadName'] ?? parameters['name'];
        }
        if (method == 'turn/started') fields['status'] = {'type': 'active'};
        if (method == 'turn/completed') fields['status'] = {'type': 'idle'};
        _patchThread(id, fields);
        notifyListeners();
      }
    }
    conversation.handleEvent(method, parameters);
  }

  Future<void> _refreshRuntimeLists() async {
    await loadProjects().catchError(reportError);
    final value = asMap(await api.request('GET', '/api/models'));
    if (!authenticated || _disposed) return;
    models = asMaps(value['data']);
    await loadThreads();
    await refreshUsage();
  }

  void _disconnected() {
    if (_disposed ||
        !authenticated ||
        connection == ConnectionState.loginRequired) {
      return;
    }
    _stopConnection();
    connection = ConnectionState.offline;
    notifyListeners();
    if (!_foreground) return;
    final generation = _connectionGeneration;
    final seconds = min(30, 1 << min(_retryCount++, 5));
    _retry = Timer(
      Duration(milliseconds: seconds * 1000 + Random().nextInt(500)),
      () async {
        if (!_currentConnection(generation)) return;
        try {
          final currentStatus = asMap(await api.request('GET', '/api/status'));
          if (!_currentConnection(generation)) return;
          status = currentStatus;
          conversation.queueSupported = status['queuedMessages'] == true;
          unawaited(_configureNotifications());
          await connectEvents();
        } catch (exception) {
          if (!_currentConnection(generation)) return;
          _reportConnectionError(exception);
          _disconnected();
        }
      },
    );
  }

  Future<void> foreground() async {
    _foreground = true;
    notifications.foreground(true);
    if (!authenticated) return;
    // A sleeping app may miss events or outlive the replay buffer. Reconcile
    // the selected task with a fresh snapshot before allowing interaction.
    _epoch = null;
    _sequence = 0;
    await connectEvents();
    unawaited(refreshUsage());
  }

  void background() {
    if (!_foreground || _disposed) return;
    _foreground = false;
    notifications.foreground(false);
    _stopConnection();
    if (authenticated) connection = ConnectionState.offline;
    notifyListeners();
  }

  bool _currentConnection(int generation) =>
      !_disposed &&
      authenticated &&
      _foreground &&
      generation == _connectionGeneration;

  void _stopConnection() {
    // Cancelling a timer does not cancel HTTP work already started by it.
    // Invalidate that work before closing the old socket or scheduling retry.
    _connectionGeneration++;
    _retry?.cancel();
    _retry = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.sink.close());
    _socket = null;
    if (_syncing) {
      _epoch = null;
      _sequence = 0;
    }
    _syncing = false;
    _buffer.clear();
  }

  void _reportConnectionError(Object exception) {
    if (exception is TimeoutException ||
        exception is http.ClientException ||
        exception is WebSocketChannelException) {
      // Offline/reconnecting state already describes a temporary transport
      // failure. Keep automatic retries from producing repeated snackbars.
      debugPrint('CodexLink connection interrupted: $exception');
      return;
    }
    reportError(exception);
  }

  Future<void> refreshUsage({bool force = false}) async {
    if (!authenticated || _usageLoading) return;
    _usageLoading = true;
    final accountGeneration = _accountGeneration;
    try {
      final origin = api.base.origin;
      final result = asMap(
        await api.request(
          'GET',
          '/api/account/usage',
          query: {'refresh': '$force'},
        ),
      );
      if (!authenticated ||
          origin != api.base.origin ||
          _disposed ||
          accountGeneration != _accountGeneration) {
        return;
      }
      accountUsage = result;
      notifyListeners();
    } catch (exception) {
      if (!authenticated ||
          _disposed ||
          accountGeneration != _accountGeneration) {
        return;
      }
      accountUsage = {...accountUsage, 'error': exception.toString()};
      notifyListeners();
    } finally {
      _usageLoading = false;
      if (!_disposed &&
          authenticated &&
          accountGeneration != _accountGeneration) {
        unawaited(refreshUsage(force: true));
      }
    }
  }

  Future<void> toggleTheme() async {
    dark = !dark;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('dark', dark);
  }

  Future<void> logout() async {
    _threadActions.clear();
    _threadChanges.clear();
    await notifications.clear();
    if (kIsWeb) await api.request('DELETE', '/api/auth/session');
    await transport.saveToken(null);
    authenticated = false;
    _threadListGeneration++;
    _accountGeneration++;
    conversation.reset();
    projects = [];
    threads = [];
    models = [];
    accountUsage = {};
    projectId = null;
    _epoch = null;
    _sequence = 0;
    _buffer.clear();
    _syncing = false;
    _stopConnection();
    connection = ConnectionState.loginRequired;
    notifyListeners();
  }

  void reportError(Object exception) {
    error.value = exception.toString();
    if (exception is ApiError && exception.status == 401) {
      connection = ConnectionState.loginRequired;
      authenticated = false;
      unawaited(notifications.clear());
      _stopConnection();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopConnection();
    notifications.dispose();
    conversation.dispose();
    error.dispose();
    api.close();
    super.dispose();
  }
}
