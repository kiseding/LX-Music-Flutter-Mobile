/**
 * User authentication routes
 */
import { Env, jsonResponse, requireJsonContentType } from '../../lib/response';
import { signToken, verifyToken, hashPassword, verifyPassword, checkPasswordLength } from '../../utils/jwt';
import { getUserId, isAdmin, requireAuth } from '../../utils/auth';
import { RateLimiter, getClientIP } from '../../middleware/rateLimit';
import { SCHEMA_SQL } from '../../db/schema';

// Defensive user-lookup: if the SELECT fails with "no such column:
// token_version" (v1 schema pre-migration), run the patch inline and
// retry once. This is the last line of defense if the seed's
// applySchemaPatches() didn't run or didn't take effect — better than
// returning 500 on every login.
async function selectUserByUsername(
  env: Env, username: string
): Promise<{ id: number; password_hash: string; role: string; token_version: number } | null> {
  const sql = 'SELECT id, password_hash, role, token_version FROM users WHERE username = ?';
  try {
    return await env.DB.prepare(sql).bind(username).first<{ id: number; password_hash: string; role: string; token_version: number }>();
  } catch (e: any) {
    if (String(e?.message || '').includes('no such column')) {
      console.log('[login] missing column detected, running patch inline');
      _patchesApplied = false;
      await applySchemaPatches(env);
      return await env.DB.prepare(sql).bind(username).first<{ id: number; password_hash: string; role: string; token_version: number }>();
    }
    throw e;
  }
}

export async function handleUserLogin(request: Request, env: Env): Promise<Response> {
  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
  const { username, password } = body;
  if (!username || !password) {
    return jsonResponse({ error: '用户名和密码不能为空' }, 400);
  }

  if (typeof username !== 'string' || username.length > 32) {
    return jsonResponse({ error: '输入过长' }, 400);
  }
  if (!/^[\w\-一-鿿]+$/.test(username)) {
    return jsonResponse({ error: '用户名只能包含字母、数字、下划线、中文字符' }, 400);
  }
  const limiter = new RateLimiter(env.RATE_LIMITER, 'rl:login');
  const rateKey = loginRateLimitKey(getClientIP(request), username);
  const rateCheck = await limiter.check(rateKey, 5, 60);
  if (!rateCheck.allowed) {
    return jsonResponse({ error: '请求过于频繁，请稍后再试', retryAfter: Math.ceil((rateCheck.resetAt - Date.now()) / 1000) }, 429);
  }
  // Login: don't enforce new-password length cap. Existing users may have
  // passwords set before the cap was added. verifyPassword itself does
  // no length cap (relies on the 256KB body limit for DoS protection).

  const user = await selectUserByUsername(env, username);
  if (!user) {
    return jsonResponse({ error: '用户名或密码错误' }, 401);
  }

  const { valid, needsUpgrade } = await verifyPassword(password, user.password_hash);
  if (!valid) {
    return jsonResponse({ error: '用户名或密码错误' }, 401);
  }

  // Auto-upgrade legacy SHA-256 hash to PBKDF2
  if (needsUpgrade) {
    const newHash = await hashPassword(password);
    await env.DB.prepare('UPDATE users SET password_hash = ? WHERE id = ?').bind(newHash, user.id).run();
  }

  const token = await signToken({ sub: user.id, username, role: user.role, tv: user.token_version }, '7d', env);

  // Reset rate limit on successful login
  await limiter.reset(rateKey);

  return jsonResponse({ token, username, role: user.role });
}

export async function handleUserRegister(request: Request, env: Env): Promise<Response> {
  // P1-1: limit runs in a Durable Object.
  const regLimiter = new RateLimiter(env.RATE_LIMITER, 'rl:register');
  const ip = getClientIP(request);
  const rateCheck = await regLimiter.check(ip, 10, 3600);
  if (!rateCheck.allowed) {
    return jsonResponse({ error: '注册过于频繁，请稍后再试' }, 429);
  }

  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
  const { username, password } = body;
  if (!username || !password) {
    return jsonResponse({ error: '用户名和密码不能为空' }, 400);
  }

  if (typeof username !== 'string' || username.length > 32) {
    return jsonResponse({ error: '输入过长' }, 400);
  }
  if (username.length < 2) return jsonResponse({ error: '用户名至少2字符' }, 400);
  const pwCheck = checkPasswordLength(password);
  if (!pwCheck.ok) return jsonResponse({ error: pwCheck.reason }, 400);
  if (!/^[\w\-一-鿿]+$/.test(username)) {
    return jsonResponse({ error: '用户名只能包含字母、数字、下划线、中文字符' }, 400);
  }

  const existing = await env.DB.prepare('SELECT id FROM users WHERE username = ?').bind(username).first();
  if (existing) {
    return jsonResponse({ error: '用户名已存在' }, 409);
  }

  const passwordHash = await hashPassword(password);
  const result = await env.DB.prepare('INSERT INTO users (username, password_hash, role) VALUES (?, ?, ?)')
    .bind(username, passwordHash, 'user').run();

  const userId = result.meta.last_row_id as number;
  const token = await signToken({ sub: userId, username, role: 'user', tv: 0 }, '7d', env);
  return jsonResponse({ token, username });
}

export async function handleUserVerify(request: Request, env: Env): Promise<Response> {
  // P1-9: full verify with token_version check so the response reflects the
  // current DB state (demoted admin sees role='user' on next request).
  const auth = request.headers.get('Authorization')?.replace('Bearer ', '');
  if (!auth) return jsonResponse({ valid: false }, 401);
  const payload = await verifyToken(auth, env);
  if (!payload?.sub) return jsonResponse({ valid: false }, 401);
  const row = await env.DB.prepare('SELECT token_version, role FROM users WHERE id = ?')
    .bind(payload.sub as number)
    .first<{ token_version: number; role: string }>();
  if (!row) return jsonResponse({ valid: false }, 401);
  const tv = typeof payload.tv === 'number' ? payload.tv : 0;
  if (tv !== row.token_version) return jsonResponse({ valid: false }, 401);
  return jsonResponse({ valid: true, username: payload.username, role: row.role });
}

// Change password
export async function handleChangePassword(request: Request, env: Env): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId) return jsonResponse({ error: '未登录' }, 401);

  const ctErr = requireJsonContentType(request);
  if (ctErr) return ctErr;

  let body: any;
  try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
  const { oldPassword, newPassword } = body;
  if (!oldPassword || !newPassword) return jsonResponse({ error: '请填写新旧密码' }, 400);
  const pwCheck = checkPasswordLength(newPassword);
  if (!pwCheck.ok) return jsonResponse({ error: pwCheck.reason }, 400);

  const user = await env.DB.prepare('SELECT password_hash, username, role, token_version FROM users WHERE id = ?')
    .bind(userId).first<{ password_hash: string; username: string; role: string; token_version: number }>();
  if (!user) return jsonResponse({ error: '用户不存在' }, 404);
  const { valid } = await verifyPassword(oldPassword, user.password_hash);
  if (!valid) return jsonResponse({ error: '原密码错误' }, 403);

  const newHash = await hashPassword(newPassword);
  // P1-9: bump token_version so all of this user's existing tokens are
  // invalidated immediately. The user will need to log in again on other
  // devices.
  await env.DB.prepare('UPDATE users SET password_hash = ?, token_version = token_version + 1, updated_at = datetime(\'now\') WHERE id = ?')
    .bind(newHash, userId).run();
  const token = await signToken({
    sub: userId,
    username: user.username,
    role: user.role,
    tv: user.token_version + 1,
  }, '7d', env);
  return jsonResponse({ ok: true, token });
}

// Seed default admin user on first run
let _seeded = false;
const SEED_LOCK_KEY = 'v2:system:seed_lock';
// CRITICAL: Cloudflare KV requires expirationTtl >= 60. Setting it lower
// throws "Invalid expiration_ttl" which propagates up and breaks the
// entire seed flow (and therefore every login attempt).
const SEED_LOCK_TTL = 90;

// Note: this lock is best-effort, NOT atomic across isolates. KV is
// eventually consistent, so two isolates can both pass the get(), both
// call put(), and both think they hold the lock. That's OK — the real
// race protection is INSERT OR IGNORE in the admin user insert below
// (UNIQUE(username) drops the duplicate). The lock just avoids duplicate
// schema-exec work.
async function tryAcquireSeedLock(env: Env): Promise<boolean> {
  const cur = await env.CACHE.get(SEED_LOCK_KEY);
  if (cur) return false;
  await env.CACHE.put(SEED_LOCK_KEY, '1', { expirationTtl: SEED_LOCK_TTL });
  return true;
}
async function releaseSeedLock(env: Env): Promise<void> {
  try { await env.CACHE.delete(SEED_LOCK_KEY); } catch {}
}

// Self-healing v1→v2 schema patches.
//
// Runs OUTSIDE the seed lock so every isolate applies the patches
// before its first login/verify query — not just the one that happened
// to win the seed lock. The patch logic itself is idempotent at the
// SQL level (PRAGMA check + conditional ALTER), and D1 serializes
// schema changes so two simultaneous ALTERs against the same column
// resolve as one success + one "duplicate column" error which we swallow.
//
// Per-isolate memoization avoids the PRAGMA roundtrip on every request
// after the first. The memo is intentionally NOT cross-isolate — every
// new isolate re-checks, so a slow first request from one isolate
// can't poison another.
let _patchesApplied = false;
let _lastPatchError: string | null = null;
export async function applySchemaPatches(env: Env): Promise<void> {
  if (_patchesApplied) return;
  try {
    const cols = await env.DB.prepare("PRAGMA table_info('users')").all<{ name: string }>();
    const hasTV = (cols.results || []).some(c => c.name === 'token_version');
    if (!hasTV) {
      console.log('[seed] P1-9: adding users.token_version');
      try {
        await env.DB.exec("ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0");
        console.log('[seed] P1-9: column added');
      } catch (e: any) {
        const msg = String(e?.message || '').toLowerCase();
        if (msg.includes('duplicate') || msg.includes('already exists')) {
          console.log('[seed] P1-9: column already exists (race, ignored)');
        } else {
          console.error('[seed] P1-9: ALTER failed:', e?.message);
          throw e;
        }
      }
    } else {
      console.log('[seed] P1-9: column already exists');
    }

    // P0-1 fix: dedup existing playlist_songs rows and create the UNIQUE
    // INDEX that prevents future duplicates. Two concurrent writes (full
    // love-list save + incremental add) used to insert the same song twice
    // because there was no UNIQUE constraint on (playlist_id, user_id,
    // songmid, source). We keep the lowest rowid for each duplicate set so
    // the auto-incremented id stays stable for any external references.
    // Step 1: empty-songmid rows from v1 block a non-partial unique index.
    // Make them unique by tagging rowid.
    await env.DB.exec(
      `UPDATE playlist_songs SET songmid = '_empty_' || rowid WHERE songmid = ''`
    );
    // Step 2: dedup across FULL key.
    const dupes = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM (
         SELECT playlist_id, user_id, songmid, source, COUNT(*) AS c
         FROM playlist_songs
         GROUP BY playlist_id, user_id, songmid, source
         HAVING c > 1
       )`
    ).first<{ n: number }>();
    const dupeCount = Number(dupes?.n ?? 0);
    if (dupeCount > 0) {
      console.log(`[seed] P0-1: deduping ${dupeCount} duplicate playlist_songs sets`);
      const del = await env.DB.prepare(
        `DELETE FROM playlist_songs
         WHERE rowid NOT IN (
           SELECT MIN(rowid) FROM playlist_songs
           GROUP BY playlist_id, user_id, songmid, source
         )`
      ).run();
      console.log(`[seed] P0-1: removed ${del.meta?.changes ?? 0} duplicate rows`);
    }
    // Drop any existing incarnation of this index (the original partial
    // form blocked handleLoveAdd / saveLoveList INSERT...ON CONFLICT
    // because SQLite refuses to target a partial index from a non-WHERE
    // INSERT). CREATE INDEX IF NOT EXISTS won't notice the schema
    // mismatch — same name, different definition — so we drop first.
    let reindexErr: string | null = null;
    try {
      await env.DB.exec(`DROP INDEX IF EXISTS uniq_ps_love_song`);
      await env.DB.exec(`CREATE UNIQUE INDEX uniq_ps_love_song ON playlist_songs(playlist_id, user_id, songmid, source)`);
    } catch (e: any) {
      reindexErr = String(e?.message || e);
      console.error('[seed] P0-1: UNIQUE INDEX creation failed:', reindexErr);
      // don't re-throw — we want applySchemaPatches to mark itself applied so the next request
      // doesn't keep retrying. The diagnostic endpoint can read _lastPatchError.
      _lastPatchError = reindexErr;
    }

    _patchesApplied = true;
  } catch (e) {
    console.error('[seed] P1-9 patch failed:', e);
  }
}

// Public entry point so diagnostic / repair endpoints can force-run the
// patches without going through the full seed flow.


export function getLastPatchError(): string | null {
  return _lastPatchError;
}

export async function ensureSchemaPatches(env: Env): Promise<void> {
  _patchesApplied = false;
  await applySchemaPatches(env);
}

export interface BootstrapState { ready: boolean; reason?: string }

export async function seedAdminUser(env: Env, ctx?: ExecutionContext): Promise<BootstrapState> {
  if (_seeded) return { ready: true };

  try { await env.DB.exec(SCHEMA_SQL); } catch (e) { console.error('schema init error:', e); }
  await applySchemaPatches(env);

  const existingAdmin = await env.DB.prepare("SELECT id FROM users WHERE role = 'admin' LIMIT 1").first();
  if (existingAdmin) {
    _seeded = true;
    if (ctx) ctx.waitUntil(env.CACHE.put('v2:system:seeded', '1'));
    else await env.CACHE.put('v2:system:seeded', '1');
    return { ready: true };
  }

  const username = env.ADMIN_USERNAME;
  const password = env.ADMIN_PASSWORD;
  if (!username || !password) {
    console.error('[lx-music-api] ADMIN_USERNAME and ADMIN_PASSWORD must be set before registration.');
    return { ready: false, reason: 'admin credentials are not configured' };
  }
  if (password.length > 128) {
    console.error('[lx-music-api] ADMIN_PASSWORD too long (>128 chars).');
    return { ready: false, reason: 'admin password is invalid' };
  }

  const gotLock = await tryAcquireSeedLock(env);
  if (!gotLock) {
    const racedAdmin = await env.DB.prepare("SELECT id FROM users WHERE role = 'admin' LIMIT 1").first();
    return racedAdmin ? { ready: true } : { ready: false, reason: 'admin initialization in progress' };
  }

  try {
    const hash = await hashPassword(password);
    const result = await env.DB.prepare(
      'INSERT OR IGNORE INTO users (username, password_hash, role) VALUES (?, ?, ?)'
    ).bind(username, hash, 'admin').run();
    if ((result.meta?.changes ?? 0) > 0) {
      console.log(`[lx-music-api] Admin user created: ${username}`);
    }

    const admin = await env.DB.prepare("SELECT id FROM users WHERE role = 'admin' LIMIT 1").first();
    if (!admin) return { ready: false, reason: 'admin creation failed' };
    _seeded = true;
    if (ctx) ctx.waitUntil(env.CACHE.put('v2:system:seeded', '1'));
    else await env.CACHE.put('v2:system:seeded', '1');
    return { ready: true };
  } catch (e) {
    console.error('[seed] error:', e);
    return { ready: false, reason: 'admin initialization failed' };
  } finally {
    await releaseSeedLock(env);
  }
}

// Admin: list/manage users
export async function handleAdminUsers(request: Request, env: Env): Promise<Response> {
  // P1-9 + P0-3: requireAuth verifies the JWT signature, checks
  // token_version against the DB, and syncs role from the DB so a demoted
  // admin loses access on the next request.
  const authResult = await requireAuth(request, env);
  if (authResult instanceof Response) return authResult;
  const { userId, payload } = authResult;
  if (!isAdmin(payload)) return jsonResponse({ error: '仅管理员' }, 403);

  if (request.method === 'GET') {
    const rows = await env.DB.prepare('SELECT id, username, created_at, role FROM users ORDER BY id').all();
    return jsonResponse({ users: rows.results });
  }

  if (request.method === 'POST') {
    const ctErr = requireJsonContentType(request);
    if (ctErr) return ctErr;
    let body: any;
    try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
    const { username, password } = body;
    if (!username || !password) return jsonResponse({ error: '缺少参数' }, 400);
    if (username.length < 2 || username.length > 32) return jsonResponse({ error: '用户名长度需2-32字符' }, 400);
    const pwCheck = checkPasswordLength(password);
    if (!pwCheck.ok) return jsonResponse({ error: pwCheck.reason }, 400);
    if (!/^[\w\-一-鿿]+$/.test(username)) return jsonResponse({ error: '用户名只能包含字母、数字、下划线、中文字符' }, 400);
    const existing = await env.DB.prepare('SELECT id FROM users WHERE username = ?').bind(username).first();
    if (existing) return jsonResponse({ error: '用户已存在' }, 409);
    const hash = await hashPassword(password);
    await env.DB.prepare('INSERT INTO users (username, password_hash, role) VALUES (?, ?, ?)').bind(username, hash, 'user').run();
    return jsonResponse({ ok: true });
  }

  if (request.method === 'DELETE') {
    const ctErr = requireJsonContentType(request);
    if (ctErr) return ctErr;
    let body: any;
    try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
    const id = Number(body?.id);
    if (!Number.isFinite(id) || id <= 0) return jsonResponse({ error: '缺少ID' }, 400);
    // P2-18: don't let an admin delete themselves — leaves the system with no
    // admins (or worse, locked-out-of-everything).
    if (id === userId) return jsonResponse({ error: '不能删除自己' }, 403);
    const user = await env.DB.prepare('SELECT username FROM users WHERE id = ?').bind(id).first<{ username: string }>();
    if (user?.username === 'admin') return jsonResponse({ error: '不能删除admin' }, 403);
    // DELETE cascades via FK to playlists / playlist_songs / playback_progress,
    // and the next verify on a still-cached JWT will fail the user lookup,
    // so the target's active sessions are invalidated as a side effect.
    await env.DB.prepare('DELETE FROM users WHERE id = ?').bind(id).run();
    return jsonResponse({ ok: true });
  }

  if (request.method === 'PUT') {
    const ctErr = requireJsonContentType(request);
    if (ctErr) return ctErr;
    let body: any;
    try { body = await request.json(); } catch { return jsonResponse({ error: '无效请求' }, 400); }
    const { id, password } = body;
    if (!id || !password) return jsonResponse({ error: '缺少参数' }, 400);
    const pwCheck = checkPasswordLength(password);
    if (!pwCheck.ok) return jsonResponse({ error: pwCheck.reason }, 400);
    const hash = await hashPassword(password);
    // Bump token_version so the user is logged out everywhere.
    await env.DB.prepare("UPDATE users SET password_hash = ?, token_version = token_version + 1, updated_at = datetime('now') WHERE id = ?")
      .bind(hash, id).run();
    return jsonResponse({ ok: true });
  }

  return jsonResponse({ error: 'Method not allowed' }, 405);
}

export function loginRateLimitKey(ip: string, username: string): string {
  return `${ip}:${username.trim().toLowerCase()}`;
}
