import { beforeEach, describe, expect, it, vi } from 'vitest';

describe('ccreaderMarkedConfig', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  it('escapes raw HTML via renderer', async () => {
    const { ensureCcreaderMarkedConfigured, marked } = await import('./ccreaderMarkedConfig');
    ensureCcreaderMarkedConfigured();
    const out = marked.parse('<div>hello</div>') as string;
    expect(out).not.toContain('<div>');
    expect(out).toContain('&lt;');
  });

  it('renders images as safe links', async () => {
    const { ensureCcreaderMarkedConfigured, marked } = await import('./ccreaderMarkedConfig');
    ensureCcreaderMarkedConfigured();
    const out = marked.parse('![x](https://example.com/a.webp)') as string;
    expect(out).toContain('href="https://example.com/a.webp"');
    expect(out).toContain('rel="noreferrer noopener"');
    expect(out).toContain('[image:');
  });
});
