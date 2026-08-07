import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'playlist_repository.dart';
import '../../player/domain/music_item.dart';
import '../domain/playlist.dart';

@visibleForTesting
abstract interface class PlaylistOpenFile {
  Future<void> flush();
  Future<void> close();
}

final class _RandomAccessPlaylistFile implements PlaylistOpenFile {
  const _RandomAccessPlaylistFile(this.file);

  final RandomAccessFile file;

  @override
  Future<void> flush() => file.flush();

  @override
  Future<void> close() async {
    await file.close();
  }
}

@visibleForTesting
class PlaylistFileSystem {
  const PlaylistFileSystem();

  Future<bool> exists(String path) => File(path).exists();
  Future<String> read(String path) => File(path).readAsString();
  Future<void> write(String path, String contents, {bool flush = false}) =>
      File(path).writeAsString(contents, flush: flush);
  Future<void> copy(String from, String to) => File(from).copy(to);
  Future<PlaylistOpenFile> openForAppend(String path) async =>
      _RandomAccessPlaylistFile(await File(path).open(mode: FileMode.append));
  Future<void> flushAndClose(String path) async {
    final file = await openForAppend(path);
    try {
      await file.flush();
    } finally {
      await file.close();
    }
  }

  Future<void> rename(String from, String to) => File(from).rename(to);
  Future<void> delete(String path) => File(path).delete();
}

final class FilePlaylistRepository
    implements PlaylistRepository, PlaylistSongPageRepository {
  FilePlaylistRepository({
    required this.directory,
    required this.preferences,
    this.codec = const PlaylistSnapshotCodec(),
    DateTime Function()? clock,
    @visibleForTesting PlaylistFileSystem? fileSystem,
    @visibleForTesting Future<bool> Function(String key)? removePreference,
  })  : _clock = clock ?? DateTime.now,
        _files = fileSystem ?? const PlaylistFileSystem(),
        _removePreference = removePreference ?? preferences.remove;

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
  final Future<bool> Function(String key) _removePreference;
  _LazyPlaylistDocument? _document;

  @override
  Future<PlaylistSnapshot> load() async {
    final paths = await _paths();
    final current = await _decodeLazyFile(paths.current, cache: true);
    if (current != null) {
      if (await _files.exists(paths.recovery)) {
        final legacySource = preferences.getString(_legacyKey);
        if (legacySource == null ||
            (_decodeLegacy(legacySource) != null &&
                await _removePreference(_legacyKey))) {
          await _files.delete(paths.recovery);
        }
      }
      return current;
    }

    if (await _files.exists(paths.current)) {
      await _quarantine(paths.current, paths.directory);
    }

    final previous = await _decodeFile(paths.previous);
    if (previous != null) {
      await _restore(paths.previous, paths);
      return (await _decodeLazyFile(paths.current, cache: true)) ?? previous;
    }

    final recovery = await _decodeFile(paths.recovery);
    if (recovery != null) {
      await _restore(paths.recovery, paths);
      return (await _decodeLazyFile(paths.current, cache: true)) ?? recovery;
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
        await _files.flushAndClose(paths.previous);
      }
      try {
        await _files.rename(paths.temporary, paths.current);
        codec.decode(await _files.read(paths.current));
        _document = _LazyPlaylistDocument.parse(encoded, codec);
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

  @override
  Future<PlaylistSongPage> loadSongsPage(
    String playlistId, {
    required int offset,
    required int limit,
  }) async {
    if (offset < 0 || limit <= 0) {
      throw ArgumentError('offset must be non-negative and limit must be positive');
    }
    final document = await _loadDocument();
    final entry = document.entryFor(playlistId);
    final start = offset.clamp(0, entry.songCount).toInt();
    final end = (start + limit).clamp(0, entry.songCount).toInt();
    return PlaylistSongPage(
      total: entry.songCount,
      offset: start,
      songs: entry.decodeSongs(start, end),
    );
  }

  @override
  Future<List<MusicItem>> loadAllSongs(String playlistId) async {
    final entry = (await _loadDocument()).entryFor(playlistId);
    return entry.decodeSongs(0, entry.songCount);
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

  Future<PlaylistSnapshot?> _decodeLazyFile(
    String path, {
    required bool cache,
  }) async {
    if (!await _files.exists(path)) return null;
    try {
      final document = _LazyPlaylistDocument.parse(await _files.read(path), codec);
      if (cache) _document = document;
      return document.snapshot;
    } on FormatException {
      return null;
    }
  }

  Future<_LazyPlaylistDocument> _loadDocument() async {
    final cached = _document;
    if (cached != null) return cached;
    final document = await _decodeLazyFile((await _paths()).current, cache: true);
    if (document == null || _document == null) {
      throw StateError('Playlist storage is not available');
    }
    return _document!;
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

final class _LazyPlaylistDocument {
  _LazyPlaylistDocument._({
    required this.snapshot,
    required Map<String, _LazyPlaylistEntry> entries,
  }) : _entries = Map.unmodifiable(entries);

  final PlaylistSnapshot snapshot;
  final Map<String, _LazyPlaylistEntry> _entries;

  static _LazyPlaylistDocument parse(
    String source,
    PlaylistSnapshotCodec codec,
  ) {
    final scanner = _JsonRangeScanner(source);
    final root = scanner.objectFields(0);
    const rootKeys = {'schemaVersion', 'playlists'};
    if (root.keys.any((key) => !rootKeys.contains(key)) ||
        root.length != rootKeys.length) {
      throw const FormatException('root has unsupported keys');
    }
    final schema = jsonDecode(scanner.valueText(root['schemaVersion']!));
    if (schema != 1) throw const FormatException('schemaVersion must be 1');

    final entries = <String, _LazyPlaylistEntry>{};
    final summaries = <Playlist>[];
    for (final objectRange in scanner.arrayValues(root['playlists']!.start)) {
      final fields = scanner.objectFields(objectRange.start);
      final songs = fields['songs'];
      if (songs == null || songs.start >= songs.end) {
        throw const FormatException('playlist songs are missing');
      }
      final songRanges = scanner.arrayValues(songs.start);
      final summaryJson = '${source.substring(objectRange.start, songs.start)}[]'
          '${source.substring(songs.end, objectRange.end)}';
      final summary = codec
          .decode('{"schemaVersion":1,"playlists":[$summaryJson]}')
          .playlists
          .single
          .copyWith(songCount: songRanges.length);
      if (entries.containsKey(summary.id)) {
        throw FormatException('playlist ${summary.id} must be unique');
      }
      summaries.add(summary);
      entries[summary.id] = _LazyPlaylistEntry(
        source: source,
        codec: codec,
        playlistPrefix: source.substring(objectRange.start, songs.start),
        playlistSuffix: source.substring(songs.end, objectRange.end),
        songRanges: songRanges,
      );
    }
    return _LazyPlaylistDocument._(
      snapshot: PlaylistSnapshot(schemaVersion: 1, playlists: summaries),
      entries: entries,
    );
  }

  _LazyPlaylistEntry entryFor(String playlistId) {
    final entry = _entries[playlistId];
    if (entry == null) throw StateError('Playlist $playlistId does not exist');
    return entry;
  }
}

final class _LazyPlaylistEntry {
  const _LazyPlaylistEntry({
    required this.source,
    required this.codec,
    required this.playlistPrefix,
    required this.playlistSuffix,
    required this.songRanges,
  });

  final String source;
  final PlaylistSnapshotCodec codec;
  final String playlistPrefix;
  final String playlistSuffix;
  final List<_SourceRange> songRanges;

  int get songCount => songRanges.length;

  List<MusicItem> decodeSongs(int start, int end) {
    final songs = songRanges
        .sublist(start, end)
        .map((range) => source.substring(range.start, range.end))
        .join(',');
    final playlist = '$playlistPrefix[$songs]$playlistSuffix';
    return codec
        .decode('{"schemaVersion":1,"playlists":[$playlist]}')
        .playlists
        .single
        .songs;
  }
}

final class _SourceRange {
  const _SourceRange(this.start, this.end);

  final int start;
  final int end;
}

final class _JsonRangeScanner {
  _JsonRangeScanner(this.source);

  final String source;

  Map<String, _SourceRange> objectFields(int start) {
    var cursor = _skipWhitespace(start);
    if (_charAt(cursor) != 0x7b) {
      throw const FormatException('Expected a JSON object');
    }
    cursor = _skipWhitespace(cursor + 1);
    final fields = <String, _SourceRange>{};
    if (_charAt(cursor) == 0x7d) return fields;

    while (true) {
      final keyStart = cursor;
      final keyEnd = _scanString(keyStart);
      final key = jsonDecode(source.substring(keyStart, keyEnd));
      if (key is! String || fields.containsKey(key)) {
        throw const FormatException('Invalid JSON object key');
      }
      cursor = _skipWhitespace(keyEnd);
      if (_charAt(cursor) != 0x3a) {
        throw const FormatException('Expected a JSON object separator');
      }
      final valueStart = _skipWhitespace(cursor + 1);
      final valueEnd = _scanValue(valueStart);
      fields[key] = _SourceRange(valueStart, valueEnd);
      cursor = _skipWhitespace(valueEnd);
      final separator = _charAt(cursor);
      if (separator == 0x7d) return fields;
      if (separator != 0x2c) {
        throw const FormatException('Expected a JSON object delimiter');
      }
      cursor = _skipWhitespace(cursor + 1);
    }
  }

  List<_SourceRange> arrayValues(int start) {
    var cursor = _skipWhitespace(start);
    if (_charAt(cursor) != 0x5b) {
      throw const FormatException('Expected a JSON array');
    }
    cursor = _skipWhitespace(cursor + 1);
    final values = <_SourceRange>[];
    if (_charAt(cursor) == 0x5d) return values;

    while (true) {
      final valueStart = cursor;
      final valueEnd = _scanValue(valueStart);
      values.add(_SourceRange(valueStart, valueEnd));
      cursor = _skipWhitespace(valueEnd);
      final separator = _charAt(cursor);
      if (separator == 0x5d) return values;
      if (separator != 0x2c) {
        throw const FormatException('Expected a JSON array delimiter');
      }
      cursor = _skipWhitespace(cursor + 1);
    }
  }

  String valueText(_SourceRange range) => source.substring(range.start, range.end);

  int _scanValue(int start) {
    final first = _charAt(start);
    if (first == 0x22) return _scanString(start);
    if (first == 0x7b || first == 0x5b) return _scanComposite(start);

    var cursor = start;
    while (cursor < source.length) {
      final char = _charAt(cursor);
      if (char == 0x2c || char == 0x5d || char == 0x7d || _isWhitespace(char)) {
        break;
      }
      cursor++;
    }
    if (cursor == start) throw const FormatException('Expected a JSON value');
    return cursor;
  }

  int _scanString(int start) {
    if (_charAt(start) != 0x22) {
      throw const FormatException('Expected a JSON string');
    }
    var cursor = start + 1;
    while (cursor < source.length) {
      final char = _charAt(cursor);
      if (char == 0x5c) {
        cursor += 2;
      } else if (char == 0x22) {
        return cursor + 1;
      } else if (char < 0x20) {
        throw const FormatException('Invalid JSON string');
      } else {
        cursor++;
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  int _scanComposite(int start) {
    final closers = <int>[];
    var cursor = start;
    while (cursor < source.length) {
      final char = _charAt(cursor);
      if (char == 0x22) {
        cursor = _scanString(cursor);
        continue;
      }
      if (char == 0x7b) {
        closers.add(0x7d);
      } else if (char == 0x5b) {
        closers.add(0x5d);
      } else if (char == 0x7d || char == 0x5d) {
        if (closers.isEmpty || closers.removeLast() != char) {
          throw const FormatException('Unbalanced JSON value');
        }
        if (closers.isEmpty) return cursor + 1;
      }
      cursor++;
    }
    throw const FormatException('Unterminated JSON value');
  }

  int _skipWhitespace(int index) {
    var cursor = index;
    while (cursor < source.length && _isWhitespace(_charAt(cursor))) {
      cursor++;
    }
    return cursor;
  }

  int _charAt(int index) {
    if (index >= source.length) {
      throw const FormatException('Unexpected end of JSON input');
    }
    return source.codeUnitAt(index);
  }

  bool _isWhitespace(int char) =>
      char == 0x20 || char == 0x09 || char == 0x0a || char == 0x0d;
}
