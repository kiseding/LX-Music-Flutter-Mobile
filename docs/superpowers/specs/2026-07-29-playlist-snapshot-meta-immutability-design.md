# Playlist Snapshot Meta Immutability Design

## Scope

Make `PlaylistSnapshot` own an immutable, recursively copied representation of
every song's `MusicItem.meta` value. This applies to snapshots built directly
and snapshots returned by `PlaylistSnapshotCodec.decode`.

## Snapshot Construction

`PlaylistSnapshot` rebuilds each playlist's songs when it captures input.
Every rebuilt `MusicItem` retains all existing scalar fields. Its `meta` is
recursively copied so that maps and lists use unmodifiable collections.

Allowed meta values are JSON values: null, strings, booleans, finite numbers,
lists, and maps with string keys. A non-JSON value, a non-string map key, or a
non-finite number fails construction with a `FormatException` containing the
playlist/song/meta path.

## Codec Behavior

The codec continues to validate the exact version-1 envelope and every
existing required and optional field. Decode still validates JSON meta values
with field paths, then creates a `PlaylistSnapshot`, which establishes the
same deep ownership boundary as direct construction. Encoding retains every
`MusicItem` field and the complete meta graph.

## Tests

Tests cover direct construction and decode. They prove source top-level maps,
nested maps, and nested lists cannot alter a captured snapshot; exposed nested
collections cannot be mutated; the complete codec round trip remains intact;
and invalid constructor meta values receive path-specific errors.

## Out Of Scope

`MusicItem` remains mutable-by-reference outside the persistence snapshot
boundary. No persistence storage, migration, service, or UI behavior changes.
