import '../../player/domain/music_item.dart';

final class PlaylistSongOccurrence {
  const PlaylistSongOccurrence({required this.song, required this.key});
  final MusicItem song;
  final String key;
}

List<PlaylistSongOccurrence> buildPlaylistOccurrences(
  String playlistId,
  List<MusicItem> songs,
) {
  final counts = <String, int>{};
  return songs.map((song) {
    final occurrence =
        counts.update(song.id, (value) => value + 1, ifAbsent: () => 0);
    return PlaylistSongOccurrence(
      song: song,
      key: '$playlistId:${song.id}:$occurrence',
    );
  }).toList();
}
