/**
 * P1-1: Rate limiter implemented as a Durable Object.
 *
 * Replaces the previous read-then-recheck KV-based limiter that suffered
 * from a TOCTOU race allowing up to (concurrency-1) requests past the limit
 * and could recurse into a stack overflow under sustained load.
 *
 * The DO is per-prefix+key, so each (ip, route) pair gets its own isolated
 * state. All reads/writes are linearized by the DO's single-threaded
 * execution model — true atomicity.
 */
export class RateLimiterDO implements DurableObject {
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const key = url.pathname.replace(/^\/+/, '') || 'default';
    const max = parseInt(url.searchParams.get('max') || '0', 10);
    const windowSec = parseInt(url.searchParams.get('window') || '60', 10);

    if (request.method === 'DELETE') {
      await this.state.storage.delete(key);
      return new Response(JSON.stringify({ ok: true }), { headers: { 'Content-Type': 'application/json' } });
    }

    // max=0 means "just read current state, don't increment" — useful for
    // observability. Negative max is treated as 0.
    const now = Date.now();
    const windowMs = windowSec * 1000;
    const stored = await this.state.storage.get<Entry>(key);
    let entry: Entry = stored && stored.resetAt > now
      ? stored
      : { count: 0, resetAt: now + windowMs };

    if (max > 0 && entry.count >= max) {
      return new Response(JSON.stringify({
        allowed: false,
        remaining: 0,
        resetAt: entry.resetAt,
      }), { headers: { 'Content-Type': 'application/json' } });
    }

    if (max > 0) {
      entry.count += 1;
      // Persist (no expirationTtl option on DurableObject storage in the
      // current @cloudflare/workers-types — entries are GC'd on inactivity
      // by the DO runtime, and the read path treats expired resetAt as a
      // fresh window anyway).
      await this.state.storage.put(key, entry);
    }

    return new Response(JSON.stringify({
      allowed: true,
      remaining: max > 0 ? Math.max(0, max - entry.count) : 0,
      resetAt: entry.resetAt,
    }), { headers: { 'Content-Type': 'application/json' } });
  }
}

interface Entry {
  count: number;
  resetAt: number;
}
