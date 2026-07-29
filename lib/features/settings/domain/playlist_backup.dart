import 'dart:convert';

import '../../playlist/data/playlist_repository.dart';

PlaylistSnapshot decodeBackupPlaylists(Map<String, dynamic> backup) {
  if (backup['version'] != 1) {
    throw const FormatException('backup version must be 1');
  }
  final playlists = backup['playlists'];
  final snapshot = playlists is List
      ? <String, dynamic>{'schemaVersion': 1, 'playlists': playlists}
      : playlists;
  return const PlaylistSnapshotCodec().decode(jsonEncode(snapshot));
}
