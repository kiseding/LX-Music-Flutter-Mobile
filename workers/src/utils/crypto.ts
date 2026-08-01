/**
 * Workers-compatible crypto utilities
 * Replaces Node.js crypto/zlib with Web Crypto API
 */

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

// PKCS7 padding
export function pkcs7Pad(data: Uint8Array, blockSize: number = 16): Uint8Array {
  const padLen = blockSize - (data.length % blockSize);
  const result = new Uint8Array(data.length + padLen);
  result.set(data);
  result.fill(padLen, data.length);
  return result;
}
