import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto-next on complete uses seamless skip without pause', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('skipToNext(seamless: true)'));
    expect(
        source, contains('Future<void> skipToNext({bool seamless = false})'));
    expect(
      source,
      contains('skipToQueueItem(int index, {bool seamless = false})'),
    );
    // 拖进度 pause 不清除播放意图
    expect(source, contains('pauseInternal({bool clearIntent = true})'));
  });
}
