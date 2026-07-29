# Worker and iOS Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete approved Batch D by moving D1 schema work out of requests, making authentication limiting fail closed and bounded, using CSPRNG bytes in the custom-source host, sanitizing Worker 500 responses, updating Worker runtime observability, and bundling the existing iOS privacy manifest.

**Architecture:** D1 schema changes become deployment migrations, while requests perform read-only readiness checks before routing. One Durable Object per client IP atomically enforces an IP bucket plus bounded account buckets and deletes expired storage by alarm; infrastructure errors become controlled authentication `503` responses. Worker tests run in the Workers runtime, narrow structural scripts protect deployment/Xcode boundaries, and the Flutter JS bridge obtains random bytes from Dart `Random.secure()`.

**Tech Stack:** TypeScript ES2022, Cloudflare Workers/D1/KV/SQLite Durable Objects, Wrangler 4.112.0, Vitest 4.1.x with `@cloudflare/vitest-pool-workers` 0.19.x, Dart/Flutter, JavaScriptCore/QuickJS through `flutter_js`, Xcode `.pbxproj`.

## Global Constraints

- Implement only approved spec Batch D from `docs/superpowers/specs/2026-07-29-runtime-audit-remediation-design.md`.
- Preserve anonymous playlist preview fan-out behavior unchanged; do not bound or serialize Phase 1 upstream requests in `workers/src/routes/playlist-import.ts`.
- Preserve unbounded authenticated Phase 2 request body and song-count behavior unchanged; do not add body, `songs`, or playlist-size limits in `workers/src/routes/playlist-import.ts`.
- Avoid unrelated refactors and major dependency upgrades; add only focused Worker test dependencies compatible with the pinned Wrangler 4.112.0 toolchain.
- Work directly in `/tmp/opencode/LX2IOS-main`; this tree has no Git metadata, so do not run `git` commands and do not add commit steps.
- Do not log request bodies, `Authorization`, passwords, tokens, `ADMIN_PASSWORD`, or `TINYAPI_KEY`.
- Use `2026-07-29` as the advanced Worker compatibility date and retain `nodejs_compat`.
- Linux cannot archive or inspect an iOS app bundle; keep the archive/bundle verification as an explicit macOS check.

---

## File Map

- Create `workers/test/env.d.ts`: type the Workers test environment.
- Create `workers/test/rate-limit.test.ts`: cover fail-closed adapter behavior, dual limits, storage bounds, resets, and alarm cleanup.
- Create `workers/test/error-response.test.ts`: cover generic `500` responses, request IDs, and structured server logs.
- Create `workers/vitest.config.ts`: run tests with the existing Wrangler configuration.
- Create `workers/scripts/check-batch-d-structure.mjs`: enforce schema-free request code, excluded-import invariants, safe observability config, and privacy-manifest project membership.
- Create `workers/migrations/0001_initial.sql`: deployment-owned current D1 schema for new databases.
- Create `workers/migrations/0002_love_song_uniqueness.sql`: deployment-owned data repair and unique-index reconstruction for existing data.
- Modify `workers/package.json` and `workers/package-lock.json`: add focused Worker tests and structural-check scripts without upgrading existing major dependencies.
- Modify `workers/wrangler.toml`: register D1 migrations, advance compatibility date, and enable sampled logs/traces.
- Modify `workers/src/db/schema.ts`: replace executable schema SQL with read-only readiness checking.
- Modify `workers/src/routes/user/auth.ts`: remove request-time DDL/patch fallback and return controlled limiter-unavailable responses.
- Modify `workers/src/utils/jwt.ts`: stop creating `system_settings` during a request.
- Modify `workers/src/middleware/rateLimit.ts`: expose the IP-sharded, fail-closed limiter adapter.
- Modify `workers/src/middleware/rateLimitDO.ts`: atomically enforce dual buckets with a hard account bound and alarm cleanup.
- Modify `workers/src/lib/response.ts`: define generic internal-error and schema-unavailable response helpers.
- Modify `workers/src/index.ts`: assign request IDs, run schema readiness before DB-backed routes, and sanitize unexpected errors.
- Modify `workers/README.md`: document migration-before-deploy ordering and observability behavior.
- Modify `.github/workflows/deploy-workers.yml`: run tests/checks and apply remote D1 migrations before deployment.
- Modify `lib/features/custom_source/domain/custom_source_engine.dart`: bridge `randomBytes` to Dart CSPRNG bytes.
- Modify `test/features/custom_source/domain/custom_source_engine_test.dart`: regress CSPRNG shape and bridge structure.
- Modify `ios/Runner.xcodeproj/project.pbxproj`: add the existing `ios/Runner/PrivacyInfo.xcprivacy` to the Runner group and Copy Bundle Resources.
- Modify `.github/workflows/build-ios.yml`: assert the privacy manifest is present in the built Runner bundle.

### Task 1: Add Worker Test and Structural-Check Baseline

**Files:**
- Create: `workers/vitest.config.ts`
- Create: `workers/test/env.d.ts`
- Create: `workers/scripts/check-batch-d-structure.mjs`
- Modify: `workers/package.json`
- Modify: `workers/package-lock.json`
- Test: `workers/scripts/check-batch-d-structure.mjs`

**Interfaces:**
- Consumes: `workers/wrangler.toml`, `workers/src/**/*.ts`, `workers/src/routes/playlist-import.ts`, and `ios/Runner.xcodeproj/project.pbxproj` as text inputs.
- Produces: `npm test`, `npm run check:batch-d`, and Workers-runtime imports from `cloudflare:test` for later tasks.

- [ ] **Step 1: Add the focused test dependencies and scripts**

Run from `workers/`:

```bash
npm install --save-dev --save-exact vitest@4.1.10 @cloudflare/vitest-pool-workers@0.19.0
```

Then make the `scripts` object in `workers/package.json` exactly include these entries while preserving `deploy` and `dev`:

```json
{
  "scripts": {
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "check:batch-d": "node scripts/check-batch-d-structure.mjs",
    "validate": "npm test && npm run typecheck && npm run check:batch-d",
    "deploy": "npm run validate && wrangler deploy",
    "dev": "wrangler dev"
  }
}
```

Expected: `package-lock.json` records Vitest 4.1.10 and the Workers pool 0.19.0; Wrangler remains 4.112.0 and TypeScript remains on the existing 5.x range.

- [ ] **Step 2: Configure the Workers test pool**

Create `workers/vitest.config.ts`:

```typescript
import { defineWorkersConfig } from '@cloudflare/vitest-pool-workers/config';

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: './wrangler.toml' },
      },
    },
  },
});
```

Create `workers/test/env.d.ts`:

```typescript
import type { Env } from '../src/lib/response';

declare module 'cloudflare:test' {
  interface ProvidedEnv extends Env {}
}
```

- [ ] **Step 3: Write the initially failing Batch D structural check**

Create `workers/scripts/check-batch-d-structure.mjs`:

```javascript
import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const repo = resolve(root, '..');

function fail(message) {
  console.error(`Batch D structural check failed: ${message}`);
  process.exitCode = 1;
}

function sourceFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : entry.name.endsWith('.ts') ? [path] : [];
  });
}

const runtimeSource = sourceFiles(join(root, 'src'))
  .map((path) => readFileSync(path, 'utf8'))
  .join('\n');
const importRoute = readFileSync(join(root, 'src/routes/playlist-import.ts'), 'utf8');
const wrangler = readFileSync(join(root, 'wrangler.toml'), 'utf8');
const project = readFileSync(join(repo, 'ios/Runner.xcodeproj/project.pbxproj'), 'utf8');

if (/\b(?:CREATE|ALTER|DROP)\s+(?:TABLE|INDEX)\b/i.test(runtimeSource)) {
  fail('workers/src still contains request-time DDL');
}
if (!importRoute.includes('const allResults = await Promise.all(')) {
  fail('anonymous preview fan-out changed');
}
if (!importRoute.includes('No hard cap on playlist size.')) {
  fail('unbounded Phase 2 song behavior changed');
}
if (/MAX_(?:BODY|SONGS|PLAYLIST)|songs\.length\s*>|content-length/i.test(importRoute)) {
  fail('an excluded playlist-import bound was introduced');
}
if (!wrangler.includes('compatibility_date = "2026-07-29"')) {
  fail('compatibility date is not 2026-07-29');
}
if (!wrangler.includes('[observability.logs]') || !wrangler.includes('[observability.traces]')) {
  fail('sampled logs and traces are not configured');
}
const privacyMentions = project.match(/PrivacyInfo\.xcprivacy/g)?.length ?? 0;
if (privacyMentions !== 3 || !project.includes('PrivacyInfo.xcprivacy in Resources')) {
  fail('PrivacyInfo.xcprivacy is not referenced once in file, group, and Runner resources');
}
if (/console\.(?:log|error|warn)\([^\n]*(?:Authorization|ADMIN_PASSWORD|TINYAPI_KEY|password|token)/i.test(runtimeSource)) {
  fail('runtime logging may include credentials');
}

if (!process.exitCode) console.log('Batch D structural checks passed.');
```

- [ ] **Step 4: Run the structural check to verify the baseline is red**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm run check:batch-d`

Expected: FAIL with at least `workers/src still contains request-time DDL`, `compatibility date is not 2026-07-29`, and `PrivacyInfo.xcprivacy is not referenced once in file, group, and Runner resources`.

### Task 2: Move D1 Schema Mutation to Deployment

**Files:**
- Create: `workers/migrations/0001_initial.sql`
- Create: `workers/migrations/0002_love_song_uniqueness.sql`
- Modify: `workers/wrangler.toml`
- Modify: `workers/src/db/schema.ts`
- Modify: `workers/src/routes/user/auth.ts`
- Modify: `workers/src/utils/jwt.ts`
- Modify: `workers/src/index.ts`
- Modify: `workers/README.md`
- Modify: `.github/workflows/deploy-workers.yml`
- Test: `workers/scripts/check-batch-d-structure.mjs`

**Interfaces:**
- Consumes: D1 binding `Env.DB` and Wrangler's `d1 migrations apply lx-music-api --remote` command.
- Produces: `checkSchemaReady(env: Env): Promise<SchemaReadiness>`, where `SchemaReadiness` is `{ ready: true } | { ready: false; reason: string }`; deployment migrations become the only DDL owner.

- [ ] **Step 1: Add deployment-owned migration SQL**

Create `workers/migrations/0001_initial.sql`:

```sql
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  token_version INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS system_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS playlists (
  id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  position INTEGER NOT NULL DEFAULT 0,
  source TEXT DEFAULT '',
  source_id TEXT DEFAULT '',
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (id, user_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS playlist_songs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  playlist_id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  singer TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  songmid TEXT DEFAULT '',
  album_name TEXT DEFAULT '',
  album_id TEXT DEFAULT '',
  img TEXT DEFAULT '',
  interval TEXT DEFAULT '',
  types TEXT DEFAULT '[]',
  hash TEXT DEFAULT '',
  str_media_mid TEXT DEFAULT '',
  copyright_id TEXT DEFAULT '',
  metadata TEXT DEFAULT '{}',
  position INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (playlist_id, user_id) REFERENCES playlists(id, user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_artists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  artist_id TEXT NOT NULL,
  name TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  img TEXT DEFAULT '',
  data TEXT DEFAULT '{}',
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(user_id, artist_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_albums (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  album_id TEXT NOT NULL,
  name TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  img TEXT DEFAULT '',
  singer TEXT DEFAULT '',
  data TEXT DEFAULT '{}',
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(user_id, album_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id INTEGER PRIMARY KEY,
  settings TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS playback_progress (
  user_id INTEGER NOT NULL,
  song_id TEXT NOT NULL,
  position REAL NOT NULL DEFAULT 0,
  duration REAL NOT NULL DEFAULT 0,
  updated_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, song_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

Create `workers/migrations/0002_love_song_uniqueness.sql`:

```sql
UPDATE playlist_songs
SET songmid = '_empty_' || rowid
WHERE songmid = '';

DELETE FROM playlist_songs
WHERE rowid NOT IN (
  SELECT MIN(rowid)
  FROM playlist_songs
  GROUP BY playlist_id, user_id, songmid, source
);

DROP INDEX IF EXISTS uniq_ps_love_song;
CREATE UNIQUE INDEX uniq_ps_love_song
  ON playlist_songs(playlist_id, user_id, songmid, source);
CREATE INDEX IF NOT EXISTS idx_ps_playlist_user ON playlist_songs(playlist_id, user_id);
CREATE INDEX IF NOT EXISTS idx_ps_position ON playlist_songs(playlist_id, user_id, position);
CREATE INDEX IF NOT EXISTS idx_ps_songid ON playlist_songs(hash, source);
CREATE INDEX IF NOT EXISTS idx_ps_songmid ON playlist_songs(songmid, source);
CREATE INDEX IF NOT EXISTS idx_pls_user_updated ON playlists(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_artists_user ON user_artists(user_id);
CREATE INDEX IF NOT EXISTS idx_artists_lookup ON user_artists(user_id, artist_id, source);
CREATE INDEX IF NOT EXISTS idx_albums_user ON user_albums(user_id);
CREATE INDEX IF NOT EXISTS idx_albums_lookup ON user_albums(user_id, album_id, source);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_settings_user ON user_settings(user_id);
```

In the existing `[[d1_databases]]` block in `workers/wrangler.toml`, add:

```toml
migrations_dir = "migrations"
```

Do not add `ALTER TABLE users ADD COLUMN token_version` to a repeatable migration: the current request-time patch has already upgraded deployed databases, while `0001_initial.sql` creates the column for new databases. Before applying these migrations remotely, the deployment preflight below must stop with an explicit remediation command if an old database somehow still lacks the column.

- [ ] **Step 2: Replace executable schema text with a read-only readiness API**

Replace `workers/src/db/schema.ts` with:

```typescript
import type { Env } from '../lib/response';

export type SchemaReadiness =
  | { ready: true }
  | { ready: false; reason: string };

export async function checkSchemaReady(env: Env): Promise<SchemaReadiness> {
  try {
    const [tables, columns, index] = await env.DB.batch([
      env.DB.prepare(`
        SELECT COUNT(*) AS count
        FROM sqlite_master
        WHERE type = 'table'
          AND name IN (
            'users', 'system_settings', 'playlists', 'playlist_songs',
            'user_artists', 'user_albums', 'user_settings', 'playback_progress'
          )
      `),
      env.DB.prepare("PRAGMA table_info('users')"),
      env.DB.prepare(`
        SELECT COUNT(*) AS count
        FROM sqlite_master
        WHERE type = 'index' AND name = 'uniq_ps_love_song'
      `),
    ]);
    const tableCount = Number((tables.results?.[0] as { count?: number } | undefined)?.count ?? 0);
    const hasTokenVersion = (columns.results as Array<{ name?: string }> | undefined)
      ?.some((column) => column.name === 'token_version') ?? false;
    const indexCount = Number((index.results?.[0] as { count?: number } | undefined)?.count ?? 0);
    if (tableCount !== 8 || !hasTokenVersion || indexCount !== 1) {
      return { ready: false, reason: 'D1 migrations are pending' };
    }
    return { ready: true };
  } catch {
    return { ready: false, reason: 'D1 readiness check failed' };
  }
}
```

- [ ] **Step 3: Remove every request-time schema mutation**

In `workers/src/routes/user/auth.ts`:

- Delete the `SCHEMA_SQL` import.
- Replace `selectUserByUsername` with one direct `SELECT`; remove its missing-column catch/retry.
- Delete `_patchesApplied`, `_lastPatchError`, `applySchemaPatches`, `ensureSchemaPatches`, and `getLastPatchError`.
- Remove `env.DB.exec(SCHEMA_SQL)` and `applySchemaPatches(env)` from `seedAdminUser`.
- Update seed-lock comments so they describe only admin creation, not schema execution.

The resulting lookup must be:

```typescript
async function selectUserByUsername(
  env: Env,
  username: string,
): Promise<{ id: number; password_hash: string; role: string; token_version: number } | null> {
  return env.DB.prepare(
    'SELECT id, password_hash, role, token_version FROM users WHERE username = ?',
  ).bind(username).first<{
    id: number;
    password_hash: string;
    role: string;
    token_version: number;
  }>();
}
```

In `workers/src/utils/jwt.ts`, delete this request-time DDL line and leave the following `SELECT`/`INSERT OR IGNORE` initialization intact:

```typescript
await env.DB.exec("CREATE TABLE IF NOT EXISTS system_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT (datetime('now')))");
```

- [ ] **Step 4: Gate DB-backed API routes with the read-only check**

Import `checkSchemaReady` in `workers/src/index.ts`. Immediately after handling `OPTIONS`, run the check for `/api/*` except `/api/ping` and `/api/version`:

```typescript
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
      jsonResponse({ error: '服务尚未完成数据库迁移', requestId }, 503),
      request,
    );
  }
}
```

This snippet consumes `requestId` introduced in Task 5. During execution, implement Task 5's request-ID declaration first within the same edit so TypeScript remains buildable between checks.

- [ ] **Step 5: Put migration checks before deployment**

In `.github/workflows/deploy-workers.yml`, after replacing IDs and before dry-run/deploy, add:

```yaml
      - name: Verify legacy D1 schema and apply migrations
        run: |
          set -euo pipefail
          COLUMNS="$(npx wrangler d1 execute lx-music-api --remote --json --command "PRAGMA table_info('users')")"
          if printf '%s' "$COLUMNS" | jq -e '.[0].results | length == 0 or any(.name == "token_version")' >/dev/null; then
            npx wrangler d1 migrations apply lx-music-api --remote
          else
            echo "users.token_version is missing; run the approved one-time ALTER TABLE migration before deployment" >&2
            exit 1
          fi
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

Also add `npm test` and `npm run check:batch-d` after Typecheck, before stamping/deployment. Document in `workers/README.md` that local setup runs `npx wrangler d1 migrations apply lx-music-api --local`, production applies `--remote` before Worker deployment, and a legacy database lacking `token_version` requires this one-time command before normal migrations:

```bash
npx wrangler d1 execute lx-music-api --remote \
  --command "ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0"
```

- [ ] **Step 6: Run red/green migration boundary checks**

Run before removing the DDL: `cd /tmp/opencode/LX2IOS-main/workers && npm run check:batch-d`

Expected before implementation: FAIL with `workers/src still contains request-time DDL`.

Run after implementation: `cd /tmp/opencode/LX2IOS-main/workers && npm run check:batch-d`

Expected at this stage: the request-time DDL failure is gone; later compatibility/privacy checks may still fail until Tasks 6 and 7.

Run: `cd /tmp/opencode/LX2IOS-main/workers && npx wrangler d1 migrations apply lx-music-api --local && npx wrangler d1 migrations list lx-music-api --local`

Expected: both migration files apply successfully and the list reports no pending local migrations.

### Task 3: Implement Fail-Closed, Bounded Dual Authentication Limits

**Files:**
- Create: `workers/test/rate-limit.test.ts`
- Modify: `workers/src/middleware/rateLimit.ts`
- Modify: `workers/src/middleware/rateLimitDO.ts`
- Modify: `workers/src/routes/user/auth.ts`
- Test: `workers/test/rate-limit.test.ts`

**Interfaces:**
- Consumes: `Env.RATE_LIMITER`, client IP, and normalized username.
- Produces: `RateLimiter.check(ip: string, limits: RateLimitRule[]): Promise<RateLimitResult>`, `RateLimiter.reset(ip: string, keys: string[]): Promise<void>`, and `RateLimiterUnavailableError`; one DO named `auth-ip:${ip}` stores at most `MAX_ACCOUNT_BUCKETS = 128` account entries plus the IP entry.

- [ ] **Step 1: Write failing adapter and DO tests**

Create `workers/test/rate-limit.test.ts`:

```typescript
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
    for (let account = 0; account < 128; account += 1) {
      const result = await limiter.check(ip, [
        { key: 'ip', max: 1000, windowSeconds: 1 },
        { key: `account:user-${account}`, max: 1000, windowSeconds: 1 },
      ]);
      expect(result.allowed).toBe(true);
    }
    const overflow = await limiter.check(ip, [
      { key: 'ip', max: 1000, windowSeconds: 1 },
      { key: 'account:overflow', max: 1000, windowSeconds: 1 },
    ]);
    expect(overflow).toMatchObject({ allowed: false, limitedBy: 'capacity' });

    const stub = env.RATE_LIMITER.get(env.RATE_LIMITER.idFromName(`auth-ip:${ip}`));
    await runInDurableObject(stub, async (_instance: RateLimiterDO, state) => {
      const entries = await state.storage.list({ prefix: 'bucket:' });
      expect(entries.size).toBe(129);
      await state.storage.put(Object.fromEntries(
        [...entries.keys()].map((key) => [key, { count: 1, resetAt: Date.now() - 1 }]),
      ));
      await state.storage.setAlarm(Date.now() - 1);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    await runInDurableObject(stub, async (_instance: RateLimiterDO, state) => {
      expect((await state.storage.list({ prefix: 'bucket:' })).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm test -- test/rate-limit.test.ts`

Expected: FAIL because `RateLimitRule`, `RateLimiterUnavailableError`, the new constructor/API, bounded capacity, and `alarm()` do not exist.

- [ ] **Step 3: Implement the fail-closed IP-sharded adapter**

Replace `workers/src/middleware/rateLimit.ts` with:

```typescript
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
```

- [ ] **Step 4: Implement bounded buckets and alarm deletion**

In `workers/src/middleware/rateLimitDO.ts`, retain the `RateLimiterDO` export but replace the old URL-key implementation with these rules:

```typescript
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
    if (!(await this.state.storage.get(`bucket:${accountRule.key}`))) {
      const accounts = await this.state.storage.list<Bucket>({ prefix: 'bucket:account:' });
      const expiredAccounts = [...accounts]
        .filter(([, bucket]) => bucket.resetAt <= now)
        .map(([key]) => key);
      if (expiredAccounts.length > 0) await this.state.storage.delete(expiredAccounts);
      if (accounts.size - expiredAccounts.length >= MAX_ACCOUNT_BUCKETS) {
        return Response.json({ allowed: false, remaining: 0, resetAt: now + 1000, limitedBy: 'capacity' });
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
    const resetAt = Math.max(...active.values().map((bucket) => bucket.resetAt));
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
      return;
    }
    await this.state.storage.setAlarm(Math.min(...[...entries.values()].map((bucket) => bucket.resetAt)));
  }
}
```

Keep the two checks and writes in one DO invocation; do not issue parallel IP/account DO calls, which would make the dual decision non-atomic.

- [ ] **Step 5: Wire controlled `503` responses into login and registration**

In `workers/src/routes/user/auth.ts`, normalize once and use these exact limits:

```typescript
const LOGIN_IP_MAX = 20;
const LOGIN_ACCOUNT_MAX = 5;
const LOGIN_WINDOW_SECONDS = 60;
const REGISTER_IP_MAX = 10;
const REGISTER_ACCOUNT_MAX = 3;
const REGISTER_WINDOW_SECONDS = 3600;
```

Construct `new RateLimiter(env.RATE_LIMITER)`. For login, call `check(ip, [{ key: 'ip', max: 20, windowSeconds: 60 }, { key: 'account:<normalized>', max: 5, windowSeconds: 60 }])`; for registration, use `10` and `3` with `3600`. Catch only `RateLimiterUnavailableError` and return:

```typescript
return jsonResponse(
  { error: '认证服务暂时不可用' },
  503,
  { 'Retry-After': '60' },
);
```

Task 5 extends `jsonResponse` with the third `headers` parameter. On a successful login reset only `account:<normalized>` in that IP shard; do not reset the shared IP bucket. Remove `loginRateLimitKey`, because the DO name must no longer include username.

- [ ] **Step 6: Run focused tests to green**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm test -- test/rate-limit.test.ts`

Expected: PASS; the account rejects attempt 6, the IP rejects aggregate attempt 21, the 129th account bucket is denied, and alarm execution removes all 129 expired entries.

### Task 4: Use CSPRNG for Custom-Source `crypto.randomBytes`

**Files:**
- Modify: `lib/features/custom_source/domain/custom_source_engine.dart`
- Modify: `test/features/custom_source/domain/custom_source_engine_test.dart`
- Test: `test/features/custom_source/domain/custom_source_engine_test.dart`

**Interfaces:**
- Consumes: Dart `Random.secure()` and synchronous `flutter_js` `lx_crypto` bridge messages.
- Produces: `List<int> secureRandomBytes(int size, {Random? random})`; JavaScript `lx.utils.crypto.randomBytes(size)` still returns the existing Buffer-compatible object synchronously.

- [ ] **Step 1: Write failing CSPRNG and bridge tests**

Add `import 'package:lx_music_flutter/features/custom_source/domain/custom_source_engine.dart';` to `test/features/custom_source/domain/custom_source_engine_test.dart`, then append:

```dart
test('secureRandomBytes returns independent bytes with the requested shape', () {
  final first = secureRandomBytes(32);
  final second = secureRandomBytes(32);

  expect(first, hasLength(32));
  expect(first.every((byte) => byte >= 0 && byte <= 255), isTrue);
  expect(second, hasLength(32));
  expect(second, isNot(equals(first)));
  expect(() => secureRandomBytes(-1), throwsRangeError);
  expect(() => secureRandomBytes(65537), throwsRangeError);
});

test('LX randomBytes delegates to the Dart crypto bridge', () {
  final bridge = File(
    'lib/features/custom_source/domain/custom_source_engine.dart',
  ).readAsStringSync();
  final randomBytesBlock = RegExp(
    r'globalThis\.lx\.utils\.crypto\.randomBytes = function\(size\) \{([\s\S]*?)\n      \};',
  ).firstMatch(bridge)!.group(1)!;

  expect(bridge, contains("method == 'randomBytes'"));
  expect(randomBytesBlock, contains("sendMessage('lx_crypto'"));
  expect(randomBytesBlock, isNot(contains('Math.random')));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /tmp/opencode/LX2IOS-main && flutter test test/features/custom_source/domain/custom_source_engine_test.dart`

Expected: FAIL because `secureRandomBytes` is undefined and the JS block still calls `Math.random()`.

- [ ] **Step 3: Add the host CSPRNG and bridge it synchronously**

Add `import 'dart:math';` to `custom_source_engine.dart` and define above `CustomSourceEngine`:

```dart
List<int> secureRandomBytes(int size, {Random? random}) {
  RangeError.checkValueInInterval(size, 0, 65536, 'size');
  final source = random ?? Random.secure();
  return List<int>.generate(size, (_) => source.nextInt(256), growable: false);
}
```

Add this branch to the existing synchronous `lx_crypto` message handler before AES/RSA branches:

```dart
if (method == 'randomBytes') {
  final size = input is num ? input.toInt() : int.parse(input.toString());
  return base64Encode(secureRandomBytes(size));
}
```

Replace only the existing `randomBytes` JS shim with:

```javascript
globalThis.lx.utils.crypto.randomBytes = function(size) {
  var data = sendMessage('lx_crypto', JSON.stringify({ method: 'randomBytes', input: size }));
  return globalThis.lx.utils.buffer.from(data, 'base64');
};
```

Do not change the unrelated `Math.random()` uses that create non-security callback/deferred IDs.

- [ ] **Step 4: Run the focused test to green**

Run: `cd /tmp/opencode/LX2IOS-main && flutter test test/features/custom_source/domain/custom_source_engine_test.dart`

Expected: PASS with the existing Desktop bridge assertions and both new random-byte tests green.

### Task 5: Return Generic Worker 500s with Request IDs

**Files:**
- Create: `workers/test/error-response.test.ts`
- Modify: `workers/src/lib/response.ts`
- Modify: `workers/src/index.ts`
- Modify: `workers/src/routes/user/auth.ts`
- Test: `workers/test/error-response.test.ts`

**Interfaces:**
- Consumes: `unknown` errors plus `{ requestId, method, path }` safe request metadata.
- Produces: `internalServerError(error: unknown, context: ErrorContext): Response`; body `{ error: '服务器错误', requestId }`, matching `X-Request-ID`, and a structured server-side error event.

- [ ] **Step 1: Write the failing generic-error test**

Create `workers/test/error-response.test.ts`:

```typescript
import { describe, expect, it, vi } from 'vitest';
import { internalServerError } from '../src/lib/response';

describe('internalServerError', () => {
  it('returns only a generic error and request ID while logging details', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const response = internalServerError(new Error('secret SQL and upstream URL'), {
      requestId: 'request-123',
      method: 'POST',
      path: '/api/user/login',
    });

    expect(response.status).toBe(500);
    expect(response.headers.get('X-Request-ID')).toBe('request-123');
    expect(await response.json()).toEqual({ error: '服务器错误', requestId: 'request-123' });
    expect(log).toHaveBeenCalledWith(expect.objectContaining({
      event: 'unhandled_request_error',
      requestId: 'request-123',
      error: 'secret SQL and upstream URL',
    }));
    log.mockRestore();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm test -- test/error-response.test.ts`

Expected: FAIL because `internalServerError` is not exported.

- [ ] **Step 3: Add response headers and the generic helper**

Change `jsonResponse` in `workers/src/lib/response.ts` to preserve its current callers while accepting extra headers:

```typescript
export function jsonResponse(data: unknown, status = 200, extraHeaders?: HeadersInit): Response {
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
```

- [ ] **Step 4: Assign and propagate the request ID at the Worker boundary**

At the start of `fetch` in `workers/src/index.ts`, before route processing, add:

```typescript
const requestId = request.headers.get('X-Request-ID') || crypto.randomUUID();
```

Replace the top-level catch body with:

```typescript
} catch (error: unknown) {
  response = internalServerError(error, { requestId, method, path: pathname });
}
```

Before the final `corsResponse`, clone response headers and set `X-Request-ID` when absent so successful/error responses are correlatable too. Remove the nested seed catch that allows login to continue after bootstrap/readiness failure; a failed bootstrap must now propagate to the controlled outer response instead of hiding an infrastructure failure. Keep logs structured and do not include request headers or body.

- [ ] **Step 5: Run the focused test to green**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm test -- test/error-response.test.ts`

Expected: PASS; client JSON excludes `detail`, SQL text, stack, and upstream URL while the structured server log contains the request ID and exception details.

### Task 6: Advance Compatibility Date and Enable Sampled Observability

**Files:**
- Modify: `workers/wrangler.toml`
- Modify: `workers/README.md`
- Test: `workers/scripts/check-batch-d-structure.mjs`

**Interfaces:**
- Consumes: Wrangler 4.112.0 config schema fields `observability.logs` and `observability.traces`.
- Produces: compatibility date `2026-07-29`, 10% persisted structured logs/invocation logs, and 1% persisted traces.

- [ ] **Step 1: Update runtime and observability configuration**

In `workers/wrangler.toml`, retain `compatibility_flags = ["nodejs_compat"]`, change the date, and add:

```toml
compatibility_date = "2026-07-29"

[observability]
enabled = true

[observability.logs]
enabled = true
head_sampling_rate = 0.1
invocation_logs = true
persist = true

[observability.traces]
enabled = true
head_sampling_rate = 0.01
persist = true
```

Add to `workers/README.md`: logs are sampled at 10%, traces at 1%, request IDs correlate generic client errors to server events, and credentials/request bodies must never be logged.

- [ ] **Step 2: Validate config and compatibility behavior**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm run typecheck && npx wrangler deploy --dry-run --outdir /tmp/opencode/lx-worker-dry-run`

Expected: TypeScript exits 0; Wrangler prints a successful dry-run bundle with compatibility date `2026-07-29` and no unknown observability-field diagnostics.

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm run check:batch-d`

Expected at this stage: compatibility and DDL checks pass; only the privacy-manifest check may remain red until Task 7.

### Task 7: Add Privacy Manifest to Runner Resources

**Files:**
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `.github/workflows/build-ios.yml`
- Test: `workers/scripts/check-batch-d-structure.mjs`

**Interfaces:**
- Consumes: existing `ios/Runner/PrivacyInfo.xcprivacy`.
- Produces: one `PBXFileReference`, one `PBXBuildFile`, one Runner group child, and one Runner `PBXResourcesBuildPhase` entry; built `Runner.app/PrivacyInfo.xcprivacy`.

- [ ] **Step 1: Add the exact Xcode project references**

Add these unique IDs to `ios/Runner.xcodeproj/project.pbxproj`:

```text
/* PBXBuildFile */
A7D4291133A1000100000001 /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = A7D4291033A1000100000001 /* PrivacyInfo.xcprivacy */; };

/* PBXFileReference */
A7D4291033A1000100000001 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };

/* Runner PBXGroup children */
A7D4291033A1000100000001 /* PrivacyInfo.xcprivacy */,

/* Runner PBXResourcesBuildPhase files */
A7D4291133A1000100000001 /* PrivacyInfo.xcprivacy in Resources */,
```

Place each line in its matching existing section; do not add the manifest to `RunnerTests` resources.

- [ ] **Step 2: Make CI inspect the built bundle**

In `.github/workflows/build-ios.yml`, immediately after `test -d build/ios/iphoneos/Runner.app`, add:

```bash
test -f build/ios/iphoneos/Runner.app/PrivacyInfo.xcprivacy
plutil -lint build/ios/iphoneos/Runner.app/PrivacyInfo.xcprivacy
```

After the IPA is created, add:

```bash
unzip -Z1 build/ios/LX-Music-unsigned.ipa | grep -qx 'Payload/Runner.app/PrivacyInfo.xcprivacy'
```

- [ ] **Step 3: Run Linux structural checks to green**

Run: `cd /tmp/opencode/LX2IOS-main/workers && npm run check:batch-d`

Expected: PASS with `Batch D structural checks passed.` and exactly three `PrivacyInfo.xcprivacy` mentions in the project file.

- [ ] **Step 4: Perform the required macOS bundle verification**

Run on macOS from the repository root:

```bash
flutter build ios --release --no-codesign
test -f build/ios/iphoneos/Runner.app/PrivacyInfo.xcprivacy
plutil -lint build/ios/iphoneos/Runner.app/PrivacyInfo.xcprivacy
xcodebuild -project ios/Runner.xcodeproj -target Runner -showBuildSettings >/dev/null
```

Expected: build succeeds, `PrivacyInfo.xcprivacy` exists at the app-bundle root, `plutil` reports `OK`, and Xcode parses the project/Runner target without duplicate-reference errors.

### Task 8: Full Batch D Regression Pass

**Files:**
- Verify: all files listed in the File Map
- Verify unchanged behavior: `workers/src/routes/playlist-import.ts`

**Interfaces:**
- Consumes: all Task 1-7 deliverables.
- Produces: one clean Batch D verification record; no production/test behavior outside approved Batch D is changed.

- [ ] **Step 1: Run all Worker tests and checks**

Run:

```bash
cd /tmp/opencode/LX2IOS-main/workers
npm test
npm run typecheck
npm run check:batch-d
npx wrangler deploy --dry-run --outdir /tmp/opencode/lx-worker-dry-run
```

Expected: all Vitest files pass, TypeScript reports no errors, structural checks print `Batch D structural checks passed.`, and Wrangler creates a dry-run bundle without config diagnostics.

- [ ] **Step 2: Run the focused Flutter test and analysis**

Run:

```bash
cd /tmp/opencode/LX2IOS-main
flutter test test/features/custom_source/domain/custom_source_engine_test.dart
flutter analyze lib/features/custom_source/domain/custom_source_engine.dart test/features/custom_source/domain/custom_source_engine_test.dart
```

Expected: focused tests pass and analysis reports no diagnostics introduced by the CSPRNG bridge.

- [ ] **Step 3: Reconfirm the two exclusions structurally and by diff inspection**

Run:

```bash
cd /tmp/opencode/LX2IOS-main
rg -n "Promise\.all|No hard cap on playlist size|body\.songs" workers/src/routes/playlist-import.ts
rg -n "MAX_(BODY|SONGS|PLAYLIST)|songs\.length\s*>|content-length" workers/src/routes/playlist-import.ts
```

Expected: the first command still shows parallel anonymous preview fan-out and the explicit no-cap Phase 2 behavior; the second command returns no matches. Confirm no Task 1-7 edit changed `rematchSongs`, `request.json()`, or the Phase 2 `body.songs` flow.

- [ ] **Step 4: Verify deployment order without deploying**

Inspect `.github/workflows/deploy-workers.yml` and confirm this order: `npm ci` -> tests/typecheck/structure -> replace binding IDs -> legacy-column preflight -> `wrangler d1 migrations apply --remote` -> dry run -> Worker deploy -> secrets -> health/login verification.

Expected: schema migration finishes before the new Worker can receive traffic; no request path executes DDL.

- [ ] **Step 5: Record platform-limited verification**

On Linux, report the macOS Task 7 Step 4 archive/bundle check as not run. Do not claim iOS archive verification until those exact commands pass on macOS.

---

## Self-Review Checklist

- [ ] Every Batch D item maps to a task: schema migration (Task 2), fail-closed auth limiting and bounded IP DO (Task 3), CSPRNG (Task 4), generic 500/request ID (Task 5), compatibility/observability (Task 6), and privacy manifest (Task 7).
- [ ] Anonymous preview fan-out and unbounded Phase 2 body/song behavior remain explicitly excluded and structurally guarded in Tasks 1 and 8.
- [ ] All production interfaces introduced in one task match later consumers exactly.
- [ ] Every automated change has a red command and a green command with expected output.
- [ ] No Git command or commit step appears in this plan.
- [ ] No major dependency upgrade is planned; only exact, Wrangler-compatible Worker test dependencies are added.
