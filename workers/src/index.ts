/**
 * lx-music-api — Cloudflare Worker for LX Music iOS
 *
 * Scope (matches App Sync / CloudApiClient):
 *   - Auth: login, register, verify, change password
 *   - Admin: user CRUD
 *   - Cloud playlists + love list
 *   - Playlist import (QQ / Kuwo / Netease link or id)
 *
 * Not in scope: search, play URL resolve, lyrics (App + optional custom sources).
 */
import { Env, jsonResponse, internalServerError } from './lib/response';
import { BUILD_SHA, BUILD_DATE } from './generated/version';
import {
  handleUserLogin,
  handleUserRegister,
  handleUserVerify,
  handleChangePassword,
  seedAdminUser,
  handleAdminUsers,
} from './routes/user/auth';
import {
  handleUserPlaylist,
  handleUserPlaylistSave,
  handlePlaylistDelete,
  handleLoveAdd,
  handleLoveRemove,
  handlePlaylistRefresh,
} from './routes/user/playlist';
import { handlePlaylistImport } from './routes/playlist-import';
import { requireAdmin } from './utils/auth';
import { checkSchemaReady } from './db/schema';
export { RateLimiterDO } from './middleware/rateLimitDO';

const VERSION = `${BUILD_SHA} (${BUILD_DATE})`;

function corsResponse(resp: Response, request: Request): Response {
  const headers = new Headers(resp.headers);
  const origin = request.headers.get('Origin');
  headers.set('Access-Control-Allow-Origin', origin || '*');
  if (origin) headers.set('Vary', 'Origin');
  headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  headers.set('Access-Control-Max-Age', '86400');
  headers.set('X-Content-Type-Options', 'nosniff');
  return new Response(resp.body, { status: resp.status, headers });
}

function withRequestId(response: Response, requestId: string): Response {
  if (response.headers.get('X-Request-ID')) return response;
  const headers = new Headers(response.headers);
  headers.set('X-Request-ID', requestId);
  return new Response(response.body, { status: response.status, headers });
}

type RouteHandler = (request: Request, url: URL, env: Env, ctx: ExecutionContext) => Promise<Response>;

const routes = new Map<string, RouteHandler>([
  ['POST/api/user/login', (req, _url, env) => handleUserLogin(req, env)],
  ['POST/api/user/register', (req, _url, env) => handleUserRegister(req, env)],
  ['GET/api/user/auth/verify', (req, _url, env) => handleUserVerify(req, env)],
  ['POST/api/user/auth/verify', (req, _url, env) => handleUserVerify(req, env)],
  ['POST/api/user/password', (req, _url, env) => handleChangePassword(req, env)],

  ['POST/api/music/playlist/import', (req, _url, env, ctx) => handlePlaylistImport(req, env, ctx)],
  ['DELETE/api/user/playlist', (req, url, env) => handlePlaylistDelete(req, url, env)],
  ['POST/api/user/playlist/refresh', (req, _url, env, ctx) => handlePlaylistRefresh(req, env, ctx)],
  ['GET/api/user/list', (req, url, env, ctx) => handleUserPlaylist(req, url, env, ctx)],
  ['POST/api/user/list', (req, _url, env, ctx) => handleUserPlaylistSave(req, env, ctx)],
  ['POST/api/user/love/add', (req, _url, env, ctx) => handleLoveAdd(req, env, ctx)],
  ['POST/api/user/love/remove', (req, _url, env, ctx) => handleLoveRemove(req, env, ctx)],

  ['GET/api/ping', async () => jsonResponse({ ok: true, service: 'lx-music-api' })],
  ['GET/api/version', async () => jsonResponse({ version: VERSION })],
  ['GET/api/health', async () => jsonResponse({ status: 'ok', version: VERSION })],
]);

const seedPaths = new Set([
  '/api/user/login',
  '/api/user/register',
  '/api/user/auth/verify',
]);

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const requestId = request.headers.get('X-Request-ID') || crypto.randomUUID();
    const url = new URL(request.url);
    // 去掉末尾 /，避免 /api/user/login/ 匹配失败
    let pathname = url.pathname;
    if (pathname.length > 1 && pathname.endsWith('/')) {
      pathname = pathname.slice(0, -1);
    }
    const method = request.method.toUpperCase();

    if (method === 'OPTIONS') {
      return corsResponse(withRequestId(new Response(null, { status: 204 }), requestId), request);
    }

    if (!pathname.startsWith('/api/')) {
      return corsResponse(withRequestId(jsonResponse({
        name: 'lx-music-api',
        version: VERSION,
        hint: 'Configure this URL in the app Sync settings',
        endpoints: ['/api/health', '/api/user/login', '/api/user/list'],
      }), requestId), request);
    }

    if (pathname.startsWith('/api/') && pathname !== '/api/ping' && pathname !== '/api/version') {
      const readiness = await checkSchemaReady(env);
      if (!readiness.ready) {
        console.error({
          event: 'schema_not_ready',
          requestId,
          method,
          path: pathname,
          reason: readiness.reason,
        });
        return corsResponse(
          withRequestId(jsonResponse({ error: '服务尚未完成数据库迁移', requestId }, 503), requestId),
          request,
        );
      }
    }

    let response: Response;
    try {
      if (seedPaths.has(pathname)) {
        const bootstrap = await seedAdminUser(env, ctx);
        if (pathname === '/api/user/register' && !bootstrap.ready) {
          response = jsonResponse({ error: '管理员尚未初始化，请先配置 ADMIN_USERNAME/PASSWORD' }, 503);
          return corsResponse(withRequestId(response, requestId), request);
        }
      }

      if (pathname.startsWith('/api/admin/users')) {
        response = await handleAdminUsers(request, env);
        return corsResponse(withRequestId(response, requestId), request);
      }

      const handler = routes.get(method + pathname);
      if (handler) {
        response = await handler(request, url, env, ctx);
      } else if (pathname === '/api/diag' && (method === 'GET' || method === 'POST')) {
        const admin = await requireAdmin(request, env);
        if (admin instanceof Response) response = admin;
        else response = jsonResponse({ version: VERSION, ok: true });
      } else {
        response = jsonResponse({
          error: 'Not Found',
          method,
          path: pathname,
          hint: 'Use POST /api/user/login with JSON body',
        }, 404);
      }
    } catch (error: unknown) {
      response = internalServerError(error, { requestId, method, path: pathname });
    }

    return corsResponse(withRequestId(response, requestId), request);
  },
};
