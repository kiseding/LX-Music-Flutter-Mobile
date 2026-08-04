import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/lx_source_capabilities.dart';

void main() {
  test('keeps local declarations and rejects undeclared music qualities', () {
    final capabilities = LxSourceCapabilities.fromInitData({
      'sources': {
        'local': {
          'actions': ['lyric']
        },
        'tx': {
          'musicUrl': true,
          'qualitys': ['128k', '320k', 'unsupported']
        },
      },
    });

    expect(capabilities.supports('local', 'lyric'), isTrue);
    expect(capabilities.supports('tx', 'musicUrl', '320k'), isTrue);
    expect(capabilities.supports('tx', 'musicUrl', 'flac'), isFalse);
    expect(capabilities.supports('tx', 'musicUrl'), isTrue);
  });

  test('musicUrl without qualitys allows any official quality', () {
    final capabilities = LxSourceCapabilities.fromInitData({
      'sources': {
        'tx': {
          'musicUrl': true,
        },
      },
    });
    expect(capabilities.supports('tx', 'musicUrl', 'flac'), isTrue);
    expect(capabilities.supports('tx', 'musicUrl', '320k'), isTrue);
  });

  test('effectiveQuality falls back to the best declared quality', () {
    final capabilities = LxSourceCapabilities.fromInitData({
      'sources': {
        'tx': {
          'actions': ['musicUrl'],
          'qualitys': ['128k', '320k'],
        },
      },
    });

    expect(capabilities.effectiveQuality('tx', 'musicUrl', 'flac'), '320k');
    expect(capabilities.effectiveQuality('tx', 'musicUrl', '192k'), '128k');
    expect(capabilities.effectiveQuality('tx', 'musicUrl', '128k'), '128k');
  });

  test('only media retrieval actions require a capability declaration', () {
    expect(LxSourceCapabilities.requiresDeclaration('musicUrl'), isTrue);
    expect(LxSourceCapabilities.requiresDeclaration('lyric'), isTrue);
    expect(LxSourceCapabilities.requiresDeclaration('pic'), isTrue);

    expect(LxSourceCapabilities.requiresDeclaration('search'), isFalse);
    expect(LxSourceCapabilities.requiresDeclaration('songListDetail'), isFalse);
  });
}
