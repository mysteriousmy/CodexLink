import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/app_installation.dart';
import 'api_client.dart';
import 'release_info.dart';

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.api,
    http.Client? releaseClient,
    Future<ClientInstallation> Function()? installation,
    DateTime Function()? clock,
  }) : _releaseClient = releaseClient ?? http.Client(),
       _installation = installation ?? readClientInstallation,
       _clock = clock ?? DateTime.now;

  final ApiClient api;
  // This public GitHub client never receives gateway credentials or cookies.
  final http.Client _releaseClient;
  final Future<ClientInstallation> Function() _installation;
  final DateTime Function() _clock;
  final ValueNotifier<String?> notice = ValueNotifier(null);
  ClientInstallation? client;
  ServerInstallation? server;
  ReleaseInfo? release;
  String? releaseError;
  String? serverError;
  String? clientError;
  String? preferenceError;
  DateTime? checkedAt;
  DateTime? _attemptedAt;
  String? _origin;
  String? _notified;
  bool automatic = true;
  bool checking = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _pending;
  Future<void>? _preferences;
  bool get appUpdateAvailable => release?.newerThan(client?.version) == true;
  bool get serverUpdateAvailable => release?.newerThan(server?.version) == true;
  bool get hasUpdate => appUpdateAvailable || serverUpdateAvailable;

  Future<void> _loadPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      automatic = preferences.getBool('automatic_updates') ?? true;
    } catch (_) {
      preferenceError = '无法读取自动检查设置。';
    }
  }

  Future<void> setAutomatic(bool enabled) async {
    await (_preferences ??= _loadPreferences());
    if (_disposed) return;
    automatic = enabled;
    notifyListeners();
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setBool('automatic_updates', enabled)) {
        throw StateError('save failed');
      }
      preferenceError = null;
    } catch (_) {
      preferenceError = '自动检查设置未能保存，下次启动后请重新确认。';
    }
    if (!_disposed) notifyListeners();
  }

  void reset() {
    _generation++;
    _pending = null;
    _origin = null;
    _attemptedAt = null;
    checkedAt = null;
    server = null;
    release = null;
    releaseError = serverError = clientError = null;
    checking = false;
    notice.value = null;
    _notified = null;
    notifyListeners();
  }

  Future<void> check({bool manual = false}) async {
    final generation = _generation;
    await (_preferences ??= _loadPreferences());
    if (_disposed || generation != _generation) return;
    if (_origin != null && _origin != api.base.origin) reset();
    _origin = api.base.origin;
    if (_pending != null) return _pending;
    final retryAfter =
        releaseError == null && serverError == null && clientError == null
        ? const Duration(hours: 6)
        : const Duration(minutes: 15);
    if (!manual &&
        (!automatic ||
            (_attemptedAt != null &&
                _clock().difference(_attemptedAt!) < retryAfter))) {
      return;
    }
    final current = _generation;
    final pending = _check(current, _origin!);
    _pending = pending;
    try {
      await pending;
    } finally {
      if (!_disposed && current == _generation) _pending = null;
    }
  }

  Future<void> _check(int generation, String origin) async {
    bool current() =>
        !_disposed && generation == _generation && api.base.origin == origin;
    checking = true;
    _attemptedAt = _clock();
    releaseError = serverError = clientError = null;
    release = null;
    notifyListeners();
    await Future.wait([
      () async {
        try {
          final info = await _installation().timeout(
            const Duration(seconds: 12),
          );
          if (current()) client = info;
        } catch (_) {
          if (current()) {
            client = null;
            clientError = '无法读取当前 App 版本，请重试。';
          }
        }
      }(),
      () async {
        try {
          dynamic data;
          try {
            data = await api
                .request('GET', '/api/version')
                .timeout(const Duration(seconds: 12));
          } on ApiError catch (error) {
            if (error.status != 404) rethrow;
            // v0.1.x exposes the embedded Web version, but not its host platform.
            if (!current()) return;
            data = await api
                .request('GET', '/version.json')
                .timeout(const Duration(seconds: 12));
          }
          final info = ServerInstallation.fromJson(asMap(data));
          if (current()) server = info;
        } catch (_) {
          if (current()) {
            server = null;
            serverError = '无法读取服务端版本，请检查连接后重试。';
          }
        }
      }(),
      () async {
        try {
          final response = await _releaseClient
              .get(
                Uri.https(
                  'api.github.com',
                  '/repos/$releaseRepository/releases/latest',
                ),
                headers: {'Accept': 'application/vnd.github+json'},
              )
              .timeout(const Duration(seconds: 12));
          if (response.statusCode != 200) {
            throw ApiError(switch (response.statusCode) {
              403 || 429 => 'GitHub 暂时限制请求，请稍后重试。',
              404 => 'GitHub 暂无可用的正式发布版本。',
              _ => 'GitHub 检查失败（${response.statusCode}），请重试。',
            });
          }
          final info = ReleaseInfo.fromJson(
            asMap(jsonDecode(utf8.decode(response.bodyBytes))),
          );
          if (current()) {
            release = info;
            checkedAt = _clock();
          }
        } catch (error) {
          if (current()) {
            // Do not present cached metadata as a successful fresh comparison.
            release = null;
            releaseError = error is ApiError
                ? error.message
                : '无法检查 GitHub 更新，请检查网络后重试。';
          }
        }
      }(),
    ]);
    if (!current()) return;
    checking = false;
    if (hasUpdate) {
      final signature =
          '$origin/${release!.tag}/${client?.version}/${server?.version}';
      if (_notified != signature) {
        _notified = signature;
        final targets = [
          if (appUpdateAvailable) client?.isWeb == true ? '网页端' : 'App',
          if (serverUpdateAvailable) '服务端',
        ];
        notice.value = '${targets.join('、')}有新版本 v${release!.version}';
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _releaseClient.close();
    notice.dispose();
    super.dispose();
  }
}
