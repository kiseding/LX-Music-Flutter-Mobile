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
      types: (() => { const f = item.file || {}; const q: string[] = []; if (f.size_flac && f.size_flac !== '0') q.push('flac'); if (f.size_320mp3 && f.size_320mp3 !== '0') q.push('320k'); if (!q.length && f.size_128mp3 && f.size_128mp3 !== '0') q.push('128k'); return q; })(),
    })),
    total: data.data.song.totalnum || 0, source: 'tx', limit, page,
  };
}

// Import playlist
export async function importTx(id: string) {
  // Use the old publicly-accessible API (no login required)
  const url = `https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=${encodeURIComponent(id)}&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&g_tk=5381`;
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
        types: q,
      };
    }),
  };
}
