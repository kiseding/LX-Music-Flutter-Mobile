import { env, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import {
  RateLimiter,
  RateLimiterUnavailableError,
  type RateLimitRule,
} from '../src/middleware/rateLimit';
import type { RateLimiterDO } from '../src/middleware/rateLimitDO';
import type { Env } from '../src/lib/response';
import { handleUserLogin, handleUserRegister } from '../src/routes/user/auth';

const loginRules = (account: string): RateLimitRule[] => [
  { key: 'ip', max: 20, windowSeconds: 60 },
  { key: `account:${account}`, max: 5, windowSeconds: 60 },
];

describe('RateLimiter adapter', () => {
  it('fails closed when the binding call fails', async () => {
    const binding = {
      idFromName: () => ({}) as DurableObjectId,
      get: () => ({ fetch: async () => { throw new Error('DO unavailable'); } }),
    } as unknown as DurableObjectNamespace;
    const limiter = new RateLimiter(binding);

    await expect(limiter.check('203.0.113.1', loginRules('alice')))
      .rejects.toBeInstanceOf(RateLimiterUnavailableError);
  });

  it.each([
    ['login', handleUserLogin, { username: 'alice', password: 'password' }],
    ['register', handleUserRegister, { username: 'alice', password: 'password' }],
  ])('returns a controlled 503 from %s when limiting is unavailable', async (_name, handler, body) => {
    const binding = {
      idFromName: () => ({}) as DurableObjectId,
      get: () => ({ fetch: async () => { throw new Error('DO unavailable'); } }),
    } as unknown as DurableObjectNamespace;
    const request = new Request(`https://worker.test/api/user/${_name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.1' },
      body: JSON.stringify(body),
    });

    const response = await handler(request, { RATE_LIMITER: binding } as Env);

    expect(response.status).toBe(503);
    expect(response.headers.get('Retry-After')).toBe('60');
    expect(await response.json()).toEqual({ error: '认证服务暂时不可用' });
  });
});

describe('RateLimiterDO', () => {
  it('enforces the account and IP limits in the same IP shard', async () => {
    const limiter = new RateLimiter(env.RATE_LIMITER);
    for (let attempt = 0; attempt < 5; attempt += 1) {
      expect((await limiter.check('203.0.113.2', loginRules('alice'))).allowed).toBe(true);
    }
    const accountDenied = await limiter.check('203.0.113.2', loginRules('alice'));
    expect(accountDenied).toMatchObject({ allowed: false, limitedBy: 'account:alice' });

    for (let attempt = 0; attempt < 15; attempt += 1) {
      expect((await limiter.check('203.0.113.2', loginRules(`user-${attempt}`))).allowed).toBe(true);
    }
    const ipDenied = await limiter.check('203.0.113.2', loginRules('last-user'));
    expect(ipDenied).toMatchObject({ allowed: false, limitedBy: 'ip' });
  });

  it('bounds account storage and removes expired state on alarm', async () => {
    const limiter = new RateLimiter(env.RATE_LIMITER);
    const ip = '203.0.113.3';
    // Use a long window so mid-test alarm cleanup cannot free capacity slots.
    const longWindow = 3600;
    for (let account = 0; account < 128; account += 1) {
      const result = await limiter.check(ip, [
        { key: 'ip', max: 1000, windowSeconds: longWindow },
        { key: `account:user-${account}`, max: 1000, windowSeconds: longWindow },
      ]);
      expect(result.allowed).toBe(true);
    }
    const overflow = await limiter.check(ip, [
      { key: 'ip', max: 1000, windowSeconds: longWindow },
      { key: 'account:overflow', max: 1000, windowSeconds: longWindow },
    ]);
    expect(overflow).toMatchObject({ allowed: false, limitedBy: 'capacity' });

    const stub = env.RATE_LIMITER.get(env.RATE_LIMITER.idFromName(`auth-ip:${ip}`));
    await runInDurableObject(stub, async (_instance: RateLimiterDO, state) => {
      const entries = await state.storage.list({ prefix: 'bucket:' });
      expect(entries.size).toBe(129);
      await state.storage.put(Object.fromEntries(
        [...entries.keys()].map((key) => [key, { count: 1, resetAt: Date.now() - 1 }]),
      ));
      // Miniflare auto-fires past alarms before runDurableObjectAlarm can observe them;
      // schedule slightly in the future so the alarm handler is still exercised manually.
      await state.storage.deleteAlarm();
      await state.storage.setAlarm(Date.now() + 60_000);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    await runInDurableObject(stub, async (_instance: RateLimiterDO, state) => {
      expect((await state.storage.list({ prefix: 'bucket:' })).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });
});
