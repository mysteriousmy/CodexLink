import 'dart:async';
import 'dart:convert';

import 'package:codex_link/data/api_client.dart';
import 'package:codex_link/data/release_info.dart';
import 'package:codex_link/data/update_controller.dart';
import 'package:codex_link/platform/app_installation.dart';
import 'package:codex_link/ui/update_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/github_release.dart';

const assetSuffixes = [
  'linux-x64.tar.gz',
  'linux-arm64.tar.gz',
  'windows-x64.zip',
  'windows-arm64.zip',
  'android-arm64-v8a.apk',
  'android-armeabi-v7a.apk',
  'android-x86_64.apk',
  'android-universal.apk',
];
JsonMap releaseJson({
  String version = '0.2.0',
  List<String> assets = assetSuffixes,
}) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'assets': [
    for (final suffix in assets)
      {
        'name': 'CodexLink-v$version-$suffix',
        'state': 'uploaded',
        'browser_download_url':
            'https://github.com/mysteriousmy/CodexLink/releases/download/v$version/CodexLink-v$version-$suffix',
      },
  ],
};
http.Response json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

class UpdatesFixture {
  UpdatesFixture({
    String appVersion = '0.1.9',
    String platform = 'android',
    String backendVersion = '0.1.8',
    String? target = 'linux-x64',
  }) {
    gateway = (request) async =>
        json({'version': backendVersion, 'packageTarget': ?target});
    github = (request) async => json(releaseJson());
    identity = () async => ClientInstallation(
      version: appVersion,
      platform: platform,
      abis: ['arm64-v8a', 'armeabi-v7a'],
    );
    api = ApiClient(
      client: MockClient((request) {
        gatewayCalls.add(request);
        return gateway(request);
      }),
    )..token = 'private-test-device-key';
    c = UpdateController(
      api: api,
      releaseClient: MockClient((request) {
        githubCalls.add(request);
        expect(
          request.url.toString(),
          'https://api.github.com/repos/mysteriousmy/CodexLink/releases/latest',
        );
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.headers.containsKey('Cookie'), isFalse);
        return github(request);
      }),
      installation: () => identity(),
      clock: () => now,
    );
    addTearDown(() {
      c.dispose();
      api.close();
    });
  }
  late final ApiClient api;
  late final UpdateController c;
  late Future<http.Response> Function(http.Request) gateway;
  late Future<http.Response> Function(http.Request) github;
  late Future<ClientInstallation> Function() identity;
  final gatewayCalls = <http.Request>[];
  final githubCalls = <http.Request>[];
  DateTime now = DateTime.utc(2026, 10, 25);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('update_checks_compare_app_and_server_independently', () async {
    final f = UpdatesFixture(appVersion: '0.2.0');
    await f.c.check();
    expect(f.c.appUpdateAvailable, isFalse);
    expect(f.c.serverUpdateAvailable, isTrue);
    expect(f.c.notice.value, '服务端有新版本 v0.2.0');
    expect(f.c.client!.version, '0.2.0');
    expect(f.c.server!.version, '0.1.8');
    f.identity = () async =>
        const ClientInstallation(version: '0.1.9', platform: 'android');
    f.gateway = (_) async =>
        json({'version': '0.2.0', 'packageTarget': 'windows-arm64'});
    await f.c.check(manual: true);
    expect(f.c.appUpdateAvailable, isTrue);
    expect(f.c.serverUpdateAvailable, isFalse);
    expect(f.c.notice.value, 'App有新版本 v0.2.0');
    expect(f.c.server!.target, 'windows-arm64');
    expect(
      f.gatewayCalls.every(
        (r) => kIsWeb
            ? !r.headers.containsKey('Authorization')
            : r.headers['Authorization'] == 'Bearer private-test-device-key',
      ),
      isTrue,
    );
  });

  test('release_versions_compare_numerically_and_ignore_build_metadata', () {
    final info = ReleaseInfo.fromJson(releaseJson(version: '0.10.0'));
    expect(info.newerThan('0.9.9'), isTrue);
    expect(info.newerThan('v0.10.0-rc.1'), isTrue);
    expect(info.newerThan('0.10.0+11'), isFalse);
    expect(parseVersion('0.10.0+11'), parseVersion('v0.10.0'));
    expect(info.newerThan('1.0.0'), isFalse);
    expect(info.newerThan(null), isFalse);
    expect(info.newerThan('unknown'), isFalse);
  });

  test('update_assets_match_platform_and_missing_assets_stay_missing', () {
    final info = ReleaseInfo.fromJson(releaseJson());
    for (final target in serverTargets.keys) {
      final extension = target.startsWith('linux') ? 'tar.gz' : 'zip';
      expect(
        info.serverAsset(target)!.url.toString(),
        'https://github.com/mysteriousmy/CodexLink/releases/download/v0.2.0/CodexLink-v0.2.0-$target.$extension',
      );
    }
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      expect(
        info
            .appAsset(
              ClientInstallation(
                version: '0.1.9',
                platform: 'android',
                abis: [abi],
              ),
            )!
            .name,
        'CodexLink-v0.2.0-android-$abi.apk',
      );
    }
    expect(
      info
          .appAsset(
            const ClientInstallation(
              version: '0.1.9',
              platform: 'android',
              abis: ['arm64-v8a', 'armeabi-v7a'],
            ),
          )!
          .name,
      'CodexLink-v0.2.0-android-arm64-v8a.apk',
    );
    expect(
      info
          .appAsset(
            const ClientInstallation(version: '0.1.9', platform: 'android'),
          )!
          .name,
      'CodexLink-v0.2.0-android-universal.apk',
    );
    expect(info.serverAsset('macos-arm64'), isNull);
    expect(
      info.appAsset(
        const ClientInstallation(version: '0.1.9', platform: 'ios'),
      ),
      isNull,
    );
    expect(
      info.appAsset(
        const ClientInstallation(version: '0.1.9', platform: 'web'),
      ),
      isNull,
    );
    final missing = ReleaseInfo.fromJson(releaseJson(assets: []));
    expect(missing.serverAsset('linux-x64'), isNull);
    expect(
      missing.appAsset(
        const ClientInstallation(
          version: '0.1.9',
          platform: 'android',
          abis: ['arm64-v8a'],
        ),
      ),
      isNull,
    );
    final universal = ReleaseInfo.fromJson(
      releaseJson(assets: ['android-universal.apk']),
    );
    expect(
      universal
          .appAsset(
            const ClientInstallation(
              version: '0.1.9',
              platform: 'android',
              abis: ['arm64-v8a'],
            ),
          )!
          .name,
      'CodexLink-v0.2.0-android-universal.apk',
    );
  });

  test('unpublished_or_foreign_assets_never_become_download_buttons', () {
    final value = releaseJson(
      assets: [
        'linux-x64.tar.gz',
        'windows-arm64.zip',
        'android-arm64-v8a.apk',
      ],
    );
    final assets = value['assets'] as List;
    assets[0]['browser_download_url'] = 'https://example.com/package';
    assets[1]['state'] = 'new';
    assets[2]['browser_download_url'] = 'https://github.com/mysteriousmy/Other/releases/download/v0.2.0/app.apk';
    expect(ReleaseInfo.fromJson(value).assets, isEmpty);
  });

  test('published_github_assets_match_real_release_package_names', () {
    final info = ReleaseInfo.fromJson(publishedReleaseFixture);
    expect(info.version.toString(), '0.1.9');
    expect(
      info.serverAsset('windows-x64')!.name,
      'CodexLink-v0.1.9-windows-x64.zip',
    );
    expect(
      info.serverAsset('windows-arm64')!.name,
      'CodexLink-v0.1.9-windows-arm64.zip',
    );
    expect(
      info.serverAsset('linux-x64')!.name,
      'CodexLink-v0.1.9-linux-x64.tar.gz',
    );
    expect(
      info.serverAsset('linux-arm64')!.name,
      'CodexLink-v0.1.9-linux-arm64.tar.gz',
    );
    expect(
      info
          .appAsset(
            const ClientInstallation(
              version: '0.1.8',
              platform: 'android',
              abis: ['arm64-v8a'],
            ),
          )!
          .url
          .toString(),
      'https://github.com/mysteriousmy/CodexLink/releases/download/v0.1.9/CodexLink-v0.1.9-android-arm64-v8a.apk',
    );
  });

  test('automatic_checks_throttle_and_manual_checks_bypass', () async {
    final f = UpdatesFixture();
    await f.c.check();
    expect(f.c.hasUpdate, isTrue);
    expect(f.c.notice.value, 'App、服务端有新版本 v0.2.0');
    final firstCheck = f.c.checkedAt;
    var notices = 0;
    f.c.notice.addListener(() => notices++);
    f.now = f.now.add(
      const Duration(hours: 6) - const Duration(milliseconds: 1),
    );
    await f.c.check();
    expect(f.githubCalls, hasLength(1));
    f.now = f.now.add(const Duration(milliseconds: 1));
    await f.c.check();
    expect(f.githubCalls, hasLength(2));
    expect(f.c.checkedAt!.isAfter(firstCheck!), isTrue);
    expect(notices, 0);
    await f.c.check(manual: true);
    expect(f.githubCalls, hasLength(3));
    await f.c.setAutomatic(false);
    f.now = f.now.add(const Duration(days: 1));
    await f.c.check();
    expect(f.githubCalls, hasLength(3));
    expect(
      (await SharedPreferences.getInstance()).getBool('automatic_updates'),
      isFalse,
    );
    await f.c.check(manual: true);
    expect(f.githubCalls, hasLength(4));
  });

  test('saved_opt_out_is_respected_and_manual_check_still_works', () async {
    SharedPreferences.setMockInitialValues({'automatic_updates': false});
    final f = UpdatesFixture();
    await f.c.check();
    expect(f.c.automatic, isFalse);
    expect(f.githubCalls, isEmpty);
    await f.c.check(manual: true);
    expect(f.githubCalls, hasLength(1));
    expect(f.c.hasUpdate, isTrue);
  });

  test('concurrent_update_checks_share_one_request', () async {
    final f = UpdatesFixture();
    final response = Completer<http.Response>();
    f.github = (_) => response.future;
    final first = f.c.check();
    final second = f.c.check(manual: true);
    await Future<void>.delayed(Duration.zero);
    expect(f.c.checking, isTrue);
    expect(f.githubCalls, hasLength(1));
    response.complete(json(releaseJson()));
    await Future.wait([first, second]);
    expect(f.c.checking, isFalse);
    expect(f.c.hasUpdate, isTrue);
  });

  test('old_server_version_fallback_keeps_platform_unknown', () async {
    final f = UpdatesFixture();
    f.gateway = (r) async => r.url.path == '/api/version'
        ? http.Response('', 404)
        : json({'version': '0.1.9'});
    await f.c.check();
    expect(f.gatewayCalls.map((r) => r.url.path), [
      '/api/version',
      '/version.json',
    ]);
    expect(f.c.server!.version, '0.1.9');
    expect(f.c.server!.target, isNull);
    expect(f.c.serverUpdateAvailable, isTrue);
  });

  test(
    'server_failure_does_not_hide_app_update_or_fallback_on_auth_error',
    () async {
      final f = UpdatesFixture();
      f.gateway = (_) async => json({'detail': 'expired'}, 401);
      await f.c.check();
      expect(f.c.server, isNull);
      expect(f.c.serverError, contains('服务端'));
      expect(f.gatewayCalls, hasLength(1));
      expect(f.c.appUpdateAvailable, isTrue);
      expect(f.c.serverUpdateAvailable, isFalse);
    },
  );

  test('unknown_app_version_does_not_hide_server_update', () async {
    final f = UpdatesFixture();
    f.identity = () async => throw PlatformException(code: 'missing');
    await f.c.check();
    expect(f.c.client, isNull);
    expect(f.c.clientError, contains('App'));
    expect(f.c.serverUpdateAvailable, isTrue);
    expect(f.c.appUpdateAvailable, isFalse);
  });

  for (final item in [
    (403, 'rate_limit'),
    (404, 'no_release'),
    (503, 'unavailable'),
  ]) {
    test('update_errors_retry_without_false_success_${item.$2}', () async {
      final f = UpdatesFixture();
      await f.c.check();
      f.github = (_) async => json({'message': 'failure'}, item.$1);
      await f.c.check(manual: true);
      expect(f.c.release, isNull);
      expect(f.c.hasUpdate, isFalse);
      expect(f.c.releaseError, isNotNull);
      expect(f.c.checking, isFalse);
      await f.c.check();
      expect(f.githubCalls, hasLength(2));
      f.github = (_) async => json(releaseJson());
      f.now = f.now.add(const Duration(minutes: 15));
      await f.c.check();
      expect(f.githubCalls, hasLength(3));
      expect(f.c.releaseError, isNull);
      expect(f.c.hasUpdate, isTrue);
    });
  }

  test('malformed_and_prerelease_responses_are_not_latest_success', () async {
    final f = UpdatesFixture();
    for (final response in [
      http.Response('<html>bad proxy</html>', 200),
      json({...releaseJson(), 'prerelease': true}),
      json(releaseJson(version: '0.3.0-rc.1')),
      json({...releaseJson(), 'draft': true}),
    ]) {
      f.github = (_) async => response;
      await f.c.check(manual: true);
      expect(f.c.release, isNull);
      expect(f.c.releaseError, isNotNull);
      expect(f.c.hasUpdate, isFalse);
    }
  });

  test('late_update_results_do_not_cross_servers', () async {
    final f = UpdatesFixture();
    final oldRelease = Completer<http.Response>();
    final oldServer = Completer<http.Response>();
    f.github = (_) => oldRelease.future;
    f.gateway = (_) => oldServer.future;
    final pending = f.c.check();
    await Future<void>.delayed(Duration.zero);
    f.c.reset();
    f.api.base = Uri.parse('http://second-host:47821');
    f.gateway = (_) async =>
        json({'version': '0.2.0', 'packageTarget': 'windows-arm64'});
    f.github = (_) async => json(releaseJson(version: '0.3.0'));
    await f.c.check();
    oldRelease.complete(json(releaseJson(version: '0.1.9')));
    oldServer.complete(
      json({'version': '0.1.0', 'packageTarget': 'linux-x64'}),
    );
    await pending;
    expect(f.c.server!.version, '0.2.0');
    expect(f.c.server!.target, 'windows-arm64');
    expect(f.c.release!.version.toString(), '0.3.0');
    expect(f.c.checking, isFalse);
  });

  test('android_version_and_abis_are_read_from_installed_package', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('codexlink/app_info');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'read');
          return {
            'version': '0.1.9',
            'supportedAbis': ['x86_64', 'x86'],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final info = await readClientInstallation();
    expect(info.version, '0.1.9');
    expect(info.abis, ['x86_64', 'x86']);
    expect(info.platform, 'android');
  }, skip: kIsWeb);

  testWidgets('update_dialog_shows_versions_and_opens_platform_downloads', (
    t,
  ) async {
    final f = UpdatesFixture();
    final opened = <Uri>[];
    await f.c.check();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateDialog(
            controller: f.c,
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.text('当前版本：0.1.9'), findsOneWidget);
    expect(find.text('当前版本：0.1.8'), findsOneWidget);
    expect(find.text('最新正式版 v0.2.0'), findsOneWidget);
    await t.tap(find.text('下载 App'));
    await t.ensureVisible(find.text('下载服务端'));
    await t.tap(find.text('下载服务端'));
    expect(opened.map((u) => u.toString()), [
      'https://github.com/mysteriousmy/CodexLink/releases/download/v0.2.0/CodexLink-v0.2.0-android-arm64-v8a.apk',
      'https://github.com/mysteriousmy/CodexLink/releases/download/v0.2.0/CodexLink-v0.2.0-linux-x64.tar.gz',
    ]);
    final calls = f.githubCalls.length;
    await t.tap(find.text('重新检查'));
    await t.pumpAndSettle();
    expect(f.githubCalls.length, calls + 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('old_server_platform_selection_opens_selected_package', (
    t,
  ) async {
    final f = UpdatesFixture(target: null);
    await f.c.check();
    Uri? opened;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateDialog(
            controller: f.c,
            openLink: (uri) async {
              opened = uri;
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.text('下载服务端'), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey('server-update-platform')));
    await t.tap(find.byKey(const ValueKey('server-update-platform')));
    await t.pumpAndSettle();
    await t.tap(find.text('Windows ARM64').last);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('下载服务端'));
    await t.tap(find.text('下载服务端'));
    expect(
      opened.toString(),
      'https://github.com/mysteriousmy/CodexLink/releases/download/v0.2.0/CodexLink-v0.2.0-windows-arm64.zip',
    );
  });

  testWidgets('web_updates_explain_refresh_and_never_offer_android_package', (
    t,
  ) async {
    final f = UpdatesFixture(platform: 'web');
    await f.c.check();
    t.view.physicalSize = const Size(360, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdateDialog(controller: f.c)),
      ),
    );
    expect(find.text('网页端'), findsOneWidget);
    expect(find.textContaining('刷新页面即可'), findsOneWidget);
    expect(find.text('下载 App'), findsNothing);
    expect(find.text('下载服务端'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('manual_retry_reports_failure_and_missing_packages_honestly', (
    t,
  ) async {
    final f = UpdatesFixture(appVersion: '0.3.0', backendVersion: '0.2.0');
    await f.c.check();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdateDialog(controller: f.c)),
      ),
    );
    expect(find.text('当前版本高于最新正式版'), findsOneWidget);
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('下载 App'), findsNothing);
    f.github = (_) async => json({}, 503);
    await t.tap(find.text('重新检查'));
    await t.pumpAndSettle();
    expect(find.text('GitHub 检查失败（503），请重试。'), findsOneWidget);
    expect(find.text('已是最新版本'), findsNothing);
    f.github = (_) async => json(releaseJson(version: '0.4.0', assets: []));
    await t.tap(find.text('重新检查'));
    await t.pumpAndSettle();
    expect(find.text('可更新至 v0.4.0'), findsNWidgets(2));
    expect(find.text('下载 App'), findsNothing);
    expect(find.text('下载服务端'), findsNothing);
    expect(find.text('此 Release 暂无适用于当前 App 平台的安装包。'), findsOneWidget);
    expect(find.text('此 Release 暂无对应服务端平台的安装包。'), findsOneWidget);
  });

  testWidgets('unsupported_server_platform_does_not_offer_wrong_platform', (
    t,
  ) async {
    final f = UpdatesFixture();
    f.gateway = (_) async => json({
      'version': '0.1.9',
      'platform': 'macos',
      'architecture': 'arm64',
      'packageTarget': null,
    });
    await f.c.check();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdateDialog(controller: f.c)),
      ),
    );
    expect(find.text('此 Release 暂无 macos arm64 服务端安装包。'), findsOneWidget);
    expect(find.byKey(const ValueKey('server-update-platform')), findsNothing);
    expect(find.text('下载服务端'), findsNothing);
  });

  test('update_timeout_finishes_check_and_ignores_late_release', () async {
    final f = UpdatesFixture();
    final response = Completer<http.Response>();
    final started = Completer<void>();
    f.github = (_) {
      started.complete();
      return response.future;
    };
    final check = f.c.check();
    await started.future;
    expect(f.c.checking, isTrue);
    await check;
    expect(f.c.checking, isFalse);
    expect(f.c.releaseError, '无法检查 GitHub 更新，请检查网络后重试。');
    expect(f.c.hasUpdate, isFalse);
    response.complete(json(releaseJson()));
    await Future<void>.delayed(Duration.zero);
    expect(f.c.release, isNull);
    expect(f.c.server!.version, '0.1.8');
  });
}
