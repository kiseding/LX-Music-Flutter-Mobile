# Playlist Snapshot Meta Immutability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure playlist snapshots own a recursively immutable, JSON-only copy of every song meta graph.

**Architecture:** `PlaylistSnapshot` becomes the ownership boundary by rebuilding each captured `MusicItem` and recursively copying its `meta` maps and lists into unmodifiable collections. The strict codec keeps its schema validation and feeds decoded values through the same constructor boundary, retaining the version-1 envelope and all item fields.

**Tech Stack:** Dart, Flutter test, Flutter analyzer.

## Global Constraints

- Preserve the schema-version-1 envelope and all existing `MusicItem` codec fields.
- Accept meta JSON values only: null, String, bool, finite num, List, and Maps with String keys.
- Reject invalid constructor meta values with path-specific `FormatException` messages.
- Do not alter `MusicItem` behavior outside `PlaylistSnapshot`.
- Run focused Flutter tests, analyzer, and `git diff --check` before committing.

---

### Task 1: Define Deep-Immutability Regressions

**Files:**
- Modify: `test/features/playlist/data/playlist_repository_test.dart:9-163`

**Interfaces:**
- Consumes: `PlaylistSnapshot({required int schemaVersion, required List<Playlist> playlists})`
- Consumes: `PlaylistSnapshotCodec.decode(String source)`
- Produces: regression coverage for direct-construction ownership, decoded ownership, immutable exposed meta, and constructor invalid-meta paths.

- [ ] **Step 1: Write failing direct-construction ownership tests**

```dart
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
```

- [ ] **Step 2: Run the direct-construction test to verify it fails**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart --plain-name "deeply copies and freezes constructor song meta"`

Expected: FAIL because `PlaylistSnapshot` retains the original `MusicItem.meta` map.

- [ ] **Step 3: Write failing decode ownership and invalid-value tests**

```dart
test('deeply freezes decoded song meta', () {
  final decoded = const PlaylistSnapshotCodec().decode(jsonEncode({
    'schemaVersion': 1,
    'playlists': [playlistJson('one', songs: [songJson()])],
  }));
  final meta = decoded.playlists.single.songs.single.meta!;

  expect(() => meta['new'] = true, throwsUnsupportedError);
  expect(() => (meta['nested'] as Map<String, dynamic>)['number'] = 2,
      throwsUnsupportedError);
  expect(() => (meta['tags'] as List<dynamic>).add('three'),
      throwsUnsupportedError);
});

test('rejects non-JSON constructor meta at its field path', () {
  expectFormatException(
    () => PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [
        playlistFixture(songs: [songFixture(meta: {'nested': DateTime.utc(2026)})]),
      ],
    ),
    'playlists[0].songs[0].meta.nested',
  );
});
```

- [ ] **Step 4: Run the focused test file to verify the regressions fail**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart`

Expected: FAIL in the new deep-immutability tests; the invalid constructor meta test also fails until validation is added.

### Task 2: Establish Snapshot Ownership

**Files:**
- Modify: `lib/features/playlist/data/playlist_repository.dart:6-21`
- Test: `test/features/playlist/data/playlist_repository_test.dart:9-163`

**Interfaces:**
- Consumes: `MusicItem` immutable scalar properties and nullable `Map<String, dynamic>? meta`.
- Produces: a `PlaylistSnapshot` whose `playlists`, `songs`, and nested meta maps/lists cannot mutate or alias caller data.

- [ ] **Step 1: Rebuild each song through recursive JSON copying**

```dart
PlaylistSnapshot({
  required this.schemaVersion,
  required List<Playlist> playlists,
}) : playlists = List.unmodifiable([
        for (var playlistIndex = 0;
            playlistIndex < playlists.length;
            playlistIndex++)
          _copyPlaylist(playlists[playlistIndex], playlistIndex),
      ]) {
  if (schemaVersion != 1) {
    throw const FormatException('schemaVersion must be 1');
  }
}

static Playlist _copyPlaylist(Playlist playlist, int playlistIndex) {
  return playlist.copyWith(songs: List.unmodifiable([
    for (var songIndex = 0; songIndex < playlist.songs.length; songIndex++)
      _copySong(
        playlist.songs[songIndex],
        'playlists[$playlistIndex].songs[$songIndex].meta',
      ),
  ]));
}
```

- [ ] **Step 2: Copy every scalar field and recursively freeze meta values**

```dart
static dynamic _copyJsonValue(dynamic value, String path) {
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is List) {
    return List.unmodifiable([
      for (var index = 0; index < value.length; index++)
        _copyJsonValue(value[index], '$path[$index]'),
    ]);
  }
  if (value is Map) {
    final copy = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$path must use string keys');
      }
      copy[entry.key as String] =
          _copyJsonValue(entry.value, '$path.${entry.key}');
    }
    return Map.unmodifiable(copy);
  }
  throw FormatException('$path must be a JSON value');
}
```

- [ ] **Step 3: Run focused regression tests to verify they pass**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart`

Expected: PASS, including original codec round-trip and strict-validation tests.

- [ ] **Step 4: Commit the implementation and test changes**

```bash
git add lib/features/playlist/data/playlist_repository.dart test/features/playlist/data/playlist_repository_test.dart
```

### Task 3: Document And Verify

**Files:**
- Modify: `persistence-task-5-report.md:10-34`

**Interfaces:**
- Consumes: completed constructor and codec immutability behavior.
- Produces: updated persistence task report with test-driven evidence and verification commands.

- [ ] **Step 1: Update the report contract and evidence**

```markdown
- Snapshots own recursively immutable copies of every song meta graph; caller
  mutation and mutation through exposed nested collections cannot alter a
  captured or decoded snapshot.
- Constructor meta accepts JSON-compatible values only and reports invalid
  values with their playlist/song/meta path.
```

- [ ] **Step 2: Run focused verification**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart test/features/player/domain/music_item_test.dart test/features/playlist/domain/playlist_test.dart`

Expected: PASS.

Run: `flutter analyze lib/features/playlist/data/playlist_repository.dart test/features/playlist/data/playlist_repository_test.dart`

Expected: no issues found.

Run: `git diff --check`

Expected: no output and exit status 0.

- [ ] **Step 3: Commit the report**

```bash
git add persistence-task-5-report.md
```
