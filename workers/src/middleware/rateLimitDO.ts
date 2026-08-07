const MAX_ACCOUNT_BUCKETS = 128;

interface Bucket {
  count: number;
  resetAt: number;
}

interface CheckBody {
  limits: Array<{ key: string; max: number; windowSeconds: number }>;
}

export class RateLimiterDO implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    if (request.method === 'DELETE') {
      const body = await request.json<{ keys?: string[] }>();
      const keys = (body.keys ?? []).map((key) => `bucket:${key}`);
      if (keys.length > 0) await this.state.storage.delete(keys);
      await this.scheduleNextAlarm();
      return Response.json({ ok: true });
    }
    if (request.method !== 'POST') return new Response('Method Not Allowed', { status: 405 });

    const body = await request.json<CheckBody>();
    if (!Array.isArray(body.limits) || body.limits.length !== 2) {
      return Response.json({ error: 'Invalid limits' }, { status: 400 });
    }
    const now = Date.now();
    const active = new Map<string, Bucket>();
    for (const rule of body.limits) {
      if (!/^(ip|account:[\w\-一-鿿]{1,32})$/u.test(rule.key)
          || !Number.isInteger(rule.max) || rule.max < 1
          || !Number.isInteger(rule.windowSeconds) || rule.windowSeconds < 1) {
        return Response.json({ error: 'Invalid limit rule' }, { status: 400 });
      }
      const stored = await this.state.storage.get<Bucket>(`bucket:${rule.key}`);
      active.set(rule.key, stored && stored.resetAt > now
        ? stored
        : { count: 0, resetAt: now + rule.windowSeconds * 1000 });
    }

    const accountRule = body.limits.find((rule) => rule.key.startsWith('account:'))!;
    const accountStorageKey = `bucket:${accountRule.key}`;
    if (!(await this.state.storage.get(accountStorageKey))) {
      // storage.list is paginated; walk pages so capacity counts every account bucket.
      let activeAccountCount = 0;
      const expiredAccountKeys: string[] = [];
      let cursor: string | undefined;
      for (;;) {
        const page = await this.state.storage.list<Bucket>({
          prefix: 'bucket:account:',
          limit: 128,
          ...(cursor ? { startAfter: cursor } : {}),
        });
        if (page.size === 0) break;
        for (const [key, bucket] of page) {
          if (bucket.resetAt <= now) expiredAccountKeys.push(key);
          else activeAccountCount += 1;
          cursor = key;
        }
        if (page.size < 128) break;
      }
      if (expiredAccountKeys.length > 0) await this.state.storage.delete(expiredAccountKeys);
      if (activeAccountCount >= MAX_ACCOUNT_BUCKETS) {
        return Response.json({
          allowed: false,
          remaining: 0,
          resetAt: now + 1000,
          limitedBy: 'capacity',
        });
      }
    }

    for (const rule of body.limits) {
      const bucket = active.get(rule.key)!;
      if (bucket.count >= rule.max) {
        return Response.json({ allowed: false, remaining: 0, resetAt: bucket.resetAt, limitedBy: rule.key });
      }
    }

    for (const rule of body.limits) active.get(rule.key)!.count += 1;
    await this.state.storage.put(Object.fromEntries(
      [...active].map(([key, bucket]) => [`bucket:${key}`, bucket]),
    ));
    await this.scheduleNextAlarm();
    const remaining = Math.min(...body.limits.map((rule) => rule.max - active.get(rule.key)!.count));
    const resetAt = Math.max(...[...active.values()].map((bucket) => bucket.resetAt));
    return Response.json({ allowed: true, remaining, resetAt });
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const entries = await this.state.storage.list<Bucket>({ prefix: 'bucket:' });
    const expired = [...entries]
      .filter(([, bucket]) => bucket.resetAt <= now)
      .map(([key]) => key);
    if (expired.length > 0) await this.state.storage.delete(expired);
    await this.scheduleNextAlarm();
  }

  private async scheduleNextAlarm(): Promise<void> {
    const entries = await this.state.storage.list<Bucket>({ prefix: 'bucket:' });
    if (entries.size === 0) {
      await this.state.storage.deleteAlarm();
      await this.state.storage.deleteAll();
      return;
    }
    await this.state.storage.setAlarm(Math.min(...[...entries.values()].map((bucket) => bucket.resetAt)));
  }
}
