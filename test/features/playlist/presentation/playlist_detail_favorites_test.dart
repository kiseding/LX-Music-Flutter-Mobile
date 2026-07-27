import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playlist list more menu uses center dialog and can add favorites', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_screen.dart',
    ).readAsStringSync();
    final more = source.substring(
      source.indexOf('void _showPlaylistMoreMenu('),
    );

    expect(more, contains('showDialog<void>'));
    expect(more, contains('Dialog('));
    expect(more, contains('BorderRadius.circular(20)'));
    expect(more, contains('maxHeight: maxH'));
    expect(more, contains('全部添加到我喜欢的音乐'));
    expect(more, contains('addAllSongsToFavorites(playlist.id)'));
    expect(more, isNot(contains('showModalBottomSheet')));
  });

  test('playlist detail more menu does not host bulk favorites action', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_detail_screen.dart',
    ).readAsStringSync();
    expect(source, isNot(contains("case 'add_all_to_favorites':")));
    expect(source, isNot(contains('全部添加到我喜欢的音乐')));
  });
}
