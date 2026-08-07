/**
 * JWT helpers — pure Web Crypto API, zero dependencies
 */

import type { Env } from '../lib/response';

export async function getJwtSecret(env: Env, initialize = true): Promise<string> {
  const kvKey = 'v2:system:jwt_secret';
  if (!initialize) {
    const existing = await env.DB.prepare(
      'SELECT value FROM system_settings WHERE key = ?'
    ).bind('jwt_secret').first<{ value: string }>();
    if (!existing?.value) throw new Error('JWT secret is not initialized');
    return existing.value;
  }

  const current = await env.DB.prepare(
    'SELECT value FROM system_settings WHERE key = ?'
  ).bind('jwt_secret').first<{ value: string }>();
  if (current?.value) return current.value;

  const legacy = await env.CACHE.get(kvKey);
  let candidate = typeof legacy === 'string' && legacy.length >= 32 ? legacy : '';
  if (!candidate) {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    candidate = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  await env.DB.prepare(
    'INSERT OR IGNORE INTO system_settings (key, value) VALUES (?, ?)'
  ).bind('jwt_secret', candidate).run();
  const authoritative = await env.DB.prepare(
    'SELECT value FROM system_settings WHERE key = ?'
  ).bind('jwt_secret').first<{ value: string }>();
  if (!authoritative?.value) throw new Error('JWT secret initialization failed');
  return authoritative.value;
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function parseBase64url(s: string): Uint8Array {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}

function parseDuration(s: string): number {
  const m = s.match(/^(\d+)([smhd])$/);
  if (!m) return 3600;
  const v = parseInt(m[1]);
  switch (m[2]) {
    case 's': return v;
    case 'm': return v * 60;
    case 'h': return v * 3600;
    case 'd': return v * 86400;
    default: return 3600;
  }
}

function getSecret(envSecret?: string): Uint8Array {
  return new TextEncoder().encode(envSecret || '');
}

async function hmacSign(data: Uint8Array, secret: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', secret as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, data as BufferSource));
}

async function hmacVerify(data: Uint8Array, sig: Uint8Array, secret: Uint8Array): Promise<boolean> {
  const key = await crypto.subtle.importKey('raw', secret as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  return crypto.subtle.verify('HMAC', key, sig as BufferSource, data as BufferSource);
}

export async function signToken(payload: Record<string, unknown>, expiresIn: string = '7d', secretOrEnv?: string | Env): Promise<string> {
  const secret = typeof secretOrEnv === 'object' ? getSecret(await getJwtSecret(secretOrEnv)) : getSecret(secretOrEnv);
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const claims = { ...payload, iss: 'lx-music-api', iat: now, exp: now + parseDuration(expiresIn) };

  const enc = (o: object) => base64url(new TextEncoder().encode(JSON.stringify(o)));
  const data = enc(header) + '.' + enc(claims);
  const sig = await hmacSign(new TextEncoder().encode(data), secret);

  return data + '.' + base64url(sig);
}

export async function verifyToken(token: string, secretOrEnv?: string | Env): Promise<Record<string, unknown> | null> {
  try {
    const secret = typeof secretOrEnv === 'object' ? getSecret(await getJwtSecret(secretOrEnv, false)) : getSecret(secretOrEnv);
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    const data = parts[0] + '.' + parts[1];
    const sig = parseBase64url(parts[2]);

    const valid = await hmacVerify(new TextEncoder().encode(data), sig, secret);
    if (!valid) return null;

    const payload = JSON.parse(new TextDecoder().decode(parseBase64url(parts[1])));
    if (payload.iss !== 'lx-music-api') return null;
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) return null;

    return payload as Record<string, unknown>;
  } catch {
    return null;
  }
}

// PBKDF2-SHA256 password hashing with random salt
const PBKDF2_ITERATIONS = 100000;
const SALT_LENGTH = 16;
const HASH_LENGTH = 32;

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

// P1-8: hard cap on password length. 128 chars is well above any sane human
// password and well below the 256KB body cap. Larger inputs would force the
// server to run PBKDF2 over hundreds of KB of attacker-controlled data on
// every login attempt, which is a cheap DoS.
export const PASSWORD_MAX = 128;
export const PASSWORD_MIN = 6;
export function checkPasswordLength(password: string): { ok: true } | { ok: false; reason: string } {
  if (typeof password !== 'string') return { ok: false, reason: '密码格式错误' };
  if (password.length < PASSWORD_MIN) return { ok: false, reason: `密码至少${PASSWORD_MIN}位` };
  if (password.length > PASSWORD_MAX) return { ok: false, reason: `密码不能超过${PASSWORD_MAX}位` };
  return { ok: true };
}

// Hash password using PBKDF2-SHA256 + random salt
// Storage format: "pbkdf2:<hex-salt>:<hex-hash>"
export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_LENGTH));
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    key,
    HASH_LENGTH * 8,
  );
  return `pbkdf2:${toHex(salt.buffer)}:${toHex(bits)}`;
}

// Verify password against stored hash
// Supports both new PBKDF2 format and legacy SHA-256 format
// Returns { valid, needsUpgrade } — if needsUpgrade, caller should re-hash with PBKDF2
// Constant-time string comparison to prevent timing attacks — does NOT short-circuit on length
export function timingSafeEqual(a: string, b: string): boolean {
  let result = a.length ^ b.length;
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    result |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return result === 0;
}

export async function verifyPassword(password: string, storedHash: string): Promise<{ valid: boolean; needsUpgrade: boolean }> {
  // No length cap here. Backward compat: users may have had passwords up to
  // 256KB (the request body limit) before the P1-8 cap was added. The body
  // size cap is the real DoS protection; capping again here would lock
  // those users out. New passwords are restricted via checkPasswordLength
  // in register/change-password paths.
  if (typeof password !== 'string') return { valid: false, needsUpgrade: false };
  // Legacy SHA-256 format (64 hex chars, no prefix)
  if (!storedHash.startsWith('pbkdf2:')) {
    const data = new TextEncoder().encode(password);
    const hash = await crypto.subtle.digest('SHA-256', data);
    const hex = toHex(hash);
    return { valid: timingSafeEqual(hex, storedHash), needsUpgrade: timingSafeEqual(hex, storedHash) };
  }

  // PBKDF2 format: "pbkdf2:<salt>:<hash>"
  const parts = storedHash.split(':');
  if (parts.length !== 3) return { valid: false, needsUpgrade: false };

  const salt = new Uint8Array(parts[1].match(/.{2}/g)!.map(b => parseInt(b, 16)));
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    key,
    HASH_LENGTH * 8,
  );
  return { valid: timingSafeEqual(toHex(bits), parts[2]), needsUpgrade: false };
}
