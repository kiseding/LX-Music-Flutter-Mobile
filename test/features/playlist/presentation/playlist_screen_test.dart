import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playlist screen does not resize for the keyboard', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_screen.dart',
    ).readAsStringSync();

    expect(source, contains('resizeToAvoidBottomInset: false'));
  });
}
