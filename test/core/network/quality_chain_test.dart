import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';

void main() {
  test('qualityChain prefers requested quality then fallbacks', () {
    final chain = MusicSourceService.qualityChain('320k');
    expect(chain.first, '320k');
    expect(chain, contains('128k'));
    expect(chain.toSet().length, chain.length);
  });
}
