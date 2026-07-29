import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/settings/domain/playlist_backup.dart';

void main() {
  final now = DateTime.utc(2026);
  final playlist = Playlist(
    id: 'one',
    name: 'One',
    createdAt: now,
    updatedAt: now,
  );
  final snapshotObject = jsonDecode(
    const PlaylistSnapshotCodec().encode(
      PlaylistSnapshot(schemaVersion: 1, playlists: [playlist]),
    ),
  );

  test('decodes legacy version 1 backup playlist list through strict codec',
      () {
    final decoded = decodeBackupPlaylists({
      'version': 1,
      'playlists': snapshotObject['playlists'],
    });

    expect(decoded.playlists.single.id, 'one');
  });

  test('decodes new version 1 backup strict snapshot object', () {
    final decoded = decodeBackupPlaylists({
      'version': 1,
      'playlists': snapshotObject,
    });

    expect(decoded.playlists.single.name, 'One');
  });

  test('restore requires a non-null playlists field before replacement',
      () async {
    for (final backup in <Map<String, dynamic>>[
      {'version': 1},
      {'version': 1, 'playlists': null},
    ]) {
      var replacements = 0;

      await expectLater(
        restoreBackupPlaylists(backup, (_) async => replacements++),
        throwsFormatException,
      );
      expect(replacements, 0);
    }
  });

  test('restore strictly decodes each version 1 shape then replaces once',
      () async {
    for (final playlists in <Object>[
      snapshotObject['playlists'] as Object,
      snapshotObject as Object,
    ]) {
      final replacements = <List<Playlist>>[];

      await restoreBackupPlaylists(
        {'version': 1, 'playlists': playlists},
        (value) async => replacements.add(value),
      );

      expect(replacements, hasLength(1));
      expect(replacements.single.single.id, 'one');
    }
  });

  test('rejects malformed legacy playlist instead of permissive migration', () {
    expect(
      () => decodeBackupPlaylists({
        'version': 1,
        'playlists': [
          {'id': 'one', 'name': 'One'}
        ],
      }),
      throwsFormatException,
    );
  });

  test('rejects malformed new snapshot and unsupported outer version', () {
    expect(
      () => decodeBackupPlaylists({
        'version': 1,
        'playlists': {
          'schemaVersion': 1,
          'playlists': snapshotObject['playlists'],
          'extra': true,
        },
      }),
      throwsFormatException,
    );
    expect(
      () => decodeBackupPlaylists({
        'version': 2,
        'playlists': snapshotObject,
      }),
      throwsFormatException,
    );
  });
}
