import 'dart:convert';

import '../../playlist/data/playlist_repository.dart';
import '../../playlist/domain/playlist.dart';

PlaylistSnapshot decodeBackupPlaylists(Map<String, dynamic> backup) {
  if (backup['version'] != 1) {
    throw const FormatException('backup version must be 1');
  }
  if (!backup.containsKey('playlists') || backup['playlists'] == null) {
    throw const FormatException('backup playlists are required');
  }
  final playlists = backup['playlists'];
  final snapshot = playlists is List
      ? <String, dynamic>{'schemaVersion': 1, 'playlists': playlists}
      : playlists;
  return const PlaylistSnapshotCodec().decode(jsonEncode(snapshot));
}

Future<void> restoreBackupPlaylists(
  Map<String, dynamic> backup,
  Future<void> Function(List<Playlist>) replaceAll,
) async {
  final snapshot = decodeBackupPlaylists(backup);
  await replaceAll(snapshot.playlists);
}
