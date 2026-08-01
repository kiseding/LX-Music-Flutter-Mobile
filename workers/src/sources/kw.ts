/**
 * 酷我音乐 source: search, import
 */

// Search
export async function searchKw(keyword: string, page: number, limit: number) {
  const pn = page - 1;
  const url = `https://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(keyword)}&pn=${pn}&rn=${limit}&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1`;
  const resp = await fetch(url, { signal: AbortSignal.timeout(8000) });
  const data: any = await resp.json();
  if (!data || (data.TOTAL === '0' || data.SHOW === '0')) return { list: [], total: 0, source: 'kw' };
  const mRe = /level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)/;
  const list: any[] = [];
  (data.abslist || []).forEach((item: any) => {
    const songId = (item.MUSICRID || '').replace('MUSIC_', '');
    const types: string[] = [];
    (item.N_MINFO || '').split(';').forEach((info: string) => {
      const m = info.match(mRe);
      if (m) { switch (m[2]) { case '4000': types.push('flac24bit'); break; case '2000': types.push('flac'); break; case '320': types.push('320k'); break; case '128': types.push('128k'); break; } }
    });
    types.reverse();
    list.push({
      name: item.SONGNAME, singer: item.ARTIST, source: 'kw', songmid: songId,
      interval: item.DURATION || '',
      img: item.web_albumpic_short ? `https://img1.kuwo.cn/star/albumcover/${item.web_albumpic_short}` : (item.web_artistpic_short ? `https://img1.kuwo.cn/star/starheads/${item.web_artistpic_short.replace(/^120\//, '500/')}` : ''),
      albumName: item.ALBUM || '', albumId: item.ALBUMID || '', types,
    });
  });
  return { list, total: parseInt(data.TOTAL) || 0, source: 'kw', limit, page };
}

// Import playlist
export async function importKw(id: string) {
  const resp = await fetch(`https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=${encodeURIComponent(id)}&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1`, {
    signal: AbortSignal.timeout(10000),
  });
  const data: any = await resp.json();
  if (!data?.musiclist) throw new Error('获取失败');
  const re = /level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)/;
  return {
    name: data.title || data.info?.name || '',
    songs: (data.musiclist || []).map((s: any) => {
      const q: string[] = [];
      (s.N_MINFO || '').split(';').forEach((i: string) => {
        const m = i.match(re);
        if (m) { switch (m[2]) { case '4000': q.push('flac24bit'); break; case '2000': q.push('flac'); break; case '320': q.push('320k'); break; case '128': q.push('128k'); break; } }
      });
      q.reverse();
      return { name: s.name, singer: s.artist, source: 'kw', songmid: s.rid ? `${s.rid}` : s.id, interval: `${s.duration || 0}`, img: s.pic || '', albumName: s.album || '', types: q };
    }),
  };
}
