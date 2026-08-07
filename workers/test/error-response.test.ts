import { describe, expect, it, vi } from 'vitest';
import { internalServerError, readJsonBody } from '../src/lib/response';

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

describe('readJsonBody', () => {
  it('rejects a literal null body with 400 instead of destructuring it', async () => {
    const request = new Request('https://example.com/api/user/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: 'null',
    });

    const result = await readJsonBody(request);
    expect(result).toBeInstanceOf(Response);
    const response = result as Response;
    expect(response.status).toBe(400);
  });

  it('rejects a JSON array body with 400', async () => {
    const request = new Request('https://example.com/api/user/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '[]',
    });

    const result = await readJsonBody(request);
    expect(result).toBeInstanceOf(Response);
    expect((result as Response).status).toBe(400);
  });

  it('accepts a JSON object body', async () => {
    const request = new Request('https://example.com/api/user/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{"username":"alice","password":"secret"}',
    });

    const result = await readJsonBody(request);
    expect(result).not.toBeInstanceOf(Response);
    expect((result as { body: Record<string, unknown> }).body).toEqual({
      username: 'alice',
      password: 'secret',
    });
  });

  it('rejects JSON bodies larger than 256 KiB', async () => {
    const request = new Request('https://example.com/api/user/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ value: 'x'.repeat(256 * 1024) }),
    });

    const result = await readJsonBody(request);
    expect(result).toBeInstanceOf(Response);
    expect((result as Response).status).toBe(413);
  });
});
