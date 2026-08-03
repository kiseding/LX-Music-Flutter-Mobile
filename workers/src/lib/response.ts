/**
 * Shared types and utilities
 */

// AbortSignal.timeout polyfill for environments that ship AbortSignal
// but not the .timeout() static (Node < 17.3, older V8). Cloudflare
// Workers' V8 supports it natively, but local wrangler dev / unit tests
// against older Node may not. Idempotent: skipped when present.
if(typeof AbortSignal!=='undefined' && typeof AbortSignal.timeout!=='function'){
  // eslint-disable-next-line no-extend-native
  AbortSignal.timeout = function timeout(ms: number): AbortSignal {
    const ac = new AbortController();
    setTimeout(() => ac.abort(), ms);
    return ac.signal;
  };
}

/** Bindings for the slim cloud API used by the iOS app Sync screen. */
export interface Env {
  DB: D1Database;
  CACHE: KVNamespace;
  RATE_LIMITER: DurableObjectNamespace;
  /** Bootstrap admin (wrangler secret / GitHub Actions). */
  ADMIN_USERNAME?: string;
  ADMIN_PASSWORD?: string;
  /** Optional legacy gate; unset = disabled. */
  PLAYER_PASSWORD?: string;
  /** Optional Netease import via TinyAPI when set. */
  TINYAPI_KEY?: string;
}

export function jsonResponse(data: unknown, status = 200, extraHeaders?: HeadersInit): Response {
  // charset=utf-8 is required so non-ASCII characters in error messages
  // (Chinese / emoji / accented Latin) survive the browser's strict-mode
  // JSON parsing without the SyntaxError fallback that fires when
  // Content-Type lacks a charset and the browser guesses Latin-1 / GBK
  // for non-ASCII bytes.
  const headers = new Headers(extraHeaders);
  headers.set('Content-Type', 'application/json; charset=utf-8');
  return new Response(JSON.stringify(data), { status, headers });
}

export interface ErrorContext {
  requestId: string;
  method: string;
  path: string;
}

export function internalServerError(error: unknown, context: ErrorContext): Response {
  console.error({
    event: 'unhandled_request_error',
    ...context,
    error: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  });
  return jsonResponse(
    { error: '服务器错误', requestId: context.requestId },
    500,
    { 'X-Request-ID': context.requestId },
  );
}

export function requireJsonContentType(request: Request): Response | null {
  const ct = request.headers.get('Content-Type') || '';
  if (!/^application\/json\b/i.test(ct.trim())) {
    return jsonResponse({ error: 'Content-Type must be application/json' }, 400);
  }
  return null;
}

/** Parse a JSON request body into a non-null object, returning a 400 on invalid input. */
const MAX_JSON_BODY_BYTES = 256 * 1024;

export async function readJsonBody(request: Request): Promise<{ body: Record<string, unknown> } | Response> {
  const contentLength = Number(request.headers.get('Content-Length'));
  if (Number.isFinite(contentLength) && contentLength > MAX_JSON_BODY_BYTES) {
    return jsonResponse({ error: '请求体过大' }, 413);
  }

  let parsed: unknown;
  try {
    const bytes = await request.arrayBuffer();
    if (bytes.byteLength > MAX_JSON_BODY_BYTES) {
      return jsonResponse({ error: '请求体过大' }, 413);
    }
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return jsonResponse({ error: '无效请求' }, 400);
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return jsonResponse({ error: '无效请求' }, 400);
  }
  return { body: parsed as Record<string, unknown> };
}
