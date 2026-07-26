/**
 * Workers-compatible crypto utilities
 * Replaces Node.js crypto/zlib with Web Crypto API
 */

export function md5Sync(data: string): string {
  return md5js(data);
}

// Pure JS MD5 implementation (for sync use)
function md5js(string: string): string {
  function cmn(q: number, a: number, b: number, x: number, s: number, t: number) {
    return add32((((a + q + x + t) >>> 0) << s) | ((a + q + x + t) >>> (32 - s)), b);
  }
  function add32(a: number, b: number) { return ((a + b) & 0xffffffff) >>> 0; }
  function ff(a: number, b: number, c: number, d: number, x: number, s: number, t: number) {
    return cmn((b & c) | ((~b) & d), a, b, x, s, t);
  }
  function gg(a: number, b: number, c: number, d: number, x: number, s: number, t: number) {
    return cmn((b & d) | (c & (~d)), a, b, x, s, t);
  }
  function hh(a: number, b: number, c: number, d: number, x: number, s: number, t: number) {
    return cmn(b ^ c ^ d, a, b, x, s, t);
  }
  function ii(a: number, b: number, c: number, d: number, x: number, s: number, t: number) {
    return cmn(c ^ (b | (~d)), a, b, x, s, t);
  }

  const x: number[] = [];
  let k = 0;
  const len = string.length;
  for (let i = 0; i < len; i++) {
    x[k >> 2] |= string.charCodeAt(i) << ((k % 4) * 8);
    k++;
  }
  x[k >> 2] |= 0x80 << ((k % 4) * 8);
  const nblk = ((len + 8) >> 6) + 1;
  for (let i = k + 1; i < nblk * 16; i++) x[i >> 2] |= 0;

  // Append original length in bits as 64-bit little-endian at end of last block
  const bitLen = len * 8;
  x[nblk * 16 - 2] = bitLen >>> 0;       // low 32 bits
  x[nblk * 16 - 1] = (bitLen / 0x100000000) >>> 0; // high 32 bits

  let a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
  for (let i = 0; i < x.length; i += 16) {
    const olda = a, oldb = b, oldc = c, oldd = d;
    a = ff(a, b, c, d, x[i] as number, 7, -680876936);
    d = ff(d, a, b, c, x[i+1] as number, 12, -389564586);
    c = ff(c, d, a, b, x[i+2] as number, 17, 606105819);
    b = ff(b, c, d, a, x[i+3] as number, 22, -1044525330);
    a = ff(a, b, c, d, x[i+4] as number, 7, -176418897);
    d = ff(d, a, b, c, x[i+5] as number, 12, 1200080426);
    c = ff(c, d, a, b, x[i+6] as number, 17, -1473231341);
    b = ff(b, c, d, a, x[i+7] as number, 22, -45705983);
    a = ff(a, b, c, d, x[i+8] as number, 7, 1770035416);
    d = ff(d, a, b, c, x[i+9] as number, 12, -1958414417);
    c = ff(c, d, a, b, x[i+10] as number, 17, -42063);
    b = ff(b, c, d, a, x[i+11] as number, 22, -1990404162);
    a = ff(a, b, c, d, x[i+12] as number, 7, 1804603682);
    d = ff(d, a, b, c, x[i+13] as number, 12, -40341101);
    c = ff(c, d, a, b, x[i+14] as number, 17, -1502002290);
    b = ff(b, c, d, a, x[i+15] as number, 22, 1236535329);
    a = gg(a, b, c, d, x[i+1] as number, 5, -165796510);
    d = gg(d, a, b, c, x[i+6] as number, 9, -1069501632);
    c = gg(c, d, a, b, x[i+11] as number, 14, 643717713);
    b = gg(b, c, d, a, x[i] as number, 20, -373897302);
    a = gg(a, b, c, d, x[i+5] as number, 5, -701558691);
    d = gg(d, a, b, c, x[i+10] as number, 9, 38016083);
    c = gg(c, d, a, b, x[i+15] as number, 14, -660478335);
    b = gg(b, c, d, a, x[i+4] as number, 20, -405537848);
    a = gg(a, b, c, d, x[i+9] as number, 5, 568446438);
    d = gg(d, a, b, c, x[i+14] as number, 9, -1019803690);
    c = gg(c, d, a, b, x[i+3] as number, 14, -187363961);
    b = gg(b, c, d, a, x[i+8] as number, 20, 1163531501);
    a = gg(a, b, c, d, x[i+13] as number, 5, -1444681467);
    d = gg(d, a, b, c, x[i+2] as number, 9, -51403784);
    c = gg(c, d, a, b, x[i+7] as number, 14, 1735328473);
    b = gg(b, c, d, a, x[i+12] as number, 20, -1926607734);
    a = hh(a, b, c, d, x[i+5] as number, 4, -378558);
    d = hh(d, a, b, c, x[i+8] as number, 11, -2022574463);
    c = hh(c, d, a, b, x[i+11] as number, 16, 1839030562);
    b = hh(b, c, d, a, x[i+14] as number, 23, -35309556);
    a = hh(a, b, c, d, x[i+1] as number, 4, -1530992060);
    d = hh(d, a, b, c, x[i+4] as number, 11, 1272893353);
    c = hh(c, d, a, b, x[i+7] as number, 16, -155497632);
    b = hh(b, c, d, a, x[i+10] as number, 23, -1094730640);
    a = hh(a, b, c, d, x[i+13] as number, 4, 681279174);
    d = hh(d, a, b, c, x[i] as number, 11, -358537222);
    c = hh(c, d, a, b, x[i+3] as number, 16, -722521979);
    b = hh(b, c, d, a, x[i+6] as number, 23, 76029189);
    a = hh(a, b, c, d, x[i+9] as number, 4, -640364487);
    d = hh(d, a, b, c, x[i+12] as number, 11, -421815835);
    c = hh(c, d, a, b, x[i+15] as number, 16, 530742520);
    b = hh(b, c, d, a, x[i+2] as number, 23, -995338651);
    a = ii(a, b, c, d, x[i] as number, 6, -198630844);
    d = ii(d, a, b, c, x[i+7] as number, 10, 1126891415);
    c = ii(c, d, a, b, x[i+14] as number, 15, -1416354905);
    b = ii(b, c, d, a, x[i+5] as number, 21, -57434055);
    a = ii(a, b, c, d, x[i+12] as number, 6, 1700485571);
    d = ii(d, a, b, c, x[i+3] as number, 10, -1894986606);
    c = ii(c, d, a, b, x[i+10] as number, 15, -1051523);
    b = ii(b, c, d, a, x[i+1] as number, 21, -2054922799);
    a = ii(a, b, c, d, x[i+8] as number, 6, 1873313359);
    d = ii(d, a, b, c, x[i+15] as number, 10, -30611744);
    c = ii(c, d, a, b, x[i+6] as number, 15, -1560198380);
    b = ii(b, c, d, a, x[i+13] as number, 21, 1309151649);
    a = ii(a, b, c, d, x[i+4] as number, 6, -145523070);
    d = ii(d, a, b, c, x[i+11] as number, 10, -1120210379);
    c = ii(c, d, a, b, x[i+2] as number, 15, 718787259);
    b = ii(b, c, d, a, x[i+9] as number, 21, -343485551);
    a = add32(a, olda);
    b = add32(b, oldb);
    c = add32(c, oldc);
    d = add32(d, oldd);
  }

  return [a, b, c, d].map(v => {
    const hex = ((v >>> 0) & 0xffffffff).toString(16);
    return '00000000'.slice(hex.length) + hex;
  }).join('');
}

// Block-independent AES encrypt. Not strictly ECB — it uses AES-CBC with
// a zero IV applied per block, which is functionally equivalent to ECB
// (each plaintext block maps to one ciphertext block, no chaining). The
// name `aes128BlockEncrypt` is honest about this. Web Crypto doesn't
// expose ECB directly, so we simulate it block-by-block. Used by wy.ts
// for the eapi/linuxapi transport obfuscation; this is NOT a security
// primitive, just protocol-level shape matching.
export async function aes128BlockEncrypt(key: ArrayBuffer, data: ArrayBuffer): Promise<ArrayBuffer> {
  const blockSize = 16;
  const dataArr = new Uint8Array(data);
  const padded = pkcs7Pad(dataArr, blockSize);
  const result = new Uint8Array(padded.length);
  const cryptoKey = await crypto.subtle.importKey('raw', key, { name: 'AES-CBC' }, false, ['encrypt']);
  const iv = new Uint8Array(blockSize);

  for (let i = 0; i < padded.length; i += blockSize) {
    const block = padded.slice(i, i + blockSize);
    const encrypted = await crypto.subtle.encrypt({ name: 'AES-CBC', iv }, cryptoKey, block);
    result.set(new Uint8Array(encrypted).slice(0, blockSize), i);
  }

  return result.buffer;
}

export function bufferToBase64(buf: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < buf.length; i++) {
    binary += String.fromCharCode(buf[i]);
  }
  return btoa(binary);
}

// PKCS7 padding
export function pkcs7Pad(data: Uint8Array, blockSize: number = 16): Uint8Array {
  const padLen = blockSize - (data.length % blockSize);
  const result = new Uint8Array(data.length + padLen);
  result.set(data);
  result.fill(padLen, data.length);
  return result;
}

// gb18030 decoding for kw lyrics (minimal implementation for common Chinese chars)
export function decodeGb18030(data: Uint8Array): string {
  const decoder = new TextDecoder('gb18030');
  try {
    return decoder.decode(data);
  } catch {
    // Fallback: try gbk, then manual decode
    try {
      return new TextDecoder('gbk').decode(data);
    } catch {
      // Manual fallback: treat as UTF-8 first, then try other encodings
      return new TextDecoder('utf-8').decode(data);
    }
  }
}

// inflate (standard zlib)
export async function inflate(data: Uint8Array): Promise<Uint8Array> {
  const ds = new DecompressionStream('deflate');
  const writer = ds.writable.getWriter();
  writer.write(data as BufferSource);
  writer.close();
  const result = await new Response(ds.readable).arrayBuffer();
  return new Uint8Array(result);
}
