import 'dart:convert';

import '../../player/domain/music_item.dart';
import '../domain/playlist.dart';

final class PlaylistSnapshot {
  PlaylistSnapshot({
    required this.schemaVersion,
    required List<Playlist> playlists,
  }) : playlists = _copyPlaylists(schemaVersion, playlists) {
    if (schemaVersion != 1) {
      throw const FormatException('schemaVersion must be 1');
    }
  }

  final int schemaVersion;
  final List<Playlist> playlists;

  static List<Playlist> _copyPlaylists(
    int schemaVersion,
    List<Playlist> playlists,
  ) {
    if (schemaVersion != 1) {
      throw const FormatException('schemaVersion must be 1');
    }
    return List.unmodifiable([
      for (var playlistIndex = 0;
          playlistIndex < playlists.length;
          playlistIndex++)
        playlists[playlistIndex].copyWith(
          songs: List.unmodifiable([
            for (var songIndex = 0;
                songIndex < playlists[playlistIndex].songs.length;
                songIndex++)
              _copySong(
                playlists[playlistIndex].songs[songIndex],
                'playlists[$playlistIndex].songs[$songIndex].meta',
              ),
          ]),
          songCount: playlists[playlistIndex].songCount,
        ),
    ]);
  }

  static MusicItem _copySong(MusicItem song, String metaPath) {
    return MusicItem(
      id: song.id,
      name: song.name,
      singer: song.singer,
      album: song.album,
      duration: song.duration,
      source: song.source,
      platform: song.platform,
      artwork: song.artwork,
      url: song.url,
      lyricsUrl: song.lyricsUrl,
      isPlayable: song.isPlayable,
      songmid: song.songmid,
      hash: song.hash,
      meta: song.meta == null
          ? null
          : _copyJsonObject(song.meta!, metaPath),
    );
  }

  static Map<String, dynamic> _copyJsonObject(Map value, String path) {
    final copy = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$path must use string keys');
      }
      copy[entry.key as String] = _copyJsonValue(entry.value, '$path.${entry.key}');
    }
    return Map.unmodifiable(copy);
  }

  static dynamic _copyJsonValue(dynamic value, String path) {
    if (value == null || value is String || value is bool) return value;
    if (value is num && value.isFinite) return value;
    if (value is List) {
      return List.unmodifiable([
        for (var index = 0; index < value.length; index++)
          _copyJsonValue(value[index], '$path[$index]'),
      ]);
    }
    if (value is Map) return _copyJsonObject(value, path);
    throw FormatException('$path must be a JSON value');
  }
}

abstract interface class PlaylistRepository {
  Future<PlaylistSnapshot> load();
  Future<void> save(PlaylistSnapshot snapshot);
}

final class PlaylistSongPage {
  PlaylistSongPage({
    required this.total,
    required this.offset,
    required List<MusicItem> songs,
  }) : songs = List.unmodifiable(songs) {
    if (total < 0 || offset < 0 || offset > total) {
      throw ArgumentError('Invalid playlist song page range');
    }
    if (this.songs.length > total - offset) {
      throw ArgumentError('Page songs exceed the available range');
    }
  }

  final int total;
  final int offset;
  final List<MusicItem> songs;
}

abstract interface class PlaylistSongPageRepository {
  Future<PlaylistSongPage> loadSongsPage(
    String playlistId, {
    required int offset,
    required int limit,
  });

  Future<List<MusicItem>> loadAllSongs(String playlistId);
}

final class PlaylistSnapshotCodec {
  const PlaylistSnapshotCodec();

  String encode(PlaylistSnapshot snapshot) {
    if (snapshot.schemaVersion != 1) {
      throw const FormatException('schemaVersion must be 1');
    }

    final ids = <String>{};
    return jsonEncode({
      'schemaVersion': 1,
      'playlists': List.unmodifiable([
        for (var index = 0; index < snapshot.playlists.length; index++)
          _encodePlaylist(snapshot.playlists[index], index, ids),
      ]),
    });
  }

  PlaylistSnapshot decode(String source) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('root: ${error.message}');
    }
    final root = _object(decoded, 'root');
    _onlyKeys(root, const {'schemaVersion', 'playlists'}, 'root');
    if (_integer(root['schemaVersion'], 'schemaVersion') != 1) {
      throw const FormatException('schemaVersion must be 1');
    }

    final values = _list(root['playlists'], 'playlists');
    final ids = <String>{};
    final playlists = <Playlist>[];
    for (var index = 0; index < values.length; index++) {
      playlists.add(_decodePlaylist(values[index], 'playlists[$index]', ids));
    }
    return PlaylistSnapshot(schemaVersion: 1, playlists: playlists);
  }

  Map<String, dynamic> _encodePlaylist(
    Playlist playlist,
    int index,
    Set<String> ids,
  ) {
    final path = 'playlists[$index]';
    _uniqueNonEmpty(playlist.id, '$path.id', ids);
    _nonEmpty(playlist.name, '$path.name');
    _timestamp(playlist.createdAt, '$path.createdAt');
    _timestamp(playlist.updatedAt, '$path.updatedAt');
    if (playlist.songs.length != playlist.songCount) {
      throw FormatException('$path songs must be loaded before encoding');
    }
    return {
      'id': playlist.id,
      'name': playlist.name,
      'description': playlist.description,
      'coverUrl': playlist.coverUrl,
      'songs': List.unmodifiable([
        for (var songIndex = 0; songIndex < playlist.songs.length; songIndex++)
          _encodeSong(playlist.songs[songIndex], '$path.songs[$songIndex]'),
      ]),
      'createdAt': playlist.createdAt.millisecondsSinceEpoch,
      'updatedAt': playlist.updatedAt.millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> _encodeSong(MusicItem song, String path) {
    _nonEmpty(song.id, '$path.id');
    _nonEmpty(song.name, '$path.name');
    _nonEmpty(song.singer, '$path.singer');
    _nonEmpty(song.source, '$path.source');
    if (song.duration.isNegative) {
      throw FormatException('$path.duration must be a non-negative integer');
    }
    return song.toJson();
  }

  Playlist _decodePlaylist(
    dynamic value,
    String path,
    Set<String> ids,
  ) {
    final json = _object(value, path);
    _onlyKeys(json, _playlistKeys, path);
    final id = _nonEmpty(_string(json['id'], '$path.id'), '$path.id');
    final name = _nonEmpty(_string(json['name'], '$path.name'), '$path.name');
    _unique(id, '$path.id', ids);
    _nonEmpty(name, '$path.name');
    final songs = _list(json['songs'], '$path.songs');

    return Playlist(
      id: id,
      name: name,
      description: _nullableString(json['description'], '$path.description'),
      coverUrl: _nullableString(json['coverUrl'], '$path.coverUrl'),
      songs: List.unmodifiable([
        for (var index = 0; index < songs.length; index++)
          _decodeSong(songs[index], '$path.songs[$index]'),
      ]),
      createdAt: _date(json['createdAt'], '$path.createdAt'),
      updatedAt: _date(json['updatedAt'], '$path.updatedAt'),
    );
  }

  MusicItem _decodeSong(dynamic value, String path) {
    final json = _object(value, path);
    _onlyKeys(json, _songKeys, path);
    final id = _nonEmpty(_string(json['id'], '$path.id'), '$path.id');
    final name = _nonEmpty(_string(json['name'], '$path.name'), '$path.name');
    final singer =
        _nonEmpty(_string(json['singer'], '$path.singer'), '$path.singer');
    final source =
        _nonEmpty(_string(json['source'], '$path.source'), '$path.source');
    final duration = _integer(json['duration'], '$path.duration');
    if (duration < 0) {
      throw FormatException('$path.duration must be a non-negative integer');
    }

    final validated = <String, dynamic>{
      'id': id,
      'name': name,
      'singer': singer,
      'source': source,
      'duration': duration,
    };
    _copyOptionalString(json, validated, 'album', path);
    _copyOptionalString(json, validated, 'platform', path);
    _copyOptionalString(json, validated, 'artwork', path);
    _copyOptionalString(json, validated, 'url', path);
    _copyOptionalString(json, validated, 'lyricsUrl', path);
    _copyOptionalString(json, validated, 'songmid', path);
    _copyOptionalString(json, validated, 'hash', path);
    if (json.containsKey('isPlayable')) {
      if (json['isPlayable'] is! bool) {
        throw FormatException('$path.isPlayable must be a boolean');
      }
      validated['isPlayable'] = json['isPlayable'];
    }
    if (json.containsKey('meta')) {
      if (json['meta'] != null && json['meta'] is! Map) {
        throw FormatException('$path.meta must be an object or null');
      }
      if (json['meta'] != null) {
        validated['meta'] = _jsonObject(json['meta'], '$path.meta');
      }
    }
    return MusicItem.fromJson(validated);
  }

  void _copyOptionalString(
    Map<String, dynamic> source,
    Map<String, dynamic> destination,
    String key,
    String path,
  ) {
    if (!source.containsKey(key)) return;
    destination[key] = _nullableString(source[key], '$path.$key');
  }

  DateTime _date(dynamic value, String path) {
    final milliseconds = _integer(value, path);
    try {
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    } on ArgumentError {
      throw FormatException('$path must be a valid millisecond timestamp');
    }
  }

  int _timestamp(DateTime value, String path) {
    try {
      return value.millisecondsSinceEpoch;
    } on ArgumentError {
      throw FormatException('$path must be a valid millisecond timestamp');
    }
  }

  Map<String, dynamic> _object(dynamic value, String path) {
    if (value is! Map) throw FormatException('$path must be an object');
    if (value.keys.any((key) => key is! String)) {
      throw FormatException('$path must use string keys');
    }
    return Map<String, dynamic>.from(value);
  }

  Map<String, dynamic> _jsonObject(dynamic value, String path) {
    final object = _object(value, path);
    for (final entry in object.entries) {
      _jsonValue(entry.value, '$path.${entry.key}');
    }
    return object;
  }

  void _jsonValue(dynamic value, String path) {
    if (value == null || value is String || value is bool || value is num) {
      return;
    }
    if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _jsonValue(value[index], '$path[$index]');
      }
      return;
    }
    if (value is Map) {
      _jsonObject(value, path);
      return;
    }
    throw FormatException('$path must be a JSON value');
  }

  List<dynamic> _list(dynamic value, String path) {
    if (value is! List) throw FormatException('$path must be a list');
    return value;
  }

  String _string(dynamic value, String path) {
    if (value is! String) throw FormatException('$path must be a string');
    return value;
  }

  String? _nullableString(dynamic value, String path) {
    if (value != null && value is! String) {
      throw FormatException('$path must be a string or null');
    }
    return value as String?;
  }

  int _integer(dynamic value, String path) {
    if (value is! int) throw FormatException('$path must be an integer');
    return value;
  }

  String _nonEmpty(String value, String path) {
    if (value.trim().isEmpty) throw FormatException('$path must be non-empty');
    return value;
  }

  void _uniqueNonEmpty(String value, String path, Set<String> values) {
    _nonEmpty(value, path);
    _unique(value, path, values);
  }

  void _unique(String value, String path, Set<String> values) {
    if (!values.add(value)) throw FormatException('$path must be unique');
  }

  void _onlyKeys(Map<String, dynamic> value, Set<String> allowed, String path) {
    for (final key in value.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('$path.$key is not supported');
      }
    }
  }

  static const _playlistKeys = {
    'id',
    'name',
    'description',
    'coverUrl',
    'songs',
    'createdAt',
    'updatedAt',
  };
  static const _songKeys = {
    'id',
    'name',
    'singer',
    'album',
    'duration',
    'source',
    'platform',
    'artwork',
    'url',
    'lyricsUrl',
    'isPlayable',
    'songmid',
    'hash',
    'meta',
  };
}
