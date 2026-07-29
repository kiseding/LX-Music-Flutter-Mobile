# Playback Cache Transactions Design

## Goal

Close the remaining playback-cache races by serializing all key-owned state and
file transitions through one non-reentrant per-key transaction gate, and make
startup orphan cleanup fail closed when persisted index integrity is uncertain.

## Per-Key Transactions

`PlaybackCacheService` owns one asynchronous tail per cache key. Public and
cross-key orchestration methods enter a key transaction once, then invoke
private `Locked` methods that never enter the gate again. The transaction owns
entry validation, hit metadata persistence, lease increments and releases,
commit and rollback, entry removal, expiration and size-eviction rechecks,
cancellation-owned cleanup, and stable sibling cleanup.

Downloads and candidate selection happen outside the transaction. A completed
download enters the key transaction only to install and durably index its
staged file. Lease acquisition enters after a shared download returns, verifies
that the returned path still identifies the exact current entry and regular
file, and increments the lease before releasing the transaction. If purge wins
first, acquisition retries the cache operation once and returns only a newly
validated lease.

Purge snapshots possible TTL and size candidates without mutating them. Each
candidate is processed under its key transaction and rechecked against exact
entry identity, lease and inflight protection, current expiration, and current
size pressure. A stale candidate cannot remove a replacement entry.

## Lock Ordering

The key gate is non-reentrant by convention and API shape: only boundary
methods call `_withKeyTransaction`; methods suffixed `Locked` require ownership
and never call the gate. Global index writes remain serialized by
`_pendingIndexWrite`. A key transaction may await an index write, but an index
write callback only snapshots and writes current state and never waits for a
key transaction. This one-way dependency prevents an await cycle.

Cancellation remains immediately observable through the cancel token. Its
generation/inflight mutation and any resulting key-owned index or stable-file
cleanup are serialized through the key transaction.

## Index Integrity

Index loading distinguishes top-level integrity from record validity. A read or
top-level decode/type failure sets load integrity false, leaves the in-memory
index empty, and disables startup orphan migration deletion. It does not
overwrite the unreadable persisted value.

For a valid top-level list, each record is parsed independently. Valid records
are retained and normalized. Malformed records are skipped and a repaired index
is persisted. If a malformed record contains a plausible lowercase 40-hex key
or direct-child approved stable path, that key and path are conservatively
protected from orphan deletion for this load. Malformed values with no plausible
stable ownership claim are safely skipped. A later clean process startup has no
inherited uncertainty and can perform normal orphan cleanup.

## Verification

Deterministic test callbacks can pause stable validation while purge starts.
Tests cover lease acquisition against TTL and size purge, hit-write failure
against purge, commit against purge, malformed top-level preservation, mixed
valid and malformed records, ambiguous ownership preservation, and cleanup on
a later clean load. Existing ownership, symlink, rollback, size, and full
project suites remain required.
