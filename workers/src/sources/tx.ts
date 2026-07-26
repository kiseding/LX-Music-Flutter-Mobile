/**
 * QQ音乐 source: search, lyric, import
 */

// Search
export async function searchTx(keyword: string, page: number, limit: number) {
  const url = `https://shc.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=${page}&n=${limit}&w=${encodeURIComponent(keyword)}&cr=1&new_json=1`;
  const resp = await fetch(url, {
    headers: { 'Referer': 'https://y.qq.com', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
    // P1-6: hard timeout so a hanging upstream doesn't pin the whole Worker.
    signal: AbortSignal.timeout(8000),
  });
  const data: any = await resp.json();
  if (data.code !== 0 || !data.data?.song?.list) return { list: [], total: 0, source: 'tx' };
  return {
    list: data.data.song.list.map((item: any) => ({
      name: item.name || item.title,
      singer: item.singer?.map((s: any) => s.name).join('、') || '',
      source: 'tx', songmid: item.mid || item.songmid,
      interval: item.interval ? `${item.interval}` : '',
      img: item.album?.mid ? `https://y.gtimg.cn/music/photo_new/T002R300x300M000${item.album.mid}.jpg` : `https://y.gtimg.cn/music/photo_new/T001R300x300M000${item.singer?.[0]?.mid}.jpg`,
      albumName: item.album?.name || '', albumId: item.album?.mid || '',
      strMediaMid: item.file?.strMediaMid || item.strMediaMid,
      types: (() => { const f = item.file || {}; const q: string[] = []; if (f.size_flac && f.size_flac !== '0') q.push('flac'); if (f.size_320mp3 && f.size_320mp3 !== '0') q.push('320k'); if (!q.length && f.size_128mp3 && f.size_128mp3 !== '0') q.push('128k'); return q; })(),
    })),
    total: data.data.song.totalnum || 0, source: 'tx', limit, page,
  };
}

// Simple search for AI recs
export async function searchTxSimple(keyword: string, n = 15): Promise<any[]> {
  const resp = await fetch(`https://shc.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=${n}&w=${encodeURIComponent(keyword)}&cr=1&new_json=1`, {
    headers: { 'Referer': 'https://y.qq.com', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
    signal: AbortSignal.timeout(6000),
  });
  const d: any = await resp.json();
  if (d.code !== 0 || !d.data?.song?.list) return [];
  return d.data.song.list.map((item: any) => {
    const f = item.file || {};
    const q: string[] = [];
    if (f.size_hires && f.size_hires !== '0') q.push('flac24bit');
    if (f.size_flac && f.size_flac !== '0') q.push('flac');
    if (f.size_320mp3 && f.size_320mp3 !== '0') q.push('320k');
    if (!q.length) q.push('128k');
    return {
      name: item.name || item.title,
      singer: (item.singer || []).map((s: any) => s.name).join('、'),
      source: 'tx', songmid: item.mid || item.songmid || '',
      interval: String(item.interval || 0),
      img: item.album?.mid ? `https://y.gtimg.cn/music/photo_new/T002R300x300M000${item.album.mid}.jpg` : '',
      albumName: item.album?.name || '', types: q,
    };
  });
}

// Lyric
export async function lyricTx(songmid: string) {
  const resp = await fetch(`https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=${songmid}&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq`, {
    headers: { 'Referer': 'https://y.qq.com/portal/player.html', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
    signal: AbortSignal.timeout(6000),
  });
  const data: any = await resp.json();
  if (data.code !== 0) throw new Error('获取歌词失败');
  try {
    const lyric = data.lyric ? decodeBase64Utf8(data.lyric) : '';
    const trans = data.trans ? decodeBase64Utf8(data.trans) : '';
    return { lyric: decodeHtmlEntities(lyric), tlyric: decodeHtmlEntities(trans) };
  } catch { return { lyric: data.lyric || '', tlyric: '' }; }
}

// Import playlist
export async function importTx(id: string) {
  // Use the old publicly-accessible API (no login required)
  const url = `https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=${id}&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&g_tk=5381`;
  const resp = await fetch(url, {
    headers: { 'Referer': 'https://y.qq.com/portal/player.html', 'Origin': 'https://y.qq.com', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' },
    signal: AbortSignal.timeout(10000),
  });
  const data: any = await resp.json();
  if (data.code !== 0 || !data.cdlist?.[0]?.songlist) {
    console.error('[importTx] failed:', JSON.stringify(data).substring(0,500));
    throw new Error(data.msg || data.cdlist?.[0]?.msg || '获取歌单失败');
  }
  const cd = data.cdlist[0];
  return {
    name: cd.dissname || '',
    songs: cd.songlist.map((s: any) => {
      const f = s.file || {}; const q: string[] = [];
      if (f.size_hires && f.size_hires !== '0') q.push('flac24bit');
      if (f.size_flac && f.size_flac !== '0') q.push('flac');
      if (f.size_320mp3 && f.size_320mp3 !== '0') q.push('320k');
      if (!q.length && f.size_128mp3 && f.size_128mp3 !== '0') q.push('128k');
      return {
        name: s.title || s.name, singer: (s.singer || []).map((x: any) => x.name).join('、'),
        source: 'tx', songmid: s.mid || s.songmid,
        interval: `${s.interval || 0}`,
        img: s.album?.mid ? `https://y.gtimg.cn/music/photo_new/T002R300x300M000${s.album.mid}.jpg` : '',
        albumName: s.album?.name || '', albumId: s.album?.mid || '',
        strMediaMid: f.strMediaMid || s.strMediaMid, types: q,
      };
    }),
  };
}

// Leaderboard
export async function leaderboardTx() {
  // Get period — retry once on failure
  let period = '';
  for (let i = 0; i < 2; i++) {
    try {
      const htmlResp = await fetch('https://c.y.qq.com/node/pc/wk_v15/top.html', {
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
        signal: AbortSignal.timeout(i === 0 ? 5000 : 10000),
      });
      const html = await htmlResp.text();
      const periodMatch = html.match(/data-tid=".*?\/26" data-date="(\d{4}-\d{2}-\d{2})"/);
      if (periodMatch) { period = periodMatch[1]; break; }
    } catch (e) { console.error('leaderboard period fetch error:', e); }
  }

  const resp = await fetch('https://u.y.qq.com/cgi-bin/musicu.fcg', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      toplist: { module: 'musicToplist.ToplistInfoServer', method: 'GetDetail', param: { topid: 26, num: 100, period } },
      comm: { uin: 0, format: 'json', ct: 20, cv: 1859 },
    }),
    signal: AbortSignal.timeout(8000),
  });
  const data: any = await resp.json();
  if (data?.code !== 0 || !data?.toplist?.data?.songInfoList) return [];
  const seen = new Set<string>();
  return data.toplist.data.songInfoList
    .filter((item: any) => {
      const mid = item.mid || '';
      if (!mid || seen.has(mid)) return false;
      seen.add(mid);
      return true;
    })
    .slice(0, 100)
    .map((item: any) => {
      const f = item.file || {}; const q: string[] = [];
      if (f.size_hires && f.size_hires !== '0') q.push('flac24bit');
      if (f.size_flac && f.size_flac !== '0') q.push('flac');
      if (f.size_320mp3 && f.size_320mp3 !== '0') q.push('320k');
      if (!q.length) q.push('128k');
      return {
        name: item.title || item.name, singer: (item.singer || []).map((s: any) => s.name).join('、'),
        source: 'tx', songmid: item.mid, interval: String(item.interval || 0),
        img: item.album?.mid ? `https://y.gtimg.cn/music/photo_new/T002R500x500M000${item.album.mid}.jpg` : '',
        albumName: item.album?.name || '', albumId: item.album?.mid || '', types: q,
      };
    });
}

// Hot search
export async function hotSearchTx() {
  const resp = await fetch('https://c.y.qq.com/splcloud/fcgi-bin/get_hot_key.fcg?g_tk=5381&loginUin=0&format=json', {
    headers: { 'Referer': 'https://y.qq.com', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' },
    signal: AbortSignal.timeout(6000),
  });
  const data: any = await resp.json();
  if (data.code !== 0 || !data.data?.hotkey) return [];
  return (data.data.hotkey || []).slice(0, 20).map((item: any) => ({ name: item.k || '', heat: item.n || 0 }));
}

function decodeBase64Utf8(s: string): string {
  try { return new TextDecoder().decode(Uint8Array.from(atob(s), c => c.charCodeAt(0))); } catch { return s; }
}

function decodeHtmlEntities(s: string): string {
  return s.replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d)))
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'");
}
