import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const centralizedClients = [
    'lib/core/music_source/platform/music_platform.dart',
    'lib/features/playlist/domain/playlist_import_service.dart',
    'lib/core/audio/playback_cache_service.dart',
    'lib/features/download/domain/download_service.dart',
  ];

  test('production networking has no bad certificate callback', () {
    for (final path in [
      ...centralizedClients,
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('badCertificateCallback')),
        reason: path,
      );
    }
  });

  test('production clients use the centralized system-trust factory', () {
    for (final path in centralizedClients) {
      expect(
        File(path).readAsStringSync(),
        contains('AppHttpClient.create('),
        reason: path,
      );
    }
  });

  test('iOS transport security does not allow arbitrary loads', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('<key>NSAllowsArbitraryLoads</key>')));
  });
}
