import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/transport.dart' as transport;
import 'api_client.dart';
import 'models.dart';

class AttachmentUpload extends ChangeNotifier {
  AttachmentUpload(this.file, this.size, this.threadId);
  final PlatformFile file;
  final int size;
  final String threadId;
  JsonMap? uploaded;
  double progress = 0;
  String? error;
  bool running = false;
  bool removed = false;
  Completer<void> cancellation = Completer<void>();
  void changed() => notifyListeners();
  void cancel() {
    if (!cancellation.isCompleted) cancellation.complete();
  }
}

String newRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class ConversationController extends ChangeNotifier {
  ConversationController(
    this.api, {
    required this.onError,
    required this.onTurnFinished,
  });
  final ApiClient api;
  final void Function(Object) onError;
  final void Function() onTurnFinished;
  String? threadId;
  JsonMap thread = {};
  String? activeTurnId;
  String? model;
  String? effort;
  JsonMap? goal;
  TokenUsage usage = const TokenUsage(null, null, null, null, null, null, null);
  final List<ConversationItem> items = [];
  final Map<String, ConversationItem> _byId = {};
  final Map<String, String> _turnDiffs = {};
  List<JsonMap> approvals = [];
  List<JsonMap> files = [];
  String draft = '';
  bool goalMode = false;
  String? _pendingGoalObjective;
  List<JsonMap> references = [];
  String? activity;
  final List<(String, JsonMap)> _duringReload = [];
  int _reloadBytes = 0;
  bool _reloadOverflow = false;
  bool canControl = true;
  bool archived = false;
  String? controlReason;
  bool loading = false;
  bool sending = false;
  bool loadingOlder = false;
  String? olderError;
  bool uncertain = false;
  String? itemsCursor;
  String? pendingRequestId;
  JsonMap? _pendingBody;
  String? _pendingPath;
  String? _pendingThread;
  final Map<String, List<AttachmentUpload>> _uploads = {};
  final Set<ConversationItem> _dirty = {};
  Timer? _flushTimer;
  Timer? _draftTimer;
  int _generation = 0;
  bool _disposed = false;
  final ValueNotifier<int> streamRevision = ValueNotifier(0);
  List<AttachmentUpload> get uploads => _uploads[threadId] ?? const [];
  bool get hasUnreadyFiles => uploads.any((file) => file.uploaded == null);
  bool get canSend =>
      canControl &&
      !sending &&
      !loading &&
      !uncertain &&
      !hasUnreadyFiles &&
      (goalMode
          ? draft.trim().isNotEmpty
          : draft.trim().isNotEmpty ||
                uploads.isNotEmpty ||
                references.isNotEmpty);
  String get title => threadTitle(thread);

  String _draftKey(String id) => 'draft:${api.base.origin}:$id';
  void setGoalMode(bool value) {
    if (sending || uncertain || !canControl) return;
    goalMode = value;
    notifyListeners();
  }

  void setDraft(String text) {
    draft = text;
    _draftTimer?.cancel();
    final id = threadId;
    if (id != null) {
      _draftTimer = Timer(const Duration(milliseconds: 500), () async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(_draftKey(id), text);
      });
    }
  }

  Future<void> select(String id, {bool archived = false}) async {
    if (sending || uncertain) throw const ApiError('请先核对当前消息的提交结果，再切换会话。');
    _draftTimer?.cancel();
    final preferences = await SharedPreferences.getInstance();
    if (threadId != null) {
      await preferences.setString(_draftKey(threadId!), draft);
    }
    threadId = id;
    goalMode = false;
    this.archived = archived;
    canControl = !archived;
    controlReason = null;
    draft = preferences.getString(_draftKey(id)) ?? '';
    final savedReferences = preferences.getString(
      '${_draftKey(id)}:references',
    );
    references = savedReferences == null
        ? []
        : asMaps(jsonDecode(savedReferences));
    activity = null;
    _duringReload.clear();
    _clearItems();
    thread = {};
    activeTurnId = null;
    goal = null;
    usage = const TokenUsage(null, null, null, null, null, null, null);
    approvals = [];
    files = [];
    itemsCursor = null;
    loadingOlder = false;
    olderError = null;
    await reload();
  }

  Future<void> reload() async {
    final id = threadId;
    if (id == null) return;
    final generation = ++_generation;
    loadingOlder = false;
    olderError = null;
    _duringReload.clear();
    _reloadBytes = 0;
    _reloadOverflow = false;
    loading = true;
    notifyListeners();
    try {
      final snapshot = asMap(
        await api.request(
          'GET',
          '/api/threads/$id',
          query: {'archived': '$archived'},
        ),
      );
      final history = asMap(await api.request('GET', '/api/threads/$id/items'));
      final target = asMap(await api.request('GET', '/api/threads/$id/goal'));
      if (generation != _generation || id != threadId) return;
      thread = asMap(snapshot['thread']);
      canControl = snapshot['canControl'] != false;
      controlReason = snapshot['controlReason'] as String?;
      archived = snapshot['archived'] == true;
      model = thread['model'] as String?;
      effort = thread['reasoningEffort'] as String?;
      activeTurnId = snapshot['activeTurnId'] as String?;
      usage = TokenUsage.fromJson(asMap(snapshot['usage']));
      goal = target['goal'] == null ? null : asMap(target['goal']);
      approvals = asMaps(snapshot['approvals']);
      files = asMaps(snapshot['attachments']);
      _mergeHistory(asMaps(history['data']), prepend: false);
      itemsCursor = history['nextCursor'] as String?;
    } finally {
      if (generation == _generation) {
        loading = false;
        final buffered = List.of(_duringReload);
        _duringReload.clear();
        for (final event in buffered) {
          handleEvent(event.$1, event.$2);
        }
        if (_reloadOverflow) {
          canControl = false;
          controlReason = '同步期间事件过多，请同步重试以核对最新状态。';
          onError(ApiError(controlReason!));
        }
        notifyListeners();
      }
    }
  }

  Future<void> unarchive() async {
    final id = threadId;
    if (id == null) return;
    await api.request('POST', '/api/threads/$id/unarchive');
    archived = false;
    await reload();
  }

  Future<void> loadOlder() async {
    if (threadId == null || itemsCursor == null || loadingOlder || loading) {
      return;
    }
    final id = threadId!;
    final generation = _generation;
    loadingOlder = true;
    olderError = null;
    notifyListeners();
    try {
      final result = asMap(
        await api.request(
          'GET',
          '/api/threads/$id/items',
          query: {'cursor': itemsCursor!},
        ),
      );
      if (threadId != id || generation != _generation) return;
      _mergeHistory(asMaps(result['data']), prepend: true);
      itemsCursor = result['nextCursor'] as String?;
    } catch (error) {
      if (threadId == id && generation == _generation) {
        olderError = '$error';
        onError(error);
      }
    } finally {
      if (threadId == id && generation == _generation) {
        loadingOlder = false;
        notifyListeners();
      }
    }
  }

  void _mergeHistory(List<JsonMap> entries, {required bool prepend}) {
    final added = <ConversationItem>[];
    for (final entry in entries.reversed) {
      final item = asMap(entry['item']);
      final id = item['id'] as String?;
      if (id == null) continue;
      final existing = _byId[id];
      if (existing != null) {
        // History was requested before the latest live event. Never replace a
        // completed/longer live message with an older snapshot of that item.
        if (existing.text.length >= (item['text'] as String? ?? '').length &&
            existing.text.isNotEmpty) {
          continue;
        }
        existing.replace(item, isStreaming: false);
      } else {
        final value = ConversationItem(
          id,
          entry['turnId'] as String? ?? '',
          item,
          streaming: false,
        );
        _byId[id] = value;
        added.add(value);
      }
    }
    if (prepend) {
      items.insertAll(0, added);
    } else {
      items.addAll(added);
    }
    final turns = added
        .where((item) => item.type == 'fileChange')
        .map((item) => item.turnId)
        .toSet();
    for (final turn in turns) {
      _updateDiffSummary(turn);
    }
  }

  void _updateDiffSummary(String turnId) {
    final changes = items
        .where(
          (item) =>
              item.turnId == turnId &&
              item.type == 'fileChange' &&
              item.data['status'] != 'failed' &&
              item.data['status'] != 'declined',
        )
        .expand((item) => asMaps(item.data['changes']))
        .toList();
    if (changes.isEmpty && !_turnDiffs.containsKey(turnId)) return;
    final id = 'codexlink-diff:$turnId';
    final data = <String, dynamic>{
      'id': id,
      'type': 'turnDiff',
      'changes': changes,
      if (_turnDiffs.containsKey(turnId)) 'diff': _turnDiffs[turnId],
    };
    final summary = _byId[id] ?? ConversationItem(id, turnId, data);
    summary.replace(data, isStreaming: activeTurnId == turnId);
    _byId[id] = summary;
    items.remove(summary);
    final last = items.lastIndexWhere((item) => item.turnId == turnId);
    items.insert(last < 0 ? items.length : last + 1, summary);
  }

  void handleEvent(String method, JsonMap parameters) {
    if (loading &&
        (parameters['threadId'] == threadId ||
            method.startsWith('approval/'))) {
      if (_reloadOverflow) return;
      _reloadBytes += jsonEncode(parameters).length * 2;
      if (_duringReload.length >= 2048 || _reloadBytes > 8 * 1024 * 1024) {
        _duringReload.clear();
        _reloadOverflow = true;
        return;
      }
      _duringReload.add((method, parameters));
      return;
    }
    if (method == 'approval/resolved') {
      approvals.removeWhere((a) => a['id'] == parameters['id']);
      notifyListeners();
      return;
    }
    if (method == 'approval/requested') {
      if (asMap(parameters['params'])['threadId'] == threadId) {
        approvals.removeWhere((a) => a['id'] == parameters['id']);
        approvals.add(parameters);
        notifyListeners();
      }
      return;
    }
    if (parameters['threadId'] != threadId) return;
    switch (method) {
      case 'turn/started':
        activeTurnId = asMap(parameters['turn'])['id'] as String?;
        activity = '正在处理';
        notifyListeners();
      case 'turn/completed':
        final turn = asMap(parameters['turn']);
        if (activeTurnId == turn['id']) activeTurnId = null;
        activity = null;
        for (final item in items.where(
          (item) => item.turnId == turn['id'] && item.streaming,
        )) {
          item.streaming = false;
          item.flush();
        }
        _updateDiffSummary(turn['id'] as String? ?? '');
        final failure = asMap(turn['error']);
        if (failure['message'] != null) {
          onError(ApiError(failure['message'] as String));
        }
        notifyListeners();
        onTurnFinished();
      case 'item/started':
      case 'item/completed':
        final data = asMap(parameters['item']);
        final id = data['id'] as String?;
        if (id == null) break;
        if (method == 'item/started') {
          activity = switch (data['type']) {
            'agentMessage' => data['phase'] == 'commentary' ? '正在汇报进展' : '正在回复',
            'commandExecution' => '正在执行命令',
            'fileChange' => '正在修改文件',
            'mcpToolCall' => '正在调用工具',
            'imageGeneration' => '正在生成图片',
            'webSearch' => '正在搜索',
            'reasoning' => '正在思考',
            _ => '正在处理',
          };
        } else if (activeTurnId != null) {
          activity = '正在继续处理';
        }
        final existing = _byId[id];
        if (existing != null) {
          if (method == 'item/completed') {
            existing.replace(data, isStreaming: false);
          }
        } else {
          final value = ConversationItem(
            id,
            parameters['turnId'] as String? ?? '',
            data,
            streaming: method == 'item/started',
          );
          _byId[id] = value;
          items.add(value);
          notifyListeners();
        }
        streamRevision.value++;
        if (data['type'] == 'fileChange' && method == 'item/completed') {
          _updateDiffSummary(parameters['turnId'] as String? ?? '');
        }
        notifyListeners();
      case 'item/agentMessage/delta':
      case 'item/commandExecution/outputDelta':
        final id = parameters['itemId'] as String?;
        if (id == null) break;
        var item = _byId[id];
        if (item == null) {
          item = ConversationItem(id, parameters['turnId'] as String? ?? '', {
            'id': id,
            'type': method.contains('agentMessage')
                ? 'agentMessage'
                : 'commandExecution',
          }, streaming: true);
          _byId[id] = item;
          items.add(item);
          notifyListeners();
        }
        final field = method.contains('agentMessage')
            ? 'text'
            : 'aggregatedOutput';
        final delta = parameters['delta'] as String? ?? '';
        final offset = parameters['clientOffset'] as int?;
        final currentLength = item.fieldLength(field);
        if (offset == null || offset >= currentLength) {
          item.append(field, delta);
        } else if (offset + delta.length > currentLength) {
          item.append(field, delta.substring(currentLength - offset));
        }
        _dirty.add(item);
        _flushTimer ??= Timer(const Duration(milliseconds: 40), () {
          for (final value in _dirty) {
            value.flush();
          }
          _dirty.clear();
          _flushTimer = null;
          streamRevision.value++;
        });
      case 'thread/tokenUsage/updated':
        usage = TokenUsage.fromJson(asMap(parameters['tokenUsage']));
        notifyListeners();
      case 'thread/goal/updated':
        goal = asMap(parameters['goal']);
        notifyListeners();
      case 'thread/goal/cleared':
        goal = null;
        notifyListeners();
      case 'turn/diff/updated':
        final turnId = parameters['turnId'] as String?;
        if (turnId != null && parameters['diff'] is String) {
          _turnDiffs[turnId] = parameters['diff'] as String;
          _updateDiffSummary(turnId);
        }
        notifyListeners();
    }
  }

  Future<void> pickFiles(int maxFileBytes) async {
    final picked = await FilePicker.pickFiles(dialogTitle: '为当前消息添加附件');
    await addFiles(picked, maxFileBytes);
  }

  Future<void> addFiles(List<PlatformFile> picked, int maxFileBytes) async {
    final id = threadId;
    if (id == null || sending || uncertain) {
      for (final file in picked) {
        transport.releaseFile(file);
      }
      return;
    }
    for (final file in picked) {
      final size = await file.length();
      if (size == null || size <= 0 || size > maxFileBytes) {
        onError(ApiError('${file.name} 超出单个文件限制，或文件为空。'));
        transport.releaseFile(file);
        continue;
      }
      final list = _uploads.putIfAbsent(id, () => []);
      if (list.length >= 10 ||
          list.fold<int>(0, (sum, f) => sum + f.size) + size >
              100 * 1024 * 1024) {
        onError(const ApiError('一条消息最多 10 个附件，总计 100 MiB。'));
        transport.releaseFile(file);
        continue;
      }
      final upload = AttachmentUpload(file, size, id);
      list.add(upload);
      notifyListeners();
      unawaited(uploadAttachment(upload));
    }
  }

  Future<void> uploadAttachment(AttachmentUpload file) async {
    if (file.running || file.removed || _disposed) return;
    final origin = api.base.origin;
    file.running = true;
    file.error = null;
    file.progress = 0;
    file.cancellation = Completer<void>();
    file.changed();
    try {
      final response = await transport.uploadFile(
        file: file.file,
        size: file.size,
        uri: api.uri('/api/attachments', {'threadId': file.threadId}),
        token: api.token,
        progress: (progress) {
          file.progress = progress;
          file.changed();
        },
        cancel: file.cancellation.future,
      );
      file.uploaded = asMap(ApiClient.decode(response));
      file.progress = 1;
      if (file.removed && !_disposed && origin == api.base.origin) {
        await api.request('DELETE', '/api/attachments/${file.uploaded!['id']}');
      }
    } catch (error) {
      file.error = error.toString();
    } finally {
      file.running = false;
      file.changed();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> removeUpload(AttachmentUpload file) async {
    file.removed = true;
    file.cancel();
    transport.releaseFile(file.file);
    _uploads[file.threadId]?.remove(file);
    if (file.uploaded?['id'] case final String id) {
      try {
        await api.request('DELETE', '/api/attachments/$id');
      } catch (error) {
        onError(error);
      }
    }
    notifyListeners();
  }

  Future<bool> send() async {
    if (!canSend || threadId == null) return false;
    if (goalMode) return _sendGoal();
    final id = threadId!;
    final generation = _generation;
    final requestId = newRequestId();
    final body = <String, dynamic>{
      'requestId': requestId,
      'text': draft,
      'attachmentIds': uploads.map((f) => f.uploaded!['id']).toList(),
      'references': List<JsonMap>.of(references),
      if (activeTurnId == null && model != null) 'model': model,
      if (activeTurnId == null && effort != null) 'effort': effort,
    };
    final path = activeTurnId == null
        ? '/api/threads/$id/turns'
        : '/api/threads/$id/turns/$activeTurnId/steer';
    pendingRequestId = requestId;
    _pendingBody = body;
    _pendingPath = path;
    _pendingThread = id;
    sending = true;
    notifyListeners();
    try {
      await api.request('POST', path, body: body);
      if (_disposed || generation != _generation || threadId != id) return true;
      await _accepted(id);
      return true;
    } catch (error) {
      if (_disposed || generation != _generation || threadId != id) {
        return false;
      }
      // Transport failures and RPC timeouts leave acceptance unknown. Never auto-resend.
      uncertain =
          error is! ApiError ||
          error.status == null ||
          error.status! >= 500 ||
          error.status! < 400 ||
          error.status == 408;
      if (!uncertain) {
        pendingRequestId = null;
        _pendingBody = null;
        _pendingPath = null;
      }
      onError(error);
      return false;
    } finally {
      if (!_disposed && generation == _generation) {
        sending = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _sendGoal() async {
    // Native Goal accepts an objective, not a turn's skill/image inputs. Keep
    // those selections intact instead of silently dropping them from a goal.
    if (uploads.isNotEmpty || references.isNotEmpty) {
      onError(const ApiError('Goal 使用目标文本；请先发送或移除附件与引用。'));
      return false;
    }
    final id = threadId!;
    final text = draft;
    final objective = text.trim();
    if (objective.length > 4000) {
      onError(const ApiError('目标最多 4,000 字符，内容已保留。'));
      return false;
    }
    sending = true;
    _pendingGoalObjective = objective;
    notifyListeners();
    try {
      await setGoal(objective: objective, status: 'active');
      await _acceptedGoal(id, objective);
      return true;
    } catch (error) {
      uncertain =
          error is! ApiError ||
          error.status == null ||
          error.status! >= 500 ||
          error.status == 408;
      if (!uncertain) _pendingGoalObjective = null;
      onError(error);
      return false;
    } finally {
      sending = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _acceptedGoal(String id, String objective) async {
    if (_disposed || threadId != id) return;
    if (draft.trim() == objective) {
      draft = '';
      goalMode = false;
    }
    _pendingGoalObjective = null;
    uncertain = false;
    _draftTimer?.cancel();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_draftKey(id), draft);
    if (!_disposed) notifyListeners();
  }

  Future<void> _accepted(String id) async {
    final sent = _pendingBody;
    if (draft == sent?['text']) draft = '';
    final sentReferences = asMaps(sent?['references']);
    references.removeWhere(
      (r) => sentReferences.any(
        (s) => s['type'] == r['type'] && s['path'] == r['path'],
      ),
    );
    await _saveReferences();
    _draftTimer?.cancel();
    uncertain = false;
    pendingRequestId = null;
    _pendingBody = null;
    _pendingPath = null;
    final sentFiles = (sent?['attachmentIds'] as List?) ?? const [];
    _uploads[id]?.removeWhere((file) {
      if (!sentFiles.contains(file.uploaded?['id'])) return false;
      transport.releaseFile(file.file);
      return true;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_draftKey(id), draft);
    notifyListeners();
  }

  Future<void> reconcile() async {
    if (_pendingGoalObjective case final String objective) {
      final result = asMap(
        await api.request('GET', '/api/threads/$threadId/goal'),
      );
      goal = result['goal'] == null ? null : asMap(result['goal']);
      if (goal?['objective'] == objective) {
        await _acceptedGoal(threadId!, objective);
      } else {
        onError(const ApiError('目标提交结果仍未知，请检查当前目标后再决定是否重新发送。'));
      }
      await reload();
      return;
    }
    if (pendingRequestId == null) return;
    final result = asMap(
      await api.request('GET', '/api/operations/$pendingRequestId'),
    );
    if (result['state'] == 'accepted') {
      await _accepted(_pendingThread!);
    } else if (result['state'] == 'failed') {
      uncertain = false;
      pendingRequestId = null;
      onError(ApiError(result['message'] as String? ?? '操作失败，草稿已保留。'));
    } else {
      onError(const ApiError('提交结果仍未知。请检查最新消息；确认未执行后才能重新发送。'));
    }
    await reload();
  }

  Future<void> retrySameRequest() async {
    if (_pendingBody == null || _pendingPath == null) return;
    final status = asMap(
      await api.request('GET', '/api/operations/$pendingRequestId'),
    );
    if (status['state'] == 'unknown') {
      throw const ApiError('网关已不记得此请求。请人工核对最新会话，不能安全自动重发。');
    }
    await api.request('POST', _pendingPath!, body: _pendingBody);
    await _accepted(_pendingThread!);
  }

  void confirmNotSubmitted() {
    uncertain = false;
    _pendingGoalObjective = null;
    pendingRequestId = null;
    _pendingBody = null;
    _pendingPath = null;
    notifyListeners();
  }

  Future<void> stop() async {
    if (threadId != null && activeTurnId != null) {
      await api.request(
        'POST',
        '/api/threads/$threadId/turns/$activeTurnId/interrupt',
      );
    }
  }

  Future<void> setGoal({
    String? objective,
    String? status,
    int? budget,
    bool budgetSpecified = false,
  }) async {
    if (threadId == null || !canControl) return;
    final result = asMap(
      await api.request(
        'PUT',
        '/api/threads/$threadId/goal',
        body: {
          'objective': objective,
          'status': status,
          'tokenBudget': budget,
          'budgetSpecified': budgetSpecified,
        },
      ),
    );
    goal = result['goal'] == null ? null : asMap(result['goal']);
    notifyListeners();
  }

  Future<void> clearGoal() async {
    if (threadId == null) return;
    await api.request('DELETE', '/api/threads/$threadId/goal');
    goal = null;
    notifyListeners();
  }

  Future<void> _saveReferences() async {
    if (threadId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '${_draftKey(threadId!)}:references',
      jsonEncode(references),
    );
  }

  void addReference(JsonMap reference) {
    if (references.any(
      (r) => r['type'] == reference['type'] && r['path'] == reference['path'],
    )) {
      return;
    }
    references.add(reference);
    unawaited(_saveReferences());
    notifyListeners();
  }

  void removeReference(JsonMap reference) {
    references.remove(reference);
    unawaited(_saveReferences());
    notifyListeners();
  }

  Future<List<JsonMap>> skills({bool refresh = false}) async {
    final result = asMap(
      await api.request(
        'GET',
        '/api/threads/$threadId/skills',
        query: {'refresh': '$refresh'},
      ),
    );
    return asMaps(result['data']).expand((e) => asMaps(e['skills'])).toList();
  }

  Future<List<JsonMap>> searchFiles(String query) async {
    final result = asMap(
      await api.request(
        'GET',
        '/api/threads/$threadId/file-search',
        query: {'query': query},
      ),
    );
    return asMaps(result['files'])
        .where((f) => f['match_type'] != 'directory')
        .take(50)
        .toList();
  }

  Future<JsonMap> mcp({String? cursor}) async => asMap(
    await api.request(
      'GET',
      '/api/threads/$threadId/mcp',
      query: {'cursor': ?cursor},
    ),
  );

  Future<void> answer(String id, JsonMap result) async {
    await api.request('POST', '/api/approvals/$id', body: {'result': result});
    approvals.removeWhere((a) => a['id'] == id);
    notifyListeners();
  }

  Future<void> download(JsonMap file) => transport.downloadFile(
    api.uri('/api/attachments/${file['id']}'),
    api.token,
    file['name'] as String,
  );
  Future<void> deleteFile(JsonMap file) async {
    await api.request(
      'DELETE',
      '/api/attachments/${file['id']}',
      query: {'cleanup': 'true'},
    );
    files.removeWhere((f) => f['id'] == file['id']);
    notifyListeners();
  }

  void runtimeStopped() {
    activeTurnId = null;
    activity = null;
    approvals = [];
    notifyListeners();
  }

  void reset() {
    _generation++;
    _draftTimer?.cancel();
    _clearItems();
    for (final list in _uploads.values) {
      for (final file in list) {
        file.removed = true;
        file.cancel();
        transport.releaseFile(file.file);
      }
    }
    _uploads.clear();
    threadId = null;
    thread = {};
    activeTurnId = null;
    goal = null;
    usage = const TokenUsage(null, null, null, null, null, null, null);
    approvals = [];
    files = [];
    draft = '';
    goalMode = false;
    _pendingGoalObjective = null;
    references = [];
    activity = null;
    _duringReload.clear();
    canControl = true;
    archived = false;
    controlReason = null;
    loading = false;
    sending = false;
    uncertain = false;
    pendingRequestId = null;
    _pendingBody = null;
    _pendingPath = null;
    itemsCursor = null;
    notifyListeners();
  }

  void _clearItems() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty.clear();
    for (final item in items) {
      item.dispose();
    }
    items.clear();
    _byId.clear();
    _turnDiffs.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _draftTimer?.cancel();
    _clearItems();
    streamRevision.dispose();
    for (final list in _uploads.values) {
      for (final file in list) {
        file.cancel();
        transport.releaseFile(file.file);
      }
    }
    super.dispose();
  }
}
