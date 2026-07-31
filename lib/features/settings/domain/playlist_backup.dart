import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/io/bounded_input.dart';
import '../../../core/storage/storage_service.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../playlist/domain/playlist.dart';
import '../../playlist/domain/playlist_service.dart';
import '../presentation/settings_provider.dart';

const backupKeys = {
  'version',
  'timestamp',
  'playlists',
  'search_history',
  'theme_mode',
  'audio_quality',
  'download_quality',
  'wifi_only_download',
};

final class BackupLimits {
  const BackupLimits({
    this.maximumPlaylists = 500,
    this.maximumSongsPerPlaylist = 5000,
    this.maximumTotalSongs = 20000,
    this.maximumHistoryItems = 20,
    this.maximumHistoryStringLength = 64 * 1024,
    this.jsonBudget = const JsonBudget(),
  });

  static const int maximumFileBytes = 8 * 1024 * 1024;

  final int maximumPlaylists;
  final int maximumSongsPerPlaylist;
  final int maximumTotalSongs;
  final int maximumHistoryItems;
  final int maximumHistoryStringLength;
  final JsonBudget jsonBudget;
}

final class BackupData {
  const BackupData({
    required this.version,
    required this.timestamp,
    required this.playlists,
    required this.searchHistory,
    required this.themeMode,
    required this.audioQuality,
    required this.downloadQuality,
    required this.wifiOnlyDownload,
  });

  final int version;
  final String? timestamp;
  final List<Playlist> playlists;
  final List<String> searchHistory;
  final ThemeMode themeMode;
  final AudioQualityOption audioQuality;
  final AudioQualityOption downloadQuality;
  final bool wifiOnlyDownload;
}

final class BackupRestoreException implements Exception {
  const BackupRestoreException(this.original, this.compensation);

  final Object original;
  final Object compensation;

  @override
  String toString() =>
      'BackupRestoreException(original: $original, compensation: $compensation)';
}

PlaylistSnapshot decodeBackupPlaylists(Map<String, dynamic> backup) {
  final encoded = jsonEncode(backup);
  return PlaylistSnapshot(
    schemaVersion: 1,
    playlists: decodeBackup(encoded).playlists,
  );
}

Future<void> restoreBackupPlaylists(
  Map<String, dynamic> backup,
  Future<void> Function(List<Playlist>) replaceAll,
) async {
  final snapshot = decodeBackupPlaylists(backup);
  await replaceAll(snapshot.playlists);
}

BackupData decodeBackup(
  String source, {
  BackupLimits limits = const BackupLimits(),
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    rethrow;
  }
  validateJsonBudget(decoded, limits.jsonBudget);
  if (decoded is! Map) {
    throw const FormatException('backup root must be an object');
  }
  final root = Map<String, dynamic>.from(
    decoded.map((key, value) => MapEntry(key.toString(), value)),
  );
  for (final key in root.keys) {
    if (!backupKeys.contains(key)) {
      throw FormatException('unknown backup key: $key');
    }
  }
  if (root['version'] != 1) {
    throw const FormatException('backup version must be 1');
  }
  if (!root.containsKey('playlists') || root['playlists'] == null) {
    throw const FormatException('backup playlists are required');
  }

  final playlistsValue = root['playlists'];
  final snapshotObject = playlistsValue is List
      ? <String, dynamic>{'schemaVersion': 1, 'playlists': playlistsValue}
      : playlistsValue;
  if (snapshotObject is! Map) {
    throw const FormatException('backup playlists must be a list or snapshot');
  }
  final snapshot = const PlaylistSnapshotCodec().decode(
    jsonEncode(snapshotObject),
  );
  if (snapshot.playlists.length > limits.maximumPlaylists) {
    throw FormatException(
      'backup exceeds maximum playlists (${limits.maximumPlaylists})',
    );
  }
  var totalSongs = 0;
  for (final playlist in snapshot.playlists) {
    if (playlist.songs.length > limits.maximumSongsPerPlaylist) {
      throw FormatException(
        'playlist ${playlist.id} exceeds maximum songs per playlist',
      );
    }
    totalSongs += playlist.songs.length;
  }
  if (totalSongs > limits.maximumTotalSongs) {
    throw FormatException(
      'backup exceeds maximum total songs (${limits.maximumTotalSongs})',
    );
  }

  final searchHistory = _decodeSearchHistory(
    root['search_history'],
    limits: limits,
  );
  final themeMode = _decodeThemeMode(root['theme_mode']);
  final audioQuality = _decodeAudioQuality(root['audio_quality'], 'audio_quality');
  final downloadQuality =
      _decodeAudioQuality(root['download_quality'], 'download_quality');
  final wifiOnlyDownload = _decodeWifiOnly(root['wifi_only_download']);
  final timestamp = root['timestamp'];
  if (timestamp != null && timestamp is! String) {
    throw const FormatException('timestamp must be a string');
  }

  return BackupData(
    version: 1,
    timestamp: timestamp as String?,
    playlists: snapshot.playlists,
    searchHistory: searchHistory,
    themeMode: themeMode,
    audioQuality: audioQuality,
    downloadQuality: downloadQuality,
    wifiOnlyDownload: wifiOnlyDownload,
  );
}

List<String> _decodeSearchHistory(
  Object? raw, {
  required BackupLimits limits,
}) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw const FormatException('search_history must be a list');
  }
  if (raw.length > limits.maximumHistoryItems) {
    throw FormatException(
      'search_history exceeds ${limits.maximumHistoryItems} items',
    );
  }
  final history = <String>[];
  for (final item in raw) {
    if (item is! String || item.isEmpty) {
      throw const FormatException('search_history items must be non-empty strings');
    }
    if (item.length > limits.maximumHistoryStringLength) {
      throw FormatException(
        'search_history item exceeds ${limits.maximumHistoryStringLength} chars',
      );
    }
    history.add(item);
  }
  return List.unmodifiable(history);
}

ThemeMode _decodeThemeMode(Object? raw) {
  if (raw == null) return ThemeMode.system;
  if (raw is! int || raw < 0 || raw >= ThemeMode.values.length) {
    throw const FormatException('theme_mode must be a valid ThemeMode index');
  }
  return ThemeMode.values[raw];
}

AudioQualityOption _decodeAudioQuality(Object? raw, String field) {
  if (raw == null) {
    return field == 'download_quality'
        ? AudioQualityOption.high
        : AudioQualityOption.high;
  }
  if (raw is! int || raw < 0 || raw >= AudioQualityOption.values.length) {
    throw FormatException('$field must be a valid AudioQualityOption index');
  }
  return AudioQualityOption.values[raw];
}

bool _decodeWifiOnly(Object? raw) {
  if (raw == null) return true;
  if (raw is! bool) {
    throw const FormatException('wifi_only_download must be a bool');
  }
  return raw;
}

final class BackupRestoreCoordinator {
  BackupRestoreCoordinator({
    required StorageService storage,
    required PlaylistService playlists,
    required void Function(BackupData) publishCommitted,
  })  : _storage = storage,
        _playlists = playlists,
        _publishCommitted = publishCommitted;

  final StorageService _storage;
  final PlaylistService _playlists;
  final void Function(BackupData) _publishCommitted;

  static const _preferenceKeys = {
    'search_history',
    'theme_mode',
    'audio_quality',
    'download_quality',
    'wifi_only_download',
  };

  Future<void> restore(BackupData data) async {
    final previousPreferences = _storage.snapshot(_preferenceKeys);
    final previousPlaylists = PlaylistSnapshot(
      schemaVersion: 1,
      playlists: await _playlists.getAllPlaylists(),
    );
    var playlistWriteAttempted = false;

    try {
      await _storage.setStringList('search_history', data.searchHistory);
      await _storage.setInt('theme_mode', data.themeMode.index);
      await _storage.setInt('audio_quality', data.audioQuality.index);
      await _storage.setInt('download_quality', data.downloadQuality.index);
      await _storage.setBool('wifi_only_download', data.wifiOnlyDownload);

      playlistWriteAttempted = true;
      await _playlists.replaceAll(data.playlists);
      _publishCommitted(data);
    } catch (error, stackTrace) {
      Object? compensationError;
      StackTrace? compensationStack;
      try {
        await _storage.restore(previousPreferences);
        if (playlistWriteAttempted) {
          await _playlists.restoreSnapshot(previousPlaylists);
        }
      } catch (rollbackError, rollbackStack) {
        compensationError = rollbackError;
        compensationStack = rollbackStack;
      }
      if (compensationError != null) {
        Error.throwWithStackTrace(
          BackupRestoreException(error, compensationError),
          compensationStack ?? stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}
