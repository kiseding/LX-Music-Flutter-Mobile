import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playlist screen does not resize for the keyboard', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_screen.dart',
    ).readAsStringSync();

    expect(source, contains('resizeToAvoidBottomInset: false'));
  });

  test('import dialog guards local state after every async dismissal path', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_screen.dart',
    ).readAsStringSync();
    final importDialog = source.substring(
      source.indexOf('Future<void> _showImportDialog('),
      source.indexOf('void _showPlaylistMoreMenu('),
    );

    expect(
      RegExp(r'if \(!ctx\.mounted\) return;\s+setLocal\(\(\) => busy = false\)')
          .hasMatch(importDialog),
      isTrue,
    );
    expect(
      RegExp(r'catch \(e\) \{\s+if \(!ctx\.mounted\) return;\s+setLocal')
          .hasMatch(importDialog),
      isTrue,
    );
  });
}
