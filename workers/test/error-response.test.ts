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
