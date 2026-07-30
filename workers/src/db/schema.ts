import type { Env } from '../lib/response';

export type SchemaReadiness =
  | { ready: true }
  | { ready: false; reason: string };

export async function checkSchemaReady(env: Env): Promise<SchemaReadiness> {
  try {
    const [tables, columns, index] = await env.DB.batch([
      env.DB.prepare(`
        SELECT COUNT(*) AS count
        FROM sqlite_master
        WHERE type = 'table'
          AND name IN (
            'users', 'system_settings', 'playlists', 'playlist_songs',
            'user_artists', 'user_albums', 'user_settings', 'playback_progress'
          )
      `),
      env.DB.prepare("PRAGMA table_info('users')"),
      env.DB.prepare(`
        SELECT COUNT(*) AS count
        FROM sqlite_master
        WHERE type = 'index' AND name = 'uniq_ps_love_song'
      `),
    ]);
    const tableCount = Number((tables.results?.[0] as { count?: number } | undefined)?.count ?? 0);
    const hasTokenVersion = (columns.results as Array<{ name?: string }> | undefined)
      ?.some((column) => column.name === 'token_version') ?? false;
    const indexCount = Number((index.results?.[0] as { count?: number } | undefined)?.count ?? 0);
    if (tableCount !== 8 || !hasTokenVersion || indexCount !== 1) {
      return { ready: false, reason: 'D1 migrations are pending' };
    }
    return { ready: true };
  } catch {
    return { ready: false, reason: 'D1 readiness check failed' };
  }
}
