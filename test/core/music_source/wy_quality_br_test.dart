import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WySource maps flac24bit/hires to high bitrate', () {
    final source = File('lib/core/music_source/platform/wy_source.dart')
        .readAsStringSync();
    expect(source, contains("'hires' || 'flac24bit' || 'flac' => 999000"));
  });
}
