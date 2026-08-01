/**
 * Playlist import: two-phase — preview then save
 */
import { Env, jsonResponse, requireJsonContentType, readJsonBody } from '../lib/response';
import { requireAuth } from '../utils/auth';
import { RateLimiter, RateLimiterUnavailableError, getClientIP } from '../middleware/rateLimit';
import { importTx, searchTx } from '../sources/tx';
import { importKw, searchKw } from '../sources/kw';
import { importWy, searchWy } from '../sources/wy';
import type { PlaylistImportSaveBody, PlaylistImportResult, SongInfo } from '../utils/types';
import { bestQuality } from '../utils/quality';
import { writePlaylistAtomically } from '../db/playlist-staging';

const VALID_SOURCES = new Set(['tx', 'kw', 'wy']);

// No hard cap on playlist size. D1 batch writes are chunked at 100
// statements internally, so even a 10000-song playlist just becomes
// 100 sequential batches. Clients that want to be extra safe can
// split into multiple Phase-2 requests with the same `playlistId`
// to append in batches.

// Rematch imported songs across all platforms, pick the one with best quality.
// A bounded concurrency pool limits outbound requests (Workers cap subrequests).
const REMATCH_CONCURRENCY = 10;

async function runPooled<T>(items: T[], concurrency: number, worker: (item: T, index: number) => Promise<void>): Promise<void> {
  let cursor = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      await worker(items[index], index);
    }
  });
  await Promise.all(runners);
}

export async function rematchSongs(songs: SongInfo[]): Promise<SongInfo[]> {
  const out: SongInfo[] = new Array(songs.length);
  await runPooled(songs, REMATCH_CONCURRENCY, async (s, index) => {
    if (!s.name) { out[index] = s; return; }
    const kw = `${s.name} ${s.singer || ''}`.trim();

    const searchers = [
      { src: 'tx', fn: searchTx, getMid: (m: any) => m.songmid || '' },
      { src: 'kw', fn: searchKw, getMid: (m: any) => m.hash || m.songmid || '' },
      { src: 'wy', fn: searchWy, getMid: (m: any) => m.songmid || '' },
    ];

    let best: { song: SongInfo; score: number } = {
      score: bestQuality(s.types || []),
      song: { ...s },
    };

    // Run all source searches in parallel; pick the highest-quality match across them.
    const allResults = await Promise.all(
      searchers.map(async (searcher) => {
        try {
          const result = await searcher.fn(kw, 1, 3);
          return { searcher, list: (result as any).list || [] };
        } catch { return { searcher, list: [] as any[] }; }
      })
    );

    for (const { searcher, list } of allResults) {
      for (const m of list) {
        const qs = bestQuality(m.types || []);
        if (qs < best.score) {
          best = {
            score: qs,
            song: {
              ...s,
              source: searcher.src,
              songmid: searcher.getMid(m),
              types: m.types || s.types,
              img: m.img || s.img,
              interval: m.interval || s.interval,
              albumName: m.albumName || s.albumName,
            },
          };
        }
      }
    }

    out[index] = best.song;
  });
  return out;
}

const IMPORT_IP_MAX = 30;
const IMPORT_WINDOW_SECONDS = 300;

export async function handlePlaylistImport(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  const parsed = await readJsonBody(request);
  if (parsed instanceof Response) return parsed;
  const body = parsed.body as any;

  // 预览与保存都需要登录；未认证的 Phase 1 预览会触发大量上游请求，必须限流。
  const auth = await requireAuth(request, env);
  if (auth instanceof Response) return auth;
  const userId = auth.userId;

  const ip = getClientIP(request);
  const limiter = new RateLimiter(env.RATE_LIMITER);
  try {
    const rateCheck = await limiter.check(ip, [
      { key: `import:${userId}`, max: IMPORT_IP_MAX, windowSeconds: IMPORT_WINDOW_SECONDS },
    ]);
    if (!rateCheck.allowed) {
      return jsonResponse({ error: '导入过于频繁，请稍后再试', retryAfter: Math.ceil((rateCheck.resetAt - Date.now()) / 1000) }, 429);
    }
  } catch (error) {
    if (error instanceof RateLimiterUnavailableError) {
      return jsonResponse({ error: '导入服务暂时不可用' }, 503, { 'Retry-After': '60' });
    }
    throw error;
  }

  // Phase 2: save songs to D1
  if (body.songs?.length && body.name) {

    const source = body.source || '';
    const sourceId = String(body.sourceId || '');
    if (!VALID_SOURCES.has(source)) {
      return jsonResponse({ error: '不支持的音源' }, 400);
    }
    // S2: source_id 会被拼进上游 URL，必须限定为纯数字，防止参数注入。
    if (sourceId.length === 0 || !/^\d+$/.test(sourceId)) {
      return jsonResponse({ error: '无效的歌单ID' }, 400);
    }
    // Drop any songs whose source slipped past the whitelist (legacy clients sending kg/mg).
    const cleanSongs = (body as PlaylistImportSaveBody).songs.filter((s: SongInfo) => VALID_SOURCES.has(s.source || ''));
    if (cleanSongs.length === 0) {
      return jsonResponse({ error: '歌单不含可播放的歌曲' }, 400);
    }

    // Support appending to an existing playlist: if the client sends a
    // `playlistId`, we verify it belongs to this user and append songs
    // at the next available position. This lets the client split a
    // very large playlist into multiple Phase-2 requests.
    let plId: string;
    let startPosition: number;
    let existingPlaylist: { id: string; name: string; position: number; source: string; source_id: string } | null = null;
    if (body.playlistId) {
      plId = String(body.playlistId).slice(0, 128);
      existingPlaylist = await env.DB.prepare(
        'SELECT id, name, position, source, source_id FROM playlists WHERE id = ? AND user_id = ?'
      ).bind(plId, userId).first<{ id: string; name: string; position: number; source: string; source_id: string }>();
      if (!existingPlaylist) {
        return jsonResponse({ error: '目标歌单不存在' }, 404);
      }
      // Find the current max position to append after.
      const maxPos = await env.DB.prepare(
        'SELECT MAX(position) AS m FROM playlist_songs WHERE playlist_id = ? AND user_id = ?'
      ).bind(plId, userId).first<{ m: number | null }>();
      startPosition = (maxPos?.m ?? -1) + 1;
    } else {
      plId = `imp_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`;
      startPosition = 0;
    }

    try {
      if (!body.playlistId && body.name === 'love') {
        return jsonResponse({ error: '无效歌单名' }, 400);
      }
      await writePlaylistAtomically(env, {
        id: plId,
        userId,
        name: existingPlaylist?.name || String(body.name).slice(0, 128),
        position: existingPlaylist?.position ?? 10,
        source: existingPlaylist?.source || source,
        sourceId: existingPlaylist?.source_id || sourceId,
      }, cleanSongs, { replace: !body.playlistId, startPosition });
      return jsonResponse({ ok: true, playlist: { id: plId, name: body.name, source, count: cleanSongs.length, appended: !!body.playlistId } });
    } catch (err: unknown) {
      // P2-10: generic message to user; log details server-side.
      console.error('[import:save]', err);
      return jsonResponse({ error: '保存失败' }, 500);
    }
  }

  // Phase 1: fetch playlist preview
  const { url, platform } = body;
  if (!url) return jsonResponse({ error: '缺少歌单链接' }, 400);

  // Always try URL detection first; platform from dropdown is fallback
  let source = '', listId = '';

  const trimmed = url.trim();
  // If user input is a plain number, treat it as ID for the selected platform
  const isPlainId = /^\d+$/.test(trimmed);

  if (url.includes('y.qq.com') || url.includes('i.y.qq.com')) {
    source = 'tx';
    const m = url.match(/[?&]id=(\d+)/) || url.match(/playlist\/(\d+)/) || url.match(/songList\/(\d+)/) || url.match(/taoge\/(\d+)/) || url.match(/\/(\d{5,})/);
    if (m) listId = m[1];
  } else if (url.includes('kuwo.cn')) {
    source = 'kw';
    const m = url.match(/[?&]id=(\d+)/) || url.match(/playlist\/(\d+)/) || url.match(/pid=(\d+)/) || url.match(/detail\/(\d+)/);
    if (m) listId = m[1];
  } else if (url.includes('music.163.com') || url.includes('163.com')) {
    source = 'wy';
    const m = url.match(/[?&]id=(\d+)/) || url.match(/playlist\/(\d+)/);
    if (m) listId = m[1];
  }

  // Fallback: use platform from dropdown + clean ID extraction
  if (!source && platform && ['tx','kw','wy'].includes(platform) && isPlainId) {
    source = platform;
    listId = trimmed;
  }

  if (!source || !listId) {
    return jsonResponse({ error: '无法识别，请选择平台后输入歌单链接或ID' }, 400);
  }

  try {
    const info = await fetchPlaylistInfo(source, listId, env);
    if (!info.songs?.length) throw new Error('歌单为空或ID无效');
    const rematched = await rematchSongs(info.songs);
    return jsonResponse({ songs: rematched, name: info.name, source, listId });
  } catch (err: unknown) {
    // P2-10: don't leak upstream error text (URLs, stack traces, internal
    // endpoint names). Server-side log keeps the details.
    const message = err instanceof Error ? err.message : '未知错误';
    console.error(`[import] ${source}/${listId}: ${message}`);
    const userMsg = /^\d+$/.test(listId) || message === '歌单为空或ID无效' ? message : '歌单获取失败';
    return jsonResponse({ error: userMsg }, 500);
  }
}

// One-shot helper used by the playlist-refresh endpoint: fetches the
// playlist from its source platform and rematches every song across all
// three platforms so we get the best-quality copy (same path Phase-1
// preview + Phase-2 save take during the initial import).
export async function fetchAndRematch(source: string, sourceId: string, env: Env): Promise<PlaylistImportResult> {
  const raw = await fetchPlaylistInfo(source, sourceId, env);
  const rematched = await rematchSongs(raw.songs);
  return { ...raw, songs: rematched };
}
export async function fetchPlaylistInfo(source: string, id: string, env?: Env): Promise<PlaylistImportResult> {
  console.log(`[import] fetching ${source} playlist: ${id}`);
  const e = env as (Env & { TINYAPI_KEY?: string }) | undefined;
  switch (source) {
    case 'tx': return importTx(id);
    case 'kw': return importKw(id);
    case 'wy': return e?.TINYAPI_KEY ? importWyTiny(id, e) : importWy(id);
    default: throw new Error('不支持的平台');
  }
}

export async function importWyTiny(id: string, env: Env): Promise<PlaylistImportResult> {
  const key = (env as any).TINYAPI_KEY as string || '';
  const resp = await fetch(`https://api.tinyaii.top/v1/netease/playlist?id=${encodeURIComponent(id)}`, {
    headers: { 'Authorization': `Bearer ${key}` },
    signal: AbortSignal.timeout(15000),
  });
  const data: any = await resp.json();
  if (data.code !== 200 || !data.data?.songs?.length) throw new Error('歌单为空或ID无效');
  return {
    name: data.data.name || '网易云歌单',
    songs: data.data.songs.map((s: any) => ({
      name: s.name || s.title || '',
      singer: s.artist || s.singer || '',
      source: 'wy',
      songmid: String(s.id || ''),
      interval: String(s.duration || 0),
      img: s.pic || s.cover || '',
      albumName: s.album || '',
    })),
  };
}
