/**
 * 酷我音乐 source: search, lyric, import
 */
import { bufferToBase64, inflate, decodeGb18030 } from '../utils/crypto';

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

// Lyric (XOR + inflate encrypted format)
export async function lyricKw(songmid: string) {
  try {
    const key = new TextEncoder().encode('yeelion');
    const plain = `user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_${songmid}`;
    const data = new TextEncoder().encode(plain);
    const xored = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i++) xored[i] = data[i] ^ key[i % key.length];
    const b64 = bufferToBase64(xored);
    const resp = await fetch(`https://newlyric.kuwo.cn/newlyric.lrc?${b64}`, { signal: AbortSignal.timeout(8000) });
    const raw = new Uint8Array(await resp.arrayBuffer());
    let bodyStart = -1;
    for (let i = 0; i < raw.length - 3; i++) {
      if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) { bodyStart = i + 4; break; }
    }
    if (bodyStart > 0) {
      const body = raw.slice(bodyStart);
      const decompressed = await inflate(body);
      const text = decodeGb18030(decompressed);
      if (text && text.includes('[')) {
        const lines: string[] = [];
        const re = /\[(\d+):(\d+(?:\.\d+)?)\]([^\[]*)/g;
        let m;
        while ((m = re.exec(text)) !== null) {
          const min = parseInt(m[1]), sec = parseFloat(m[2]), txt = m[3].trim();
          if (txt) lines.push(`[${fmtTime(min * 60 + sec)}]${txt}`);
        }
        if (lines.length) return { lyric: lines.join('\n'), tlyric: '' };
      }
    }
  } catch (e) { console.error('kw lyric fetch error:', e); }
  return { lyric: '', tlyric: '' };
}

// Import playlist
export async function importKw(id: string) {
  const resp = await fetch(`https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=${id}&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1`, {
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

function fmtTime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  const ms = Math.floor((seconds % 1) * 100);
  return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}.${ms.toString().padStart(2, '0')}`;
}
