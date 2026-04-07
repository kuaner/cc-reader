import { describe, expect, it } from 'vitest';
import { decodeUtf8Base64 } from './decodeUtf8Base64';

describe('decodeUtf8Base64', () => {
  it('decodes UTF-8 text from base64', () => {
    const b64 = Buffer.from('Hello 世界', 'utf8').toString('base64');
    expect(decodeUtf8Base64(b64)).toBe('Hello 世界');
  });

  it('throws on invalid base64', () => {
    expect(() => decodeUtf8Base64('@@@')).toThrow();
  });
});
