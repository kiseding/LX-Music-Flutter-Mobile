import '../../player/domain/music_item.dart';
import '../../playlist/domain/playlist.dart';
import '../../playlist/domain/playlist_service.dart';

typedef CloudSongDecoder = MusicItem? Function(dynamic raw);

final class CloudPlaylistMergeResult {
  const CloudPlaylistMergeResult({
    required this.favoriteSongCount,
    required this.acceptedPlaylistCount,
  });

  final int favoriteSongCount;
  final int acceptedPlaylistCount;
}

Future<CloudPlaylistMergeResult> mergeAndPersistCloudPlaylists({
  required PlaylistService service,
  required List love,
  required List userList,
  required CloudSongDecoder decodeSong,
  DateTime Function()? clock,
}) async {
  final now = clock ?? DateTime.now;
  final playlists = {
    for (final playlist in service.playlists) playlist.id: playlist
  };
  final favoriteSongs = love.map(decodeSong).whereType<MusicItem>().toList();
  final favorites = playlists['favorites'];
  if (favorites != null) {
    playlists['favorites'] = favorites.copyWith(
      songs: favoriteSongs,
      updatedAt: now(),
    );
  }

  final acceptedIds = <String>{};
  for (final raw in userList) {
    if (raw is! Map) continue;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty || id == 'love') continue;
    final name = raw['name']?.toString() ?? '云端歌单';
    final songs = ((raw['list'] as List?) ?? [])
        .map(decodeSong)
        .whereType<MusicItem>()
        .toList();
    final existing = playlists[id];
    final timestamp = now();
    playlists[id] = existing != null
        ? existing.copyWith(name: name, songs: songs, updatedAt: timestamp)
        : Playlist(
            id: id,
            name: name,
            description: '云端同步',
            songs: songs,
            createdAt: timestamp,
            updatedAt: timestamp,
          );
    acceptedIds.add(id);
  }

  await service.replaceAll(playlists.values.toList());
  return CloudPlaylistMergeResult(
    favoriteSongCount: favoriteSongs.length,
    acceptedPlaylistCount: acceptedIds.length,
  );
}
