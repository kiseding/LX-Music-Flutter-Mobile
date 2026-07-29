import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';

void main() {
  group('PlaylistSnapshot', () {
    test('accepts only schema version 1', () {
      expect(
        () => PlaylistSnapshot(schemaVersion: 2, playlists: const []),
        throwsFormatException,
      );
    });

    test('exposes an immutable playlist list', () {
      final snapshot = PlaylistSnapshot(
        schemaVersion: 1,
        playlists: [playlistFixture()],
      );

      expect(
        () => snapshot.playlists.add(playlistFixture(id: 'two')),
        throwsUnsupportedError,
      );
    });

    test('exposes immutable song lists', () {
      final snapshot = PlaylistSnapshot(
        schemaVersion: 1,
        playlists: [playlistFixture()],
      );

      expect(
        () => snapshot.playlists.single.songs.add(songFixture()),
        throwsUnsupportedError,
      );
    });
  });

  group('PlaylistSnapshotCodec', () {
    const codec = PlaylistSnapshotCodec();

    test('version 1 snapshot round trips every MusicItem field', () {
      final original = PlaylistSnapshot(
        schemaVersion: 1,
        playlists: [playlistFixture()],
      );

      final decoded = codec.decode(codec.encode(original));

      expect(decoded.schemaVersion, 1);
      expect(
        decoded.playlists.single.songs.single.toJson(),
        original.playlists.single.songs.single.toJson(),
      );
      expect(decoded.playlists.single.createdAt, playlistFixture().createdAt);
      expect(decoded.playlists.single.updatedAt, playlistFixture().updatedAt);
    });

    test('encodes the exact version 1 envelope', () {
      final encoded = jsonDecode(codec.encode(PlaylistSnapshot(
        schemaVersion: 1,
        playlists: [playlistFixture(id: 'favorites', songs: const [])],
      )));

      expect(encoded, {
        'schemaVersion': 1,
        'playlists': [playlistJson('favorites')],
      });
    });

    test('decoded snapshot and song lists are immutable', () {
      final decoded = codec.decode(jsonEncode({
        'schemaVersion': 1,
        'playlists': [
          playlistJson('one', songs: [songJson()])
        ],
      }));

      expect(
        () => decoded.playlists.add(playlistFixture(id: 'two')),
        throwsUnsupportedError,
      );
      expect(
        () => decoded.playlists.single.songs.add(songFixture()),
        throwsUnsupportedError,
      );
    });

    test('decoder rejects unknown version at schemaVersion', () {
      expectFormatException(
        () => codec.decode('{"schemaVersion":2,"playlists":[]}'),
        'schemaVersion',
      );
    });

    test('decoder rejects duplicate playlist ids at playlists[1].id', () {
      expectFormatException(
        () => codec.decode(jsonEncode({
          'schemaVersion': 1,
          'playlists': [playlistJson('same'), playlistJson('same')],
        })),
        'playlists[1].id',
      );
    });

    test('decoder rejects empty playlist names at playlists[0].name', () {
      final playlist = playlistJson('one')..['name'] = '';

      expectFormatException(
        () => codec.decode(jsonEncode({
          'schemaVersion': 1,
          'playlists': [playlist],
        })),
        'playlists[0].name',
      );
    });

    test('decoder rejects malformed dates at playlists[0].createdAt', () {
      final playlist = playlistJson('one')..['createdAt'] = 'not-an-int';

      expectFormatException(
        () => codec.decode(jsonEncode({
          'schemaVersion': 1,
          'playlists': [playlist],
        })),
        'playlists[0].createdAt',
      );
    });

    test('decoder rejects invalid duration at playlists[0].songs[0].duration',
        () {
      final song = songJson()..['duration'] = -1;

      expectFormatException(
        () => codec.decode(jsonEncode({
          'schemaVersion': 1,
          'playlists': [
            playlistJson('one', songs: [song])
          ],
        })),
        'playlists[0].songs[0].duration',
      );
    });

    test(
        'decoder rejects a missing song source at playlists[0].songs[0].source',
        () {
      final song = songJson()..remove('source');

      expectFormatException(
        () => codec.decode(jsonEncode({
          'schemaVersion': 1,
          'playlists': [
            playlistJson('one', songs: [song])
          ],
        })),
        'playlists[0].songs[0].source',
      );
    });
  });
}

void expectFormatException(void Function() action, String path) {
  expect(
    action,
    throwsA(isA<FormatException>()
        .having((error) => error.message, 'message', contains(path))),
  );
}

Playlist playlistFixture({String id = 'one', List<MusicItem>? songs}) {
  return Playlist(
    id: id,
    name: 'Fixture playlist',
    description: 'A complete fixture',
    coverUrl: 'https://example.com/cover.jpg',
    songs: songs ?? [songFixture()],
    createdAt: DateTime.fromMillisecondsSinceEpoch(1785283200000, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1785369600000, isUtc: true),
  );
}

MusicItem songFixture() {
  return MusicItem(
    id: 'song-id',
    name: 'Song name',
    singer: 'Singer name',
    album: 'Album name',
    duration: const Duration(minutes: 3, seconds: 21),
    source: 'source-id',
    platform: 'tx',
    artwork: 'https://example.com/artwork.jpg',
    url: 'https://example.com/song.mp3',
    lyricsUrl: 'https://example.com/song.lrc',
    isPlayable: false,
    songmid: 'song-mid',
    hash: 'song-hash',
    meta: {
      'nested': {'number': 1},
      'tags': ['one', 'two'],
    },
  );
}

Map<String, dynamic> playlistJson(String id,
    {List<Map<String, dynamic>> songs = const []}) {
  return {
    'id': id,
    'name': 'Fixture playlist',
    'description': 'A complete fixture',
    'coverUrl': 'https://example.com/cover.jpg',
    'songs': songs,
    'createdAt': 1785283200000,
    'updatedAt': 1785369600000,
  };
}

Map<String, dynamic> songJson() => songFixture().toJson();
