UPDATE playlist_songs
SET songmid = '_empty_' || rowid
WHERE songmid = '';

DELETE FROM playlist_songs
WHERE rowid NOT IN (
  SELECT MIN(rowid)
  FROM playlist_songs
  GROUP BY playlist_id, user_id, songmid, source
);

DROP INDEX IF EXISTS uniq_ps_love_song;
CREATE UNIQUE INDEX uniq_ps_love_song
  ON playlist_songs(playlist_id, user_id, songmid, source);
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
