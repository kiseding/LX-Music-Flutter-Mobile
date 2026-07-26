import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/lx_source_capabilities.dart';

void main() {
  test('music URL quality is dispatched only when the source declared it', () {
    final capabilities = LxSourceCapabilities.fromInitData({
      'sources': {
        'kw': {
          'musicUrl': true,
          'qualitys': ['128k', '320k']
        },
      },
    });

    expect(capabilities.supports('kw', 'musicUrl', '320k'), isTrue);
    expect(capabilities.supports('kw', 'musicUrl', '128k'), isTrue);
    expect(capabilities.supports('kw', 'musicUrl', 'flac'), isFalse);
  });
}
