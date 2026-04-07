import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  CC_DEFAULT_THEME,
  CC_THEME_IDS,
  CC_THEME_STORAGE_KEY,
  cycleCcTheme,
  getCcTheme,
  initCcTheme,
  isCcThemeId,
  setCcTheme,
} from './ccTheme';

describe('ccTheme', () => {
  const storage = new Map<string, string>();
  let themeAttr = '';

  beforeEach(() => {
    storage.clear();
    themeAttr = '';

    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (storage.has(k) ? storage.get(k)! : null),
      setItem: (k: string, v: string) => void storage.set(k, v),
      removeItem: (k: string) => void storage.delete(k),
    });

    const docEl = {
      get dataset(): { ccTheme?: string } {
        return {
          get ccTheme() {
            return themeAttr || undefined;
          },
          set ccTheme(v: string) {
            themeAttr = v;
          },
        };
      },
      removeAttribute(name: string) {
        if (name === 'data-cc-theme') themeAttr = '';
      },
      setAttribute(name: string, v: string) {
        if (name === 'data-cc-theme') themeAttr = v;
      },
    };

    vi.stubGlobal('document', { documentElement: docEl });
    vi.stubGlobal('window', {
      dispatchEvent: vi.fn(),
      addEventListener: vi.fn(),
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('isCcThemeId validates known ids', () => {
    expect(isCcThemeId('ledger')).toBe(true);
    expect(isCcThemeId('slate')).toBe(true);
    expect(isCcThemeId('tokyo-night')).toBe(true);
    expect(isCcThemeId('')).toBe(false);
    expect(isCcThemeId('ocean')).toBe(false);
  });

  it('setCcTheme / getCcTheme and persistence', () => {
    setCcTheme('slate');
    expect(getCcTheme()).toBe('slate');
    expect(themeAttr).toBe('slate');
    expect(storage.get(CC_THEME_STORAGE_KEY)).toBe('slate');
  });

  it('initCcTheme normalizes invalid dom attribute using storage', () => {
    themeAttr = 'bogus';
    storage.set(CC_THEME_STORAGE_KEY, 'slate');
    initCcTheme();
    expect(getCcTheme()).toBe('slate');
  });

  it('initCcTheme uses CC_DEFAULT_THEME when dom and storage are empty', () => {
    initCcTheme();
    expect(getCcTheme()).toBe(CC_DEFAULT_THEME);
  });

  it('cycleCcTheme walks CC_THEME_IDS', () => {
    const first = CC_THEME_IDS[0]!;
    const second = CC_THEME_IDS[1]!;
    setCcTheme(first);
    const next = cycleCcTheme();
    expect(next).toBe(second);
    expect(getCcTheme()).toBe(second);
    setCcTheme(CC_THEME_IDS[CC_THEME_IDS.length - 1]!);
    cycleCcTheme();
    expect(getCcTheme()).toBe(first);
  });
});
