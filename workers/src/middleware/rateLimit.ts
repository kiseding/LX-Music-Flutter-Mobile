export interface RateLimitRule {
  key: string;
  max: number;
  windowSeconds: number;
}

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  resetAt: number;
  limitedBy?: string;
}

export class RateLimiterUnavailableError extends Error {
  constructor() {
    super('Authentication rate limiter unavailable');
    this.name = 'RateLimiterUnavailableError';
  }
}

export class RateLimiter {
  constructor(private readonly binding: DurableObjectNamespace) {}

  async check(ip: string, limits: RateLimitRule[]): Promise<RateLimitResult> {
    try {
      if (!this.binding || typeof this.binding.idFromName !== 'function') {
        throw new Error('RATE_LIMITER binding unavailable');
      }
      const stub = this.binding.get(this.binding.idFromName(`auth-ip:${ip}`));
      const response = await stub.fetch('https://rate/check', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ limits }),
      });
      if (!response.ok) throw new Error(`Rate limiter returned ${response.status}`);
      const result = await response.json<RateLimitResult>();
      if (typeof result.allowed !== 'boolean' || !Number.isFinite(result.resetAt)) {
        throw new Error('Malformed rate limiter response');
      }
      return result;
    } catch (error) {
      console.error({ event: 'rate_limit_unavailable', error: String(error) });
      throw new RateLimiterUnavailableError();
    }
  }

  async reset(ip: string, keys: string[]): Promise<void> {
    try {
      const stub = this.binding.get(this.binding.idFromName(`auth-ip:${ip}`));
      const response = await stub.fetch('https://rate/reset', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ keys }),
      });
      if (!response.ok) throw new Error(`Rate limiter reset returned ${response.status}`);
    } catch (error) {
      console.error({ event: 'rate_limit_reset_failed', error: String(error) });
    }
  }
}

export function getClientIP(request: Request): string {
  return request.headers.get('CF-Connecting-IP') || 'unknown';
}
