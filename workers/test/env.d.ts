import type { Env } from '../src/lib/response';

declare module 'cloudflare:test' {
  interface ProvidedEnv extends Env {}
}
