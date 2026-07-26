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

export function jsonResponse(data: any, status = 200): Response {
  // charset=utf-8 is required so non-ASCII characters in error messages
  // (Chinese / emoji / accented Latin) survive the browser's strict-mode
  // JSON parsing without the SyntaxError fallback that fires when
  // Content-Type lacks a charset and the browser guesses Latin-1 / GBK
  // for non-ASCII bytes.
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

export function requireJsonContentType(request: Request): Response | null {
  const ct = request.headers.get('Content-Type') || '';
  if (!/^application\/json\b/i.test(ct.trim())) {
    return jsonResponse({ error: 'Content-Type must be application/json' }, 400);
  }
  return null;
}
