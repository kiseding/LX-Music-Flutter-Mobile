import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playlist more menu can add every song to favorites', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_detail_screen.dart',
    ).readAsStringSync();

    expect(source, contains("case 'add_all_to_favorites':"));
    expect(source, contains("value: 'add_all_to_favorites'"));
    expect(source, contains('全部添加到我喜欢的音乐'));
    expect(source, contains('addAllSongsToFavorites(playlist.id)'));
    expect(source, contains("playlist.id != 'favorites'"));
  });
}
