import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main resolver grants exclusivity only to playback generations', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('exclusive: resolutionGeneration is int'));
    expect(source, isNot(contains('mediaItem.value?.id == mediaId;')));
  });
}
