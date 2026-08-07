import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';

void main() {
  test('qualityChain prefers requested quality then lower fallbacks', () {
    final chain320 = MusicSourceService.qualityChain('320k');
    expect(chain320, ['320k', '192k', '128k']);

    final chainFlac = MusicSourceService.qualityChain('flac');
    expect(chainFlac.first, 'flac');
    expect(chainFlac.indexOf('flac'), lessThan(chainFlac.indexOf('320k')));
    expect(chainFlac.indexOf('320k'), lessThan(chainFlac.indexOf('128k')));
    expect(chainFlac, isNot(contains('hires')));
    expect(chainFlac, isNot(contains('flac24bit')));
  });

  test('hires degrades through flac before 320k', () {
    final chain = MusicSourceService.qualityChain('hires');
    expect(chain, ['hires', 'flac24bit', 'flac', '320k', '192k', '128k']);
  });

  test('isQualityBelow detects downgrade', () {
    expect(MusicSourceService.isQualityBelow('320k', 'flac'), isTrue);
    expect(MusicSourceService.isQualityBelow('flac', 'flac'), isFalse);
    expect(MusicSourceService.isQualityBelow('flac', '320k'), isFalse);
  });

  test('quality chain contains no duplicate attempts', () {
    final chain = MusicSourceService.qualityChain('flac');
    expect(chain.toSet().length, chain.length);
  });
}
