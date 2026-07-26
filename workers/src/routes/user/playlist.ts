import { Env, jsonResponse, requireJsonContentType } from '../../lib/response';
import { getUserId } from '../../utils/auth';
import { fetchAndRematch } from '../playlist-import';
import type { SongInfo } from '../../utils/types';
import { songIdentity, writePlaylistAtomically } from '../../db/playlist-staging';

// P1-4: D1 is now the single source of truth for love-list / playlists. KV
// is a read-through cache, populated on save and on cache miss. This removes
// the previous dual-write race (KV first, D1 in waitUntil) that could leave
// KV ahead of D1, behind it, or missing in concurrent saves.

async function readLoveListFromD1(env: Env, userId: number): Promise<any[]> {
  const songs = await env.DB.prepare(
    "SELECT name, singer, source, songmid, album_name, album_id, img, interval, types, hash, metadata FROM playlist_songs WHERE playlist_id = 'love' AND user_id = ? ORDER BY position"
  ).bind(userId).all<any>();
  return (songs.results || []).map((s: any) => {
    let meta: any = {};
    try { meta = JSON.parse(s.metadata || '{}'); } catch { /* corrupted */ }
    return {
      name: s.name, singer: s.singer, source: s.source,
      songmid: s.songmid, albumName: s.album_name, albumId: s.album_id,
      img: s.img, interval: s.interval,
      types: JSON.parse(s.types || '[]'), hash: s.hash,
      mrcUrl: meta.mrcUrl || '', lrcUrl: meta.lrcUrl || '', trcUrl: meta.trcUrl || '',
    };
  });
}

async function readLoveList(env: Env, userId: number, _ctx: ExecutionContext): Promise<any[]> {
  return readLoveListFromD1(env, userId);
}

async function writeLoveListToD1(env: Env, userId: number, list: any[]): Promise<void> {
  await writePlaylistAtomically(env, {
    id: 'love', userId, name: '我喜欢', position: 0,
  }, list, { replace: true });
}

// GET /api/user/list — return loveList + imported playlists
export async function handleUserPlaylist(request: Request, url: URL, env: Env, ctx: ExecutionContext): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const loveList = await readLoveList(env, userId, ctx);

  // P2-2: cap rows to keep the response bounded for power users.
  const playlists = await env.DB.prepare(
    "SELECT * FROM playlists WHERE user_id = ? AND id != 'love' AND id NOT LIKE '__stage__:%' ORDER BY position LIMIT 200"
  ).bind(userId).all<any>();

  let allSongs: any[] = [];
  if (playlists.results?.length) {
    const songsResult = await env.DB.prepare(
      "SELECT * FROM playlist_songs WHERE user_id = ? AND playlist_id != ? AND playlist_id NOT LIKE '__stage__:%' ORDER BY playlist_id, position LIMIT 20000"
    ).bind(userId, 'love').all<any>();
    allSongs = songsResult.results || [];
  }

  const songsByPlaylist = new Map<string, any[]>();
  for (const s of allSongs) {
    const list = songsByPlaylist.get(s.playlist_id as string) || [];
    list.push(s);
    songsByPlaylist.set(s.playlist_id as string, list);
  }

  const userList: any[] = [];
  for (const pl of (playlists.results || [])) {
    const songs = songsByPlaylist.get(pl.id as string) || [];
    const list = songs.map((s: any) => {
      let meta: any = {};
      try { meta = JSON.parse(s.metadata || '{}'); } catch { /* corrupted */ }
      return {
        name: s.name, singer: s.singer, source: s.source,
        songmid: s.songmid, albumName: s.album_name, albumId: s.album_id,
        img: s.img, interval: s.interval,
        types: JSON.parse(s.types || '[]'), hash: s.hash,
        mrcUrl: meta.mrcUrl || '', lrcUrl: meta.lrcUrl || '', trcUrl: meta.trcUrl || '',
      };
    });
    userList.push({
      id: pl.id, name: pl.name,
      source: pl.source, source_id: pl.source_id,
      list,
    });
  }

  return jsonResponse({ loveList, userList });
}

// POST /api/user/list — save loveList / rename playlists
export async function handleUserPlaylistSave(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
  const { loveList, pls, append } = body;

  // P2-16: never let a user rename the protected 'love' playlist. The
  // A parent rewrite in the save path would otherwise reset the name to
  // '我喜欢' on the next save, causing UI/DB drift.
  if (pls?.length) {
    for (const p of pls) {
      if (p.id === 'love') continue;
      if (p.id && typeof p.name === 'string' && p.name.length > 0 && p.name.length <= 128) {
        await env.DB.prepare('UPDATE playlists SET name = ?, updated_at = datetime(\'now\') WHERE id = ? AND user_id = ?')
          .bind(p.name, p.id, userId).run();
      }
    }
  }

  if (Array.isArray(loveList) && loveList.length) {
    // P1-4: D1 is the source of truth. Write to D1 first, then update KV
    // so concurrent saves from the same user converge on a single consistent
    // state instead of one racing with another in waitUntil.
    try {
      await writeLoveListToD1(env, userId, loveList);
      ctx.waitUntil(env.CACHE.delete(`v2:love:${userId}`));
    } catch (e: any) {
      console.error('[love:d1] save failed:', e?.message);
      return jsonResponse({ error: '保存失败' }, 500);
    }
  } else if (Array.isArray(loveList) && loveList.length === 0 && !append) {
    // Clearing the love list — explicit empty array, append flag not set.
    try {
      await env.DB.prepare('DELETE FROM playlist_songs WHERE playlist_id = ? AND user_id = ?').bind('love', userId).run();
      ctx.waitUntil(env.CACHE.delete(`v2:love:${userId}`));
    } catch (e: any) {
      console.error('[love:d1:clear] failed:', e?.message);
      return jsonResponse({ error: '清空失败' }, 500);
    }
  }

  return jsonResponse({ ok: true, saved: loveList?.length || 0 });
}

// POST /api/user/love/add — incrementally add songs to the love list
// without sending the entire list back. Solves the 256KB body limit
// when the love list grows past ~1000 songs.
// Body: { songs: SongInfo[] }
export async function handleLoveAdd(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
  const songs: any[] = Array.isArray(body?.songs) ? body.songs : [];
  if (songs.length === 0) return jsonResponse({ error: '无歌曲' }, 400);
  if (songs.length > 500) return jsonResponse({ error: '单批最多500首' }, 400);

  // Read the full source-aware identity from D1 to deduplicate.
  const existing = await env.DB.prepare(
    "SELECT songmid, source FROM playlist_songs WHERE playlist_id = 'love' AND user_id = ?"
  ).bind(userId).all<{ songmid: string; source: string }>();
  const existingMids = new Set((existing.results || []).map(r => songIdentity(r.songmid, r.source)));

  // Ensure the love playlist row exists.
  await env.DB.prepare('INSERT OR IGNORE INTO playlists (id, user_id, name, position) VALUES (?, ?, ?, ?)')
    .bind('love', userId, '我喜欢', 0).run();

  // Find the current max position to append after.
  const maxPos = await env.DB.prepare(
    "SELECT MAX(position) AS m FROM playlist_songs WHERE playlist_id = 'love' AND user_id = ?"
  ).bind(userId).first<{ m: number | null }>();
  let pos = (maxPos?.m ?? -1) + 1;

  // Filter out duplicates and insert.
  const seen = new Set<string>();
  const toInsert: any[] = [];
  for (const s of songs) {
    const mid = String(s.songmid || '').slice(0, 256);
    const src = String(s.source || '').slice(0, 32);
    const key = songIdentity(mid, src);
    if (!mid || existingMids.has(key) || seen.has(key)) continue;
    seen.add(key);
    toInsert.push(s);
  }

  if (toInsert.length === 0) {
    return jsonResponse({ ok: true, added: 0, message: '全部已存在' });
  }

  // P0-1 fix: ON CONFLICT DO NOTHING. The in-memory seen / existingMids
  // checks above already filter obvious duplicates, but a concurrent
  // handleLoveAdd on another tab/isolate can still race past them. With the
  // UNIQUE INDEX in place, the INSERT now silently no-ops instead of
  // either failing or duplicating the row.
  const stmts = toInsert.map((s: any) => {
    const meta = JSON.stringify({ mrcUrl: s.mrcUrl||'', lrcUrl: s.lrcUrl||'', trcUrl: s.trcUrl||'' });
    return env.DB.prepare(
      `INSERT INTO playlist_songs (playlist_id, user_id, name, singer, source, songmid, album_name, album_id, img, interval, types, hash, metadata, position)
       VALUES ('love', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(playlist_id, user_id, songmid, source) DO NOTHING`
    ).bind(userId, (s.name||'').slice(0, 256), (s.singer||'').slice(0, 256), s.source||'', (s.songmid||'').slice(0, 256), (s.albumName||'').slice(0, 256), (s.albumId||'').slice(0, 128), (s.img||'').slice(0, 512), s.interval||'0', JSON.stringify(s.types||[]).slice(0, 1024), (s.hash||'').slice(0, 256), meta, pos++);
  });
  for (let i = 0; i < stmts.length; i += 100) {
    await env.DB.batch(stmts.slice(i, i + 100));
  }

  // Bust the KV cache so the next GET fetches fresh data from D1.
  try { ctx.waitUntil(env.CACHE.delete(`v2:love:${userId}`)); } catch {}

  return jsonResponse({ ok: true, added: toInsert.length });
}

// POST /api/user/love/remove — incrementally remove songs from the love list.
// Body: { songs: [{ songmid, source }] } or { keys: ["songmid|source", ...] }
export async function handleLoveRemove(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }

  const keys: string[] = [];
  if (Array.isArray(body?.songs)) {
    for (const s of body.songs) {
      const mid = String(s.songmid || '');
      const src = String(s.source || '');
      if (mid) keys.push(mid + '|' + src);
    }
  }
  if (Array.isArray(body?.keys)) {
    keys.push(...body.keys.filter((k: any) => typeof k === 'string' && k.length > 0));
  }
  if (keys.length === 0) return jsonResponse({ error: '无歌曲' }, 400);
  if (keys.length > 500) return jsonResponse({ error: '单批最多500首' }, 400);

  let removed = 0;
  for (const key of keys) {
    const [mid, src] = key.split('|', 2);
    const r = await env.DB.prepare(
      "DELETE FROM playlist_songs WHERE playlist_id = 'love' AND user_id = ? AND songmid = ? AND source = ?"
    ).bind(userId, mid, src || '').run();
    removed += r.meta?.changes ?? 0;
  }

  try { ctx.waitUntil(env.CACHE.delete(`v2:love:${userId}`)); } catch {}

  return jsonResponse({ ok: true, removed });
}

// DELETE /api/user/playlist?id=xxx
export async function handlePlaylistDelete(request: Request, url: URL, env: Env): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const id = url.searchParams.get('id');
  if (!id || id === 'love') return jsonResponse({ error: '无效歌单ID' }, 400);

  await env.DB.prepare('DELETE FROM playlist_songs WHERE playlist_id = ? AND user_id = ?').bind(id, userId).run();
  await env.DB.prepare('DELETE FROM playlists WHERE id = ? AND user_id = ?').bind(id, userId).run();

  return jsonResponse({ ok: true });
}


// POST /api/user/playlist/refresh — re-pull an imported playlist from its
// platform using the stored source/source_id. Replaces the songs (and the
// name, which the platform may have renamed) in-place so the local copy
// matches the latest state. Renames done locally are intentionally
// overwritten; users who want a custom name should re-rename after refresh.
export async function handlePlaylistRefresh(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }

  const id = String(body?.id || '').slice(0, 128);
  if (!id || id === 'love') return jsonResponse({ error: '无效歌单ID' }, 400);

  const pl = await env.DB.prepare(
    'SELECT id, name, source, source_id FROM playlists WHERE id = ? AND user_id = ?'
  ).bind(id, userId).first<{ id: string; name: string; source: string; source_id: string }>();
  if (!pl) return jsonResponse({ error: '歌单不存在' }, 404);
  // An imported playlist must have a source + source_id to be refreshable.
  // The 'love' playlist and any future purely-local playlists fall through here.
  if (!pl.source || !pl.source_id) return jsonResponse({ error: '该歌单不支持刷新' }, 400);

  let info;
  try {
    info = await fetchAndRematch(pl.source, pl.source_id, env);
  } catch (err: any) {
    // P2-10: generic message to user; log details server-side.
    console.error('[refresh]', pl.source, pl.source_id, err?.message);
    return jsonResponse({ error: '刷新失败：歌单已失效或网络异常' }, 500);
  }
  const songs: SongInfo[] = (info.songs || []).filter((s: SongInfo) => s && s.name);
  if (!songs.length) return jsonResponse({ error: '歌单为空或已失效' }, 400);

  const newName = String(info.name || pl.name || '').slice(0, 128);
  try {
    await writePlaylistAtomically(env, {
      id, userId, name: newName, position: 10, source: pl.source, sourceId: pl.source_id,
    }, songs, { replace: true });
  } catch (err: any) {
    console.error('[refresh:save]', err?.message);
    return jsonResponse({ error: '刷新保存失败' }, 500);
  }

  return jsonResponse({ ok: true, playlist: { id, name: newName, source: pl.source, count: songs.length } });
}
