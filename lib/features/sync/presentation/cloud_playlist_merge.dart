import '../../player/domain/music_item.dart';
import '../../playlist/domain/playlist.dart';
import '../../playlist/domain/playlist_service.dart';

typedef CloudSongDecoder = MusicItem Function(Object? raw);

final class CloudPlaylistMergeResult {
  const CloudPlaylistMergeResult({
    required this.favoriteSongCount,
    required this.acceptedPlaylistCount,
    required this.playlists,
  });

  final int favoriteSongCount;
  final int acceptedPlaylistCount;
  final List<Playlist> playlists;
}

MusicItem decodeCloudSong(Object? raw) {
  if (raw is! Map) {
    throw FormatException('cloud song must be a map', raw);
  }
  final m = Map<String, dynamic>.from(raw);
  final source = m['source']?.toString() ?? '';
  final name = m['name']?.toString() ?? '';
  final singer = m['singer']?.toString() ?? '';
  final songmid = m['songmid']?.toString() ?? '';
  final hash = m['hash']?.toString() ?? '';

  if (source.isEmpty) {
    throw FormatException('cloud song source is required', raw);
  }
  if (name.isEmpty) {
    throw FormatException('cloud song name is required', raw);
  }
  if (singer.isEmpty) {
    throw FormatException('cloud song singer is required', raw);
  }
  if (songmid.isEmpty && hash.isEmpty) {
    throw FormatException('cloud song requires non-empty songmid or hash', raw);
  }

  final albumRaw = m['albumName'] ?? m['album'];
  if (albumRaw != null && albumRaw is! String) {
    throw FormatException('cloud song album must be a string', raw);
  }
  final artworkRaw = m['img'] ?? m['artwork'];
  if (artworkRaw != null && artworkRaw is! String) {
    throw FormatException('cloud song artwork must be a string', raw);
  }

  final mid = songmid.isNotEmpty ? songmid : hash;
  return MusicItem(
    id: mid,
    name: name,
    singer: singer,
    album: albumRaw is String ? albumRaw : '',
    source: source,
    platform: source,
    artwork: artworkRaw is String ? artworkRaw : null,
    songmid: mid,
    hash: hash.isNotEmpty ? hash : mid,
    meta: m,
  );
}

Future<CloudPlaylistMergeResult> mergeAndPersistCloudPlaylists({
  required PlaylistService service,
  required List love,
  required List userList,
  required CloudSongDecoder decodeSong,
  DateTime Function()? clock,
}) async {
  final favoriteSongs = <MusicItem>[
    for (var i = 0; i < love.length; i++)
      _decodeAt(decodeSong, love[i], 'love[$i]'),
  ];

  final candidates = <_CloudPlaylistCandidate>[];
  for (var i = 0; i < userList.length; i++) {
    final raw = userList[i];
    if (raw is! Map) {
      throw FormatException('user playlist at [$i] must be a map', raw);
    }
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty || const {'favorites', 'recent', 'love'}.contains(id)) {
      throw FormatException(
        'user playlist at [$i] has invalid or reserved id',
        raw,
      );
    }
    final name = raw['name']?.toString() ?? '';
    if (name.isEmpty) {
      throw FormatException('user playlist at [$i] name is required', raw);
    }
    final list = raw['list'];
    if (list is! List) {
      throw FormatException('user playlist at [$i] list must be a List', raw);
    }
    final songs = <MusicItem>[
      for (var j = 0; j < list.length; j++)
        _decodeAt(decodeSong, list[j], 'userList[$i].list[$j]'),
    ];
    candidates.add(_CloudPlaylistCandidate(id: id, name: name, songs: songs));
  }

  final now = clock ?? DateTime.now;
  final playlists = {
    for (final playlist in await service.getAllPlaylists())
      playlist.id: playlist,
  };
  final favorites = playlists['favorites'];
  final mergedFavoriteSongs = _mergeSongs(
    favorites?.songs ?? const [],
    favoriteSongs,
  );
  if (favorites != null) {
    playlists['favorites'] = favorites.copyWith(
      songs: List<MusicItem>.unmodifiable(mergedFavoriteSongs),
      updatedAt: now(),
    );
  }

  for (final candidate in candidates) {
    final existing = playlists[candidate.id];
    final timestamp = now();
    playlists[candidate.id] = existing != null
        ? existing.copyWith(
            songs: List<MusicItem>.unmodifiable(
              _mergeSongs(existing.songs, candidate.songs),
            ),
            updatedAt: timestamp,
          )
        : Playlist(
            id: candidate.id,
            name: candidate.name,
            description: '云端同步',
            songs: List<MusicItem>.unmodifiable(candidate.songs),
            createdAt: timestamp,
            updatedAt: timestamp,
          );
  }

  final merged = playlists.values.toList();
  await service.replaceAll(merged);
  return CloudPlaylistMergeResult(
    favoriteSongCount: mergedFavoriteSongs.length,
    acceptedPlaylistCount: candidates.length,
    playlists: merged,
  );
}

List<MusicItem> _mergeSongs(
  Iterable<MusicItem> local,
  Iterable<MusicItem> cloud,
) {
  final seen = <String>{};
  final result = <MusicItem>[];
  for (final song in [...local, ...cloud]) {
    final identity = _songIdentity(song);
    if (seen.add(identity)) result.add(song);
  }
  return List<MusicItem>.unmodifiable(result);
}

String _songIdentity(MusicItem song) {
  final id = song.songmid?.isNotEmpty == true
      ? song.songmid!
      : song.hash?.isNotEmpty == true
      ? song.hash!
      : song.id;
  return '${song.source}|$id';
}

Map<String, dynamic> encodeCloudSong(MusicItem song) {
  final songmid = song.songmid?.isNotEmpty == true
      ? song.songmid!
      : song.hash?.isNotEmpty == true
      ? song.hash!
      : song.id;
  return {
    'name': song.name,
    'singer': song.singer,
    'source': song.source,
    'songmid': songmid,
    'albumName': song.album,
    'img': song.artwork ?? '',
    'interval': song.duration.inSeconds.toString(),
    'hash': song.hash ?? songmid,
  };
}

List<Map<String, dynamic>> encodeCloudPlaylists(Iterable<Playlist> playlists) {
  return [
    for (final playlist in playlists)
      if (playlist.id != 'favorites' && playlist.id != 'recent')
        {
          'id': playlist.id,
          'name': playlist.name,
          'list': [for (final song in playlist.songs) encodeCloudSong(song)],
        },
  ];
}

MusicItem _decodeAt(CloudSongDecoder decodeSong, Object? raw, String path) {
  try {
    return decodeSong(raw);
  } on FormatException catch (e) {
    throw FormatException(
      'rejected cloud song at $path: ${e.message}',
      e.source,
    );
  }
}

final class _CloudPlaylistCandidate {
  const _CloudPlaylistCandidate({
    required this.id,
    required this.name,
    required this.songs,
  });

  final String id;
  final String name;
  final List<MusicItem> songs;
}
