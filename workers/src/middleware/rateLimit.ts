interface RateLimitEntry {
  count: number
  resetAt: number
}

/**
 * P1-1: Rate limiter backed by a Durable Object so the read-then-write is
 * serialized by the DO's single-threaded execution model. No more TOCTOU race,
 * no more recursive retry / stack overflow under load.
 *
 * Each (prefix, key) pair maps to a unique DO instance via `idFromName`. The
 * naming scheme is stable: a given input always maps to the same DO.
 */
export class RateLimiter {
  constructor(
    private binding: DurableObjectNamespace,
    private prefix: string,
  ) {}

  private async call(key: string, max: number, windowSec: number, method: 'GET' | 'DELETE' = 'GET'): Promise<Response> {
    // Defensive: if the DO binding isn't available (e.g., first deploy
    // before the migration runs, or an old worker version), fail open
    // rather than throwing — the user shouldn't be locked out by a
    // missing binding.
    if (!this.binding || typeof (this.binding as any).idFromName !== 'function') {
      throw new Error('RATE_LIMITER binding unavailable');
    }
    const doId = this.binding.idFromName(`${this.prefix}:${key}`);
    const stub = this.binding.get(doId);
    const url = `https://rate/${encodeURIComponent(key)}?max=${max}&window=${windowSec}`;
    return stub.fetch(url, { method });
  }

  async check(key: string, maxAttempts: number, windowSeconds: number): Promise<{ allowed: boolean; remaining: number; resetAt: number }> {
    try {
      const resp = await this.call(key, maxAttempts, windowSeconds);
      return await resp.json() as { allowed: boolean; remaining: number; resetAt: number };
    } catch (e) {
      // P1-1: fail open. If the DO is unavailable (cold start, transient
      // network, class not yet migrated), allow the request rather than
      // 500ing the user. The cost is a brief window of unlimited traffic;
      // refusing to 5xx is the right trade-off for an auth path.
      console.error('[rate-limit] DO call failed, failing open:', e);
      return { allowed: true, remaining: maxAttempts, resetAt: Date.now() + windowSeconds * 1000 };
    }
  }

  async reset(key: string): Promise<void> {
    // Reset with a synthetic call — the DO deletes the key on DELETE.
    try {
      await this.call(key, 0, 60, 'DELETE');
    } catch (e) {
      // Swallow — the next check will refresh the window anyway.
    }
  }
}

export function getClientIP(request: Request): string {
  return request.headers.get('CF-Connecting-IP') || 'unknown'
}
