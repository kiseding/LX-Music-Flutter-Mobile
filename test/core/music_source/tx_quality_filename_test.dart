import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TxSource maps quality to correct filename prefixes', () {
    final source = File('lib/core/music_source/platform/tx_source.dart')
        .readAsStringSync();
    expect(source, contains("case '320k':"));
    expect(source, contains('M800'));
    expect(source, contains('F000'));
    expect(source, isNot(contains("final filename = 'C400\$songmid.m4a';")));
  });
}
