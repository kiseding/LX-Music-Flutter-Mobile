import { Env, jsonResponse } from '../lib/response';
import { verifyToken } from './jwt';

interface VerifiedUser {
  userId: number;
  payload: Record<string, unknown>;
}

// Internal: parse + verify signature + (optionally) check token_version against DB.
// Combines JWT verify with version check in one path to avoid double-reading the
// JWT secret and double-querying the user.
async function verifyAndAuthorize(request: Request, env: Env, needPayload: false): Promise<number | null>;
async function verifyAndAuthorize(request: Request, env: Env, needPayload: true): Promise<VerifiedUser | null>;
async function verifyAndAuthorize(request: Request, env: Env, needPayload: boolean): Promise<number | null | VerifiedUser> {
  const auth = request.headers.get('Authorization')?.replace('Bearer ', '');
  if (!auth) return null;
  const payload = await verifyToken(auth, env);
  if (!payload?.sub) return null;
  const userId = payload.sub as number;

  // P1-9: cross-check token_version so password change / role demotion
  // instantly invalidates the 7-day token.
  const row = await env.DB.prepare('SELECT token_version, role FROM users WHERE id = ?')
    .bind(userId)
    .first<{ token_version: number; role: string }>();
  if (!row) return null;
  const tv = typeof payload.tv === 'number' ? payload.tv : 0;
  if (tv !== row.token_version) return null;

  // Sync the role from the DB so that a demoted user loses admin on the next
  // request, even if their token still claims admin. The JWT is authoritative
  // for everything else; role is a security-sensitive claim we double-check.
  if (payload.role !== row.role) payload.role = row.role;

  return needPayload ? { userId, payload } : userId;
}

export async function getUserId(request: Request, env: Env): Promise<number | null> {
  return verifyAndAuthorize(request, env, false);
}

export async function requireAuth(request: Request, env: Env): Promise<{ userId: number; payload: Record<string, unknown> } | Response> {
  const result = await verifyAndAuthorize(request, env, true);
  if (!result) return jsonResponse({ error: '未登录' }, 401);
  return result;
}

export function bearerToken(request: Request): string | null {
  const header = request.headers.get('Authorization');
  const match = header?.match(/^Bearer\s+(.+)$/i);
  return match?.[1] || null;
}

export function isMusicCapabilityPath(pathname: string): boolean {
  if (pathname === '/api/proxy' || pathname === '/api/ping') return true;
  if (!pathname.startsWith('/api/music/')) return false;
  return pathname !== '/api/music/config'
    && pathname !== '/api/music/auth'
    && pathname !== '/api/music/auth/verify';
}

export async function requireMusicAccess(request: Request, env: Env): Promise<Response | null> {
  if (!env.PLAYER_PASSWORD) return null;
  const token = bearerToken(request);
  if (!token) return jsonResponse({ error: '需要播放器认证' }, 401);
  const payload = await verifyToken(token, env);
  if (payload?.type === 'player') return null;
  if (payload?.sub) {
    const user = await requireAuth(request, env);
    if (!(user instanceof Response)) return null;
  }
  return jsonResponse({ error: '播放器认证无效' }, 401);
}

export async function requireAdmin(request: Request, env: Env): Promise<{ userId: number; payload: Record<string, unknown> } | Response> {
  const auth = await requireAuth(request, env);
  if (auth instanceof Response) return auth;
  if (!isAdmin(auth.payload)) return jsonResponse({ error: '需要管理员权限' }, 403);
  return auth;
}

export function isAdmin(payload: Record<string, unknown>): boolean {
  return payload.role === 'admin';
}
