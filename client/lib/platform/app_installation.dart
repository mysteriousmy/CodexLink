import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/release_info.dart';

Future<ClientInstallation> readClientInstallation() async {
  if (kIsWeb) {
    return const ClientInstallation(
      version: compiledClientVersion,
      platform: 'web',
    );
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    final info = await const MethodChannel('codexlink/app_info')
        .invokeMapMethod<String, dynamic>('read');
    final version = info?['version'] as String?;
    if (parseVersion(version) == null) throw StateError('无法读取 App 版本');
    return ClientInstallation(
      version: version!,
      platform: 'android',
      abis: (info?['supportedAbis'] as List? ?? [])
          .whereType<String>()
          .toList(),
    );
  }
  return ClientInstallation(
    version: compiledClientVersion,
    platform: defaultTargetPlatform.name,
  );
}
