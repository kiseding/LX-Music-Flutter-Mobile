import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/outbound_url_literal_scanner.dart';

void main() {
  const centralizedClients = [
    'lib/core/music_source/platform/music_platform.dart',
    'lib/features/playlist/domain/playlist_import_service.dart',
    'lib/core/audio/playback_cache_service.dart',
    'lib/features/download/domain/download_service.dart',
  ];

  test('production networking has no bad certificate callback', () {
    for (final file in _productionDartFiles()) {
      expect(
        file.readAsStringSync(),
        isNot(contains('badCertificateCallback')),
        reason: file.path,
      );
    }
  });

  test('production outbound URL literals use HTTPS', () {
    for (final file in _productionDartFiles()) {
      final insecure = staticallyKnownStrings(
        file.readAsStringSync(),
        path: file.path,
      ).where((literal) => literal.toLowerCase().contains('http://'));
      expect(insecure, isEmpty, reason: file.path);
    }
  });

  group('outbound URL literal scanner', () {
    test('detects adjacent and escaped HTTP literals', () {
      const source = r'''
final adjacent = 'http' '://example.com';
final hex = 'http\x3a//example.com';
final unicode = 'http\u003a//example.com';
final uppercase = 'HTTP://example.com';
''';

      expect(
        staticallyKnownStrings(source)
            .where((value) => value.toLowerCase().contains('http://')),
        hasLength(4),
      );
    });

    test('detects raw, triple, and statically interpolated HTTP literals', () {
      const source = r"""
final raw = r'http://example.com';
final triple = '''http://example.com''';
final interpolated = 'http${':'}//example.com';
final constInterpolated = '$protocol://example.com';
const protocol = scheme;
const scheme = 'http';
""";

      expect(
        staticallyKnownStrings(source)
            .where((value) => value.contains('http://')),
        hasLength(4),
      );
    });

    test('keeps a known insecure prefix before dynamic interpolation', () {
      const source = r'''
final url = 'http://$dynamicHost/path';
final unknownPrefix = '$dynamicScheme://example.com';
''';

      expect(
        staticallyKnownStrings(source)
            .where((value) => value.contains('http://')),
        ['http://'],
      );
    });

    test('ignores comments and secure literals', () {
      const source = r'''
// 'http://comment.example'
/* "http://comment.example" */
final secure = 'https://example.com';
''';

      expect(
        staticallyKnownStrings(source)
            .where((value) => value.contains('http://')),
        isEmpty,
      );
    });
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

List<File> _productionDartFiles() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}
