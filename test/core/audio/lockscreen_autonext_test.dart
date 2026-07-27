import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto-next on complete uses seamless skip without pause', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    // 自动连播必须 seamless，避免锁屏 pause 杀会话
    expect(source, contains('skipToNext(seamless: true)'));
    expect(
        source, contains('Future<void> skipToNext({bool seamless = false})'));
    expect(source,
        contains('skipToQueueItem(int index, {bool seamless = false})'));
    // 完成处理不再强制 delay 80ms 再检查 processingState
    expect(
      source.contains(
        'await Future<void>.delayed(const Duration(milliseconds: 80));\n'
        '          if (_isStale(gen) || _suppressAutoAdvance > 0) return;\n'
        '          if (!_userWantsPlay) return;\n'
        '          if (_player.processingState != ProcessingState.completed) return;',
      ),
      isFalse,
    );
    // 有接近结尾的 position 兜底
    expect(source, contains('milliseconds: 400'));
  });
}
