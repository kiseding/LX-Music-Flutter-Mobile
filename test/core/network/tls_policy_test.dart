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
      final insecure = _quotedLiterals(file.readAsStringSync())
          .where((literal) => literal.contains('http://'));
      expect(insecure, isEmpty, reason: file.path);
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

List<File> _productionDartFiles() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Iterable<String> _quotedLiterals(String source) sync* {
  var index = 0;
  while (index < source.length) {
    if (source.startsWith('//', index)) {
      final newline = source.indexOf('\n', index + 2);
      index = newline < 0 ? source.length : newline + 1;
      continue;
    }
    if (source.startsWith('/*', index)) {
      final end = source.indexOf('*/', index + 2);
      index = end < 0 ? source.length : end + 2;
      continue;
    }

    final quote = source[index];
    if (quote != "'" && quote != '"') {
      index++;
      continue;
    }

    final tripleQuote = '$quote$quote$quote';
    final triple = source.startsWith(tripleQuote, index);
    final delimiter = triple ? tripleQuote : quote;
    final start = index + delimiter.length;
    index = start;
    while (index < source.length) {
      if (!triple && source[index] == '\\') {
        index += 2;
        continue;
      }
      if (source.startsWith(delimiter, index)) {
        yield source.substring(start, index);
        index += delimiter.length;
        break;
      }
      index++;
    }
  }
}
