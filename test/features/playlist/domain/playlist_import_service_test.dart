import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist_import_service.dart';

void main() {
  test('QQ playlist import preserves media_mid for playback URL lookup', () {
    expect(
      PlaylistImportService.txMediaMid({'strMediaMid': 'preferred'}),
      'preferred',
    );
    expect(
      PlaylistImportService.txMediaMid({
        'file': {'media_mid': 'legacy'},
      }),
      'legacy',
    );
    expect(PlaylistImportService.txMediaMid({}), isEmpty);
  });
}
