import type { Env } from '../lib/response';
import type { SongInfo } from '../utils/types';

export interface PlaylistTarget {
  id: string;
  userId: number;
  name: string;
  position: number;
  source?: string;
  sourceId?: string;
}

export interface StageOptions {
  replace: boolean;
  startPosition?: number;
}

export function makeStageId(): string {
  return `__stage__:${crypto.randomUUID()}`;
}

export function songIdentity(songmid: unknown, source: unknown): string {
  return `${String(songmid || '')}|${String(source || '')}`;
}

export async function createStage(env: Env, userId: number): Promise<string> {
  const stageId = makeStageId();
  await env.DB.prepare(
    'INSERT INTO playlists (id, user_id, name, position, source, source_id) VALUES (?, ?, ?, ?, ?, ?)'
  ).bind(stageId, userId, '', -1, '', '').run();
  return stageId;
}

export async function insertStageSongs(
  env: Env,
  stageId: string,
  userId: number,
  songs: SongInfo[],
  startPosition = 0,
): Promise<void> {
  const unique = new Map<string, SongInfo>();
  for (const song of songs) {
    const mid = String(song.songmid || '').slice(0, 256);
    const source = String(song.source || '').slice(0, 32);
    if (!mid) continue;
    unique.set(songIdentity(mid, source), { ...song, songmid: mid, source });
  }

  const statements = [...unique.values()].map((song, index) => {
    const metadata = JSON.stringify({
      mrcUrl: song.mrcUrl || '',
      lrcUrl: song.lrcUrl || '',
      trcUrl: song.trcUrl || '',
    });
    return env.DB.prepare(
      `INSERT INTO playlist_songs
       (playlist_id, user_id, name, singer, source, songmid, album_name, album_id, img, interval, types, hash, metadata, position)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      stageId, userId, String(song.name || '').slice(0, 256), String(song.singer || '').slice(0, 256),
      song.source || '', song.songmid || '', String(song.albumName || '').slice(0, 256),
      String(song.albumId || '').slice(0, 128), String(song.img || '').slice(0, 512), song.interval || '0',
      JSON.stringify(song.types || []).slice(0, 1024), String(song.hash || '').slice(0, 256), metadata,
      startPosition + index,
    );
  });
  for (let i = 0; i < statements.length; i += 100) {
    await env.DB.batch(statements.slice(i, i + 100));
  }
}

const PARENT_UPSERT = `INSERT INTO playlists (id, user_id, name, position, source, source_id)
  VALUES (?, ?, ?, ?, ?, ?)
  ON CONFLICT(id, user_id) DO UPDATE SET
    name = excluded.name,
    position = excluded.position,
    source = excluded.source,
    source_id = excluded.source_id,
    updated_at = datetime('now')`;

export async function commitStage(
  env: Env,
  stageId: string,
  target: PlaylistTarget,
  replace: boolean,
): Promise<void> {
  const parent = env.DB.prepare(PARENT_UPSERT).bind(
    target.id, target.userId, target.name, target.position, target.source || '', target.sourceId || '',
  );
  if (replace) {
    await env.DB.batch([
      parent,
      env.DB.prepare('DELETE FROM playlist_songs WHERE playlist_id = ? AND user_id = ?')
        .bind(target.id, target.userId),
      env.DB.prepare('UPDATE playlist_songs SET playlist_id = ? WHERE playlist_id = ? AND user_id = ?')
        .bind(target.id, stageId, target.userId),
      env.DB.prepare('DELETE FROM playlists WHERE id = ? AND user_id = ?')
        .bind(stageId, target.userId),
    ]);
    return;
  }

  await env.DB.batch([
    parent,
    env.DB.prepare(`INSERT OR IGNORE INTO playlist_songs
      (playlist_id, user_id, name, singer, source, songmid, album_name, album_id, img, interval, types, hash, str_media_mid, copyright_id, metadata, position)
      SELECT ?, user_id, name, singer, source, songmid, album_name, album_id, img, interval, types, hash, str_media_mid, copyright_id, metadata, position
      FROM playlist_songs WHERE playlist_id = ? AND user_id = ?`)
      .bind(target.id, stageId, target.userId),
    env.DB.prepare('DELETE FROM playlist_songs WHERE playlist_id = ? AND user_id = ?')
      .bind(stageId, target.userId),
    env.DB.prepare('DELETE FROM playlists WHERE id = ? AND user_id = ?')
      .bind(stageId, target.userId),
  ]);
}

export async function cleanupStage(env: Env, stageId: string, userId: number): Promise<void> {
  await env.DB.prepare('DELETE FROM playlists WHERE id = ? AND user_id = ?').bind(stageId, userId).run();
}

export async function writePlaylistAtomically(
  env: Env,
  target: PlaylistTarget,
  songs: SongInfo[],
  options: StageOptions,
): Promise<void> {
  const stageId = await createStage(env, target.userId);
  try {
    await insertStageSongs(env, stageId, target.userId, songs, options.startPosition || 0);
    await commitStage(env, stageId, target, options.replace);
  } catch (error) {
    try { await cleanupStage(env, stageId, target.userId); } catch {}
    throw error;
  }
}
