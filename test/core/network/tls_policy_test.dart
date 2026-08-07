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
      final insecure = _commonCleartextUrlForms(file.readAsStringSync());
      expect(insecure, isEmpty, reason: file.path);
    }
  });

  group('cleartext URL source scanner', () {
    test('detects direct, escaped, and simple concatenated forms', () {
      const source = r'''
final split = 'ht' + 'tp' + '://example.com';
final splitHex = 'ht' + 'tp' + '\x3a//example.com';
final splitUnicode = 'ht' + 'tp' + '\u003a//example.com';
final adjacent = 'http' '://example.com';
final hex = 'http\x3a//example.com';
final unicode = 'http\u003a//example.com';
final uppercase = 'HTTP://example.com';
''';

      expect(_commonCleartextUrlForms(source), hasLength(7));
    });

    test('does not claim to evaluate arbitrary Dart expressions', () {
      const source = r'''
final scheme = getScheme();
final dynamicUrl = '$scheme://example.com';
''';

      expect(_commonCleartextUrlForms(source), isEmpty);
    });
  });

  test('policy scanner has no analyzer dependency', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains(RegExp(r'^\s*analyzer:', multiLine: true))));
    expect(File('test/support/outbound_url_literal_scanner.dart').existsSync(),
        isFalse);
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

List<String> _commonCleartextUrlForms(String source) {
  // Defense in depth for common spellings only. Code review and static analysis
  // remain responsible for intentionally obfuscated source construction.
  final compact = _withoutComments(source).replaceAll(RegExp(r'\s+'), '');
  final matches = <String>[];
  final patterns = [
    RegExp(r'http://', caseSensitive: false),
    RegExp(r'http\\x3a//', caseSensitive: false),
    RegExp(r'http\\u003a//', caseSensitive: false),
    RegExp(r'''['"]ht['"]\+['"]tp['"]\+['"]://''', caseSensitive: false),
    RegExp(r'''['"]ht['"]\+['"]tp['"]\+['"]\\x3a//''', caseSensitive: false),
    RegExp(r'''['"]ht['"]\+['"]tp['"]\+['"]\\u003a//''', caseSensitive: false),
    RegExp(r'''['"]http['"]['"]://''', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    matches.addAll(pattern.allMatches(compact).map((match) => match.group(0)!));
  }
  return matches;
}

String _withoutComments(String source) {
  final output = StringBuffer();
  var index = 0;
  String? quote;
  var triple = false;
  while (index < source.length) {
    if (quote == null) {
      if (source.startsWith('//', index)) {
        final newline = source.indexOf('\n', index + 2);
        index = newline < 0 ? source.length : newline;
        continue;
      }
      if (source.startsWith('/*', index)) {
        final end = source.indexOf('*/', index + 2);
        index = end < 0 ? source.length : end + 2;
        continue;
      }
      if (source[index] == "'" || source[index] == '"') {
        quote = source[index];
        triple = source.startsWith('$quote$quote$quote', index);
      }
    } else if (!triple && source[index] == '\\') {
      output.write(source[index]);
      if (index + 1 < source.length) {
        output.write(source[index + 1]);
        index += 2;
        continue;
      }
    } else if (triple && source.startsWith('$quote$quote$quote', index)) {
      output.write('$quote$quote$quote');
      index += 3;
      quote = null;
      triple = false;
      continue;
    } else if (!triple && source[index] == quote) {
      quote = null;
    }
    output.write(source[index]);
    index++;
  }
  return output.toString();
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
