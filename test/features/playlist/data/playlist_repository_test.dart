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

    test('deeply copies and freezes constructor song meta', () {
      final nested = <String, dynamic>{'number': 1};
      final tags = <dynamic>['one', <String, dynamic>{'value': 'two'}];
      final meta = <String, dynamic>{'nested': nested, 'tags': tags};
      final snapshot = PlaylistSnapshot(
        schemaVersion: 1,
        playlists: [playlistFixture(songs: [songFixture(meta: meta)])],
      );

      meta['new'] = true;
      nested['number'] = 2;
      (tags[1] as Map<String, dynamic>)['value'] = 'changed';

      final stored = snapshot.playlists.single.songs.single.meta!;
      expect(stored, {
        'nested': {'number': 1},
        'tags': ['one', {'value': 'two'}],
      });
      expect(() => stored['new'] = true, throwsUnsupportedError);
      expect(() => (stored['nested'] as Map<String, dynamic>)['number'] = 2,
          throwsUnsupportedError);
      expect(() => (stored['tags'] as List<dynamic>).add('three'),
          throwsUnsupportedError);
    });

    test('rejects non-JSON constructor meta at its field path', () {
      expectFormatException(
        () => PlaylistSnapshot(
          schemaVersion: 1,
          playlists: [
            playlistFixture(
              songs: [songFixture(meta: {'nested': DateTime.utc(2026)})],
            ),
          ],
        ),
        'playlists[0].songs[0].meta.nested',
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

    test('deeply freezes decoded song meta', () {
      final decoded = codec.decode(jsonEncode({
        'schemaVersion': 1,
        'playlists': [
          playlistJson('one', songs: [songJson()])
        ],
      }));
      final meta = decoded.playlists.single.songs.single.meta!;

      expect(() => meta['new'] = true, throwsUnsupportedError);
      expect(() => (meta['nested'] as Map<String, dynamic>)['number'] = 2,
          throwsUnsupportedError);
      expect(() => (meta['tags'] as List<dynamic>).add('three'),
          throwsUnsupportedError);
      expect(meta, {
        'nested': {'number': 1},
        'tags': ['one', 'two'],
      });
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

    test('decoder accepts duplicate playlist names when ids differ', () {
      final first = playlistJson('first')..['name'] = 'Same name';
      final second = playlistJson('second')..['name'] = 'Same name';

      final snapshot = codec.decode(jsonEncode({
        'schemaVersion': 1,
        'playlists': [first, second],
      }));

      expect(snapshot.playlists.map((playlist) => playlist.id),
          ['first', 'second']);
      expect(snapshot.playlists.map((playlist) => playlist.name),
          ['Same name', 'Same name']);
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

MusicItem songFixture({Map<String, dynamic>? meta}) {
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
    meta: meta ??
        {
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
