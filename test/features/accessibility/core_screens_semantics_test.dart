import 'dart:io';

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/pressable.dart';

void main() {
  testWidgets('selected destination is a keyboard-operable button',
      (tester) async {
    var activated = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Pressable(
      semanticLabel: '歌单',
      selected: true,
      onTap: () => activated++,
      child: const Text('歌单'),
    ))));

    final node = tester.getSemantics(find.bySemanticsLabel('歌单'));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    await tester.tap(find.bySemanticsLabel('歌单'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated, 2);
  });

  testWidgets('settings binary control uses native switch semantics',
      (tester) async {
    var value = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, setState) => Row(
        children: [
          const Text('仅 WiFi 下载'),
          Switch(
            value: value,
            onChanged: (next) => setState(() => value = next),
          ),
        ],
      ),
    ))));
    final node = tester.getSemantics(find.byType(Switch));
    expect(node.flagsCollection.isToggled, isNot(Tristate.none));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(value, isTrue);
  });

  test('core helper bodies no longer contain gesture-only commands', () {
    final checks = <(String, String, String)>[
      (
        'lib/features/settings/presentation/settings_screen.dart',
        'Widget _buildSwitchTile(',
        'String _getQualityName(',
      ),
      (
        'lib/features/playlist/presentation/playlist_screen.dart',
        'Widget _buildFavoritesCard(',
        'Widget _buildPlaylistItem(',
      ),
      (
        'lib/features/download/presentation/download_screen.dart',
        'Widget _buildProgressCard(',
        'Color _getThumbColor(',
      ),
      (
        'lib/features/lyric/presentation/lyric_view.dart',
        'Widget _buildStatusState(',
        'Future<void> _retryLyric(',
      ),
      (
        'lib/features/player/presentation/player_screen.dart',
        'Widget _buildAppBar(',
        'Widget _buildPageIndicator(',
      ),
      (
        'lib/features/player/presentation/widgets/mini_player.dart',
        'padding: const EdgeInsets.fromLTRB(12, 0, 6, 6)',
        'width: 128,',
      ),
    ];

    for (final (path, start, end) in checks) {
      final source = File(path).readAsStringSync();
      final body = source.substring(source.indexOf(start), source.indexOf(end));
      expect(body, isNot(contains('GestureDetector(')), reason: path);
    }
  });
}
