/**
 * 网易云音乐 source: search, lyric, import
 */
import { aes128BlockEncrypt } from '../utils/crypto';

// Search — uses the plain-text /api/search/get endpoint (no eapi encryption).
// The previous eapi AES path produced ciphertext that NetEase's server rejected
// (returned 200 with empty body) when called from Cloudflare Workers because
// Web Crypto's AES-CBC(IV=0) does not match Node OpenSSL AES-128-ECB block
// encryption at the boundaries. The plaintext endpoint is reliable and keeps
// the same response shape.
export async function searchWy(keyword: string, page: number, limit: number) {
  try { return await _searchWyInner(keyword, page, limit); }
  catch (err: any) {
    console.error('[wy] search failed:', err?.message);
    return { list: [], total: 0, source: 'wy' };
  }
}
async function _searchWyInner(keyword: string, page: number, limit: number) {
  const offset = limit * (page - 1);
  const searchUrl = `https://music.163.com/api/search/get?s=${encodeURIComponent(keyword)}&type=1&limit=${limit}&offset=${offset}`;
  const resp = await fetch(searchUrl, {
    headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36', 'Referer': 'https://music.163.com/' },
    signal: AbortSignal.timeout(8000),
  });
  const rawText = await resp.text();
  let result: any;
  try { result = JSON.parse(rawText); }
  catch {
    throw new Error('search upstream not JSON (status ' + resp.status + '): ' + rawText.substring(0, 200));
  }
  const songs: any[] = result?.result?.songs || [];
  if (!result || result.code !== 200 || !songs.length) {
    console.error('[wy] empty result: status=', resp.status, 'body_len=', rawText.length, 'code=', result?.code);
    return { list: [], total: 0, source: 'wy', limit, page };
  }
  const songCount = Number(result.result?.songCount || songs.length);
  // Enrich each song with quality info (h/m/l/sq/hr + maxbr) by calling
  // /api/v3/song/detail in one batch. Falls back to empty types if it fails.
  const detailMap = await fetchWySongDetail(songs.map(s => s.id));
  const list = songs.map((s: any) => {
    const id = String(s.id || '');
    const detail = detailMap.get(id);
    const q: string[] = [];
    if (detail) {
      if (detail.hr) q.push('flac24bit');
      if (detail.sq) q.push('flac');
      if (detail.h) q.push('320k');
      else if (detail.m) q.push('192k');
      if (detail.l) q.push('128k');
    }
    if (!q.length) q.push('128k');
    // /api/search/get returns only the album's numeric picId and no cover
    // URL (the storage-hash part is missing). Re-use the cover from the
    // song-detail batch, which always carries al.picUrl.
    const img = detail?.al?.picUrl || '';
    return {
      name: s.name || '',
      singer: (s.artists || []).map((a: any) => a.name).join('、'),
      source: 'wy',
      songmid: id,
      interval: s.duration ? String(Math.floor(s.duration / 1000)) : '',
      img,
      albumName: s.album?.name || detail?.al?.name || '',
      albumId: String(s.album?.id || detail?.al?.id || ''),
      types: q,
    };
  })
  // Drop demos / ringtones / clip previews. Anything under a minute is
  // almost always noise NetEase surfaces in /api/search/get results.
  .filter((s: any) => !s.interval || parseInt(s.interval, 10) >= 60);
  return { list, total: songCount, source: 'wy', limit, page };
}
// Batch-fetch song quality (h/m/l/sq/hr) for a list of NetEase song IDs.
// Returns Map<songmid-as-string, songDetailObject>. Returns empty map on
// any failure so the caller can degrade gracefully.
async function fetchWySongDetail(ids: Array<number | string>): Promise<Map<string, any>> {
  const map = new Map<string, any>();
  if (!ids.length) return map;
  const cleanIds = ids.map(id => Number(id)).filter(n => Number.isFinite(n) && n > 0);
  if (!cleanIds.length) return map;
  // NetEase returns code:-462 (anti-bot / verify challenge) often enough
  // on /api/v3/song/detail from Cloudflare edges that we have to defend
  // against it. Splitting into sub-batches of 2 IDs limits blast radius,
  // and an exponential backoff clears the challenge within a few tries.
  const subBatches: number[][] = [];
  for (let i = 0; i < cleanIds.length; i += 2) subBatches.push(cleanIds.slice(i, i + 2));
  const detailHeaders = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36', 'Referer': 'https://music.163.com/', 'Origin': 'https://music.163.com', 'Accept': 'application/json, text/plain, */*' };
  for (const batch of subBatches) {
    const c = '[' + batch.map(id => JSON.stringify({ id })).join(',') + ']';
    const url = 'https://music.163.com/api/v3/song/detail?c=' + encodeURIComponent(c);
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const resp = await fetch(url, { headers: detailHeaders, signal: AbortSignal.timeout(6000) });
        const data: any = await resp.json();
        if (data?.code === -462) {
          await new Promise(r => setTimeout(r, 400 * Math.pow(2, attempt)));
          continue;
        }
        const songs: any[] = data?.songs || [];
        songs.forEach((s: any) => { if (s.id) map.set(String(s.id), s); });
        break;
      } catch (err: any) {
        await new Promise(r => setTimeout(r, 200 * (attempt + 1)));
      }
    }
  }
  return map;
}

// Import playlist
export async function importWy(id: string) {
  const linuxapiKey = new TextEncoder().encode('rFgB&h#%2?^eDg:Q');
  const reqBody = JSON.stringify({ method: 'POST', url: 'https://music.163.com/api/v3/playlist/detail', params: { id: id.replace(/\D/g, ''), n: 100000, s: 8 } });
  const encrypted = await aes128BlockEncrypt(linuxapiKey.buffer as ArrayBuffer, new TextEncoder().encode(reqBody).buffer as ArrayBuffer);
  const eparams = Array.from(new Uint8Array(encrypted)).map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
  const resp = await fetch('https://music.163.com/api/linux/forward', {
    method: 'POST',
    headers: { 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36', 'Origin': 'https://music.163.com', 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `eparams=${encodeURIComponent(eparams)}`,
    signal: AbortSignal.timeout(10000),
  });
  const data: any = await resp.json();
  if (data.code !== 200 || !data.playlist) throw new Error('获取歌单失败');
  const trackIds = data.playlist.trackIds || [];
  const tracks = data.playlist.tracks || [];
  const privileges = data.privileges || [];
  const songs = (tracks.length ? tracks : trackIds).map((item: any, index: number) => {
    const s = item.id ? item : null;
    const privilege = privileges[index] || (s ? privileges.find((p: any) => p.id === s.id) : null);
    const q: string[] = [];
    if (privilege) {
      if (privilege.maxBrLevel === 'hires') q.push('flac24bit');
      if (privilege.maxbr >= 999000) q.push('flac');
      if (privilege.maxbr >= 320000) q.push('320k');
      if (privilege.maxbr >= 128000) q.push('128k');
    }
    if (s) {
      return {
        name: s.name || '', singer: (s.ar || []).map((a: any) => a.name).join('、'),
        source: 'wy', songmid: `${s.id}`, interval: s.dt ? `${Math.floor(s.dt / 1000)}` : '',
        img: s.al?.picUrl || '', albumName: s.al?.name || '', albumId: `${s.al?.id || ''}`, types: q,
      };
    }
    return { name: '', singer: '', source: 'wy', songmid: `${item.id}`, interval: '', img: '', albumName: '', types: [] };
  }).filter((s: any) => s.songmid);
  return { name: data.playlist.name || '', songs };
}

