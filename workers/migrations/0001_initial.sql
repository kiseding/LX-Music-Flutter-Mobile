CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  token_version INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS system_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS playlists (
  id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  position INTEGER NOT NULL DEFAULT 0,
  source TEXT DEFAULT '',
  source_id TEXT DEFAULT '',
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (id, user_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS playlist_songs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  playlist_id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  singer TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  songmid TEXT DEFAULT '',
  album_name TEXT DEFAULT '',
  album_id TEXT DEFAULT '',
  img TEXT DEFAULT '',
  interval TEXT DEFAULT '',
  types TEXT DEFAULT '[]',
  hash TEXT DEFAULT '',
  str_media_mid TEXT DEFAULT '',
  copyright_id TEXT DEFAULT '',
  metadata TEXT DEFAULT '{}',
  position INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (playlist_id, user_id) REFERENCES playlists(id, user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_artists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  artist_id TEXT NOT NULL,
  name TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  img TEXT DEFAULT '',
  data TEXT DEFAULT '{}',
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(user_id, artist_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_albums (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  album_id TEXT NOT NULL,
  name TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  img TEXT DEFAULT '',
  singer TEXT DEFAULT '',
  data TEXT DEFAULT '{}',
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(user_id, album_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id INTEGER PRIMARY KEY,
  settings TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS playback_progress (
  user_id INTEGER NOT NULL,
  song_id TEXT NOT NULL,
  position REAL NOT NULL DEFAULT 0,
  duration REAL NOT NULL DEFAULT 0,
  updated_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, song_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
