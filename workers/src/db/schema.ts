import type { Env } from '../lib/response';

export type SchemaReadiness =
  | { ready: true }
  | { ready: false; reason: string };

const READY_CACHE_KEY = 'v2:system:schema_ready';
const READY_CACHE_TTL = 300; // 5 minutes; only consulted once ready
const NOT_READY_CACHE_TTL = 30;

export async function checkSchemaReady(env: Env): Promise<SchemaReadiness> {
  // O1: cache readiness in KV so we don't run a 3-query D1 batch on every
  // request. Only "ready" is cached long-term; a pending-migration state is
  // re-checked after a short TTL so a just-applied migration unblocks fast.
  try {
    const cached = await env.CACHE.get(READY_CACHE_KEY);
    if (cached) return { ready: true };
  } catch {
    // KV read failure is non-fatal; fall through to the DB check.
  }

  let readiness: SchemaReadiness;
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
    readiness = tableCount === 8 && hasTokenVersion && indexCount === 1
      ? { ready: true }
      : { ready: false, reason: 'D1 migrations are pending' };
  } catch {
    readiness = { ready: false, reason: 'D1 readiness check failed' };
  }

  try {
    if (readiness.ready) {
      await env.CACHE.put(READY_CACHE_KEY, '1', { expirationTtl: READY_CACHE_TTL });
    } else {
      await env.CACHE.delete(READY_CACHE_KEY);
    }
  } catch {
    // Cache write failure is non-fatal.
  }
  return readiness;
}
