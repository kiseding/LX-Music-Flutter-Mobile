/**
 * Database schema — single source of truth
 * Auto-generated from schema.sql for Workers import
 *
 * P2-1: indexes brought into alignment with src/db/schema.sql.
 * P1-9: users.token_version added for instant JWT revocation.
 */
export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'user', token_version INTEGER NOT NULL DEFAULT 0, created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS system_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS playlists (id TEXT NOT NULL, user_id INTEGER NOT NULL, name TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, source TEXT DEFAULT '', source_id TEXT DEFAULT '', created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')), PRIMARY KEY (id, user_id), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS playlist_songs (id INTEGER PRIMARY KEY AUTOINCREMENT, playlist_id TEXT NOT NULL, user_id INTEGER NOT NULL, name TEXT NOT NULL, singer TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', songmid TEXT DEFAULT '', album_name TEXT DEFAULT '', album_id TEXT DEFAULT '', img TEXT DEFAULT '', interval TEXT DEFAULT '', types TEXT DEFAULT '[]', hash TEXT DEFAULT '', str_media_mid TEXT DEFAULT '', copyright_id TEXT DEFAULT '', metadata TEXT DEFAULT '{}', position INTEGER NOT NULL DEFAULT 0, created_at TEXT DEFAULT (datetime('now')), FOREIGN KEY (playlist_id, user_id) REFERENCES playlists(id, user_id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS user_artists (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, artist_id TEXT NOT NULL, name TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', img TEXT DEFAULT '', data TEXT DEFAULT '{}', created_at TEXT DEFAULT (datetime('now')), UNIQUE(user_id, artist_id), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS user_albums (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, album_id TEXT NOT NULL, name TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', img TEXT DEFAULT '', singer TEXT DEFAULT '', data TEXT DEFAULT '{}', created_at TEXT DEFAULT (datetime('now')), UNIQUE(user_id, album_id), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS user_settings (user_id INTEGER PRIMARY KEY, settings TEXT NOT NULL DEFAULT '{}', updated_at TEXT DEFAULT (datetime('now')), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS playback_progress (user_id INTEGER NOT NULL, song_id TEXT NOT NULL, position REAL NOT NULL DEFAULT 0, duration REAL NOT NULL DEFAULT 0, updated_at TEXT DEFAULT (datetime('now')), PRIMARY KEY (user_id, song_id), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);
CREATE UNIQUE INDEX IF NOT EXISTS uniq_ps_love_song ON playlist_songs(playlist_id, user_id, songmid, source);
CREATE INDEX IF NOT EXISTS idx_ps_playlist_user ON playlist_songs(playlist_id, user_id);
CREATE INDEX IF NOT EXISTS idx_ps_position ON playlist_songs(playlist_id, user_id, position);
CREATE INDEX IF NOT EXISTS idx_ps_songid ON playlist_songs(hash, source);
CREATE INDEX IF NOT EXISTS idx_ps_songmid ON playlist_songs(songmid, source);
CREATE INDEX IF NOT EXISTS idx_pls_user_updated ON playlists(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_artists_user ON user_artists(user_id);
CREATE INDEX IF NOT EXISTS idx_artists_lookup ON user_artists(user_id, artist_id, source);
CREATE INDEX IF NOT EXISTS idx_albums_user ON user_albums(user_id);
CREATE INDEX IF NOT EXISTS idx_albums_lookup ON user_albums(user_id, album_id, source);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_settings_user ON user_settings(user_id);
`;
