/// In-memory entries with a last-access TTL. Disk helpers live beside loaders.
class TtlCacheEntry<T> {
  TtlCacheEntry(this.value, this.lastAccessedAt);

  final T value;
  DateTime lastAccessedAt;
}

class TtlCache<T> {
  TtlCache({
    required this.ttl,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, TtlCacheEntry<T>> _entries = {};

  static const defaultTtl = Duration(hours: 12);

  T? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    final now = _clock();
    if (now.difference(entry.lastAccessedAt) > ttl) {
      _entries.remove(key);
      return null;
    }
    entry.lastAccessedAt = now;
    return entry.value;
  }

  void set(String key, T value) {
    _entries[key] = TtlCacheEntry(value, _clock());
  }

  void remove(String key) => _entries.remove(key);

  void clear() => _entries.clear();

  int get length => _entries.length;
}
