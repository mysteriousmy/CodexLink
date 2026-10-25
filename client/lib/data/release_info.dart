import 'package:pub_semver/pub_semver.dart';

import 'api_client.dart';

const releaseRepository = 'mysteriousmy/CodexLink';
const compiledClientVersion = String.fromEnvironment(
  'CODEXLINK_VERSION',
  defaultValue: '0.2.0',
);
const serverTargets = {
  'linux-x64': 'Linux x64',
  'linux-arm64': 'Linux ARM64',
  'windows-x64': 'Windows x64',
  'windows-arm64': 'Windows ARM64',
};

Version? parseVersion(String? value) {
  if (value == null) return null;
  try {
    final parsed = Version.parse(
      value.startsWith('v') ? value.substring(1) : value,
    );
    // Android build codes and Git build metadata do not change release ordering.
    return Version(
      parsed.major,
      parsed.minor,
      parsed.patch,
      pre: parsed.preRelease.isEmpty ? null : parsed.preRelease.join('.'),
    );
  } on FormatException {
    return null;
  }
}

class ClientInstallation {
  const ClientInstallation({
    required this.version,
    required this.platform,
    this.abis = const [],
  });
  final String version;
  final String platform;
  final List<String> abis;
  bool get isWeb => platform == 'web';
}

class ServerInstallation {
  const ServerInstallation({
    required this.version,
    this.target,
    this.platform,
    this.architecture,
  });
  final String version;
  final String? target;
  final String? platform;
  final String? architecture;

  factory ServerInstallation.fromJson(JsonMap json) {
    final version = json['version'] as String?;
    if (parseVersion(version) == null) {
      throw const FormatException('服务端未提供有效版本号');
    }
    final target = json['packageTarget'] as String?;
    return ServerInstallation(
      version: version!,
      target: serverTargets.containsKey(target) ? target : null,
      platform: json['platform'] as String?,
      architecture: json['architecture'] as String?,
    );
  }
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url);
  final String name;
  final Uri url;
}

class ReleaseInfo {
  ReleaseInfo._(this.tag, this.version, this.assets);
  final String tag;
  final Version version;
  final List<ReleaseAsset> assets;
  Uri get page =>
      Uri.https('github.com', '/$releaseRepository/releases/tag/$tag');

  factory ReleaseInfo.fromJson(JsonMap json) {
    final tag = json['tag_name'] as String?;
    final version = parseVersion(tag);
    if (json['draft'] != false ||
        json['prerelease'] != false ||
        version == null ||
        version.isPreRelease) {
      throw const FormatException('GitHub 未返回有效的正式发布版本');
    }
    final assets = <ReleaseAsset>[];
    for (final item in asMaps(json['assets'])) {
      final name = item['name'];
      final url = Uri.tryParse(item['browser_download_url'] as String? ?? '');
      if (name is! String || item['state'] != 'uploaded' || url == null) {
        continue;
      }
      // Only expose actual published assets from this repository. Never build
      // speculative download links for a package absent from the release.
      final expected = Uri.https(
        'github.com',
        '/$releaseRepository/releases/download/$tag/$name',
      );
      if (url == expected) assets.add(ReleaseAsset(name, url));
    }
    return ReleaseInfo._(tag!, version, List.unmodifiable(assets));
  }

  bool newerThan(String? current) {
    final installed = parseVersion(current);
    return installed != null && version > installed;
  }

  ReleaseAsset? _asset(String suffix) =>
      assets.where((a) => a.name == 'CodexLink-v$version-$suffix').firstOrNull;

  ReleaseAsset? serverAsset(String? target) =>
      !serverTargets.containsKey(target)
      ? null
      : _asset('$target.${target!.startsWith('linux-') ? 'tar.gz' : 'zip'}');

  ReleaseAsset? appAsset(ClientInstallation? app) {
    if (app?.platform != 'android') return null;
    for (final abi in app!.abis) {
      if (!['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(abi)) continue;
      final asset = _asset('android-$abi.apk');
      if (asset != null) return asset;
    }
    return _asset('android-universal.apk');
  }
}
