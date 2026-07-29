import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'playlist_repository.dart';

class PlaylistFileSystem {
  const PlaylistFileSystem();

  Future<bool> exists(String path) => File(path).exists();
  Future<String> read(String path) => File(path).readAsString();
  Future<void> write(String path, String contents, {bool flush = false}) =>
      File(path).writeAsString(contents, flush: flush);
  Future<void> copy(String from, String to) => File(from).copy(to);
  Future<void> rename(String from, String to) => File(from).rename(to);
  Future<void> delete(String path) => File(path).delete();
}

final class FilePlaylistRepository implements PlaylistRepository {
  FilePlaylistRepository({
    required this.directory,
    required this.preferences,
    this.codec = const PlaylistSnapshotCodec(),
    DateTime Function()? clock,
    PlaylistFileSystem? fileSystem,
  })  : _clock = clock ?? DateTime.now,
        _files = fileSystem ?? const PlaylistFileSystem();

  static const _currentName = 'playlists.v1.json';
  static const _temporaryName = 'playlists.v1.tmp';
  static const _previousName = 'playlists.v1.previous';
  static const _recoveryName = 'playlists.v1.recovery.json';
  static const _legacyKey = 'playlists';

  final Future<Directory> Function() directory;
  final SharedPreferences preferences;
  final PlaylistSnapshotCodec codec;
  final DateTime Function() _clock;
  final PlaylistFileSystem _files;

  @override
  Future<PlaylistSnapshot> load() async {
    final paths = await _paths();
    final current = await _decodeFile(paths.current);
    if (current != null) {
      if (await _files.exists(paths.recovery)) {
        await preferences.remove(_legacyKey);
        await _files.delete(paths.recovery);
      }
      return current;
    }

    if (await _files.exists(paths.current)) {
      await _quarantine(paths.current, paths.directory);
    }

    final previous = await _decodeFile(paths.previous);
    if (previous != null) {
      await _restore(paths.previous, paths);
      return previous;
    }

    final recovery = await _decodeFile(paths.recovery);
    if (recovery != null) {
      await _restore(paths.recovery, paths);
      return recovery;
    }

    final legacy = _decodeLegacy(preferences.getString(_legacyKey));
    if (legacy != null) {
      final encoded = codec.encode(legacy);
      await _files.write(paths.recovery, encoded, flush: true);
      await save(legacy);
      return legacy;
    }

    return PlaylistSnapshot(schemaVersion: 1, playlists: const []);
  }

  @override
  Future<void> save(PlaylistSnapshot snapshot) async {
    final paths = await _paths();
    final encoded = codec.encode(snapshot);
    codec.decode(encoded);

    await _files.write(paths.temporary, encoded, flush: true);
    try {
      codec.decode(await _files.read(paths.temporary));
      if (await _files.exists(paths.previous)) {
        await _files.delete(paths.previous);
      }
      if (await _files.exists(paths.current)) {
        await _files.copy(paths.current, paths.previous);
      }
      try {
        await _files.rename(paths.temporary, paths.current);
        codec.decode(await _files.read(paths.current));
        if (await _files.exists(paths.previous)) {
          await _files.delete(paths.previous);
        }
      } catch (_) {
        if ((!await _isValid(paths.current)) &&
            await _files.exists(paths.previous)) {
          await _files.copy(paths.previous, paths.current);
        }
        rethrow;
      }
    } finally {
      if (await _files.exists(paths.temporary)) {
        await _files.delete(paths.temporary);
      }
    }
  }

  Future<bool> _isValid(String path) async => (await _decodeFile(path)) != null;

  Future<void> _restore(String source, _Paths paths) async {
    await _files.write(paths.temporary, await _files.read(source), flush: true);
    try {
      codec.decode(await _files.read(paths.temporary));
      await _files.rename(paths.temporary, paths.current);
      codec.decode(await _files.read(paths.current));
    } finally {
      if (await _files.exists(paths.temporary)) {
        await _files.delete(paths.temporary);
      }
    }
  }

  Future<PlaylistSnapshot?> _decodeFile(String path) async {
    if (!await _files.exists(path)) return null;
    try {
      return codec.decode(await _files.read(path));
    } on FormatException {
      return null;
    }
  }

  PlaylistSnapshot? _decodeLegacy(String? source) {
    if (source == null) return null;
    try {
      final decoded = jsonDecode(source);
      if (decoded is! List) return null;
      return codec.decode(jsonEncode({
        'schemaVersion': 1,
        'playlists': decoded,
      }));
    } on FormatException {
      return null;
    }
  }

  Future<void> _quarantine(String current, String directoryPath) async {
    var timestamp = _clock().millisecondsSinceEpoch;
    var target = '$directoryPath/playlists.v1.corrupt.$timestamp.json';
    while (await _files.exists(target)) {
      timestamp++;
      target = '$directoryPath/playlists.v1.corrupt.$timestamp.json';
    }
    await _files.rename(current, target);
  }

  Future<_Paths> _paths() async {
    final root = (await directory()).path;
    return _Paths(
      directory: root,
      current: '$root/$_currentName',
      temporary: '$root/$_temporaryName',
      previous: '$root/$_previousName',
      recovery: '$root/$_recoveryName',
    );
  }
}

final class _Paths {
  const _Paths({
    required this.directory,
    required this.current,
    required this.temporary,
    required this.previous,
    required this.recovery,
  });

  final String directory;
  final String current;
  final String temporary;
  final String previous;
  final String recovery;
}
