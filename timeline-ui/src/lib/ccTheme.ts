/** localStorage key — keep in sync with inline script in `timeline-shell.html` / `markdown-preview.html`. */
export const CC_THEME_STORAGE_KEY = 'ccreader.themeId';

/** 与 `src/styles/themes/*.css` 同步；运行 `npm run sync-themes` 或 `npm run build` 重新生成。 */
import { CC_THEME_IDS } from './ccTheme.generated';

export { CC_THEME_IDS };
export type CcThemeId = (typeof CC_THEME_IDS)[number];

export const CC_DEFAULT_THEME: CcThemeId = 'everforest';

export function isCcThemeId(value: unknown): value is CcThemeId {
  return typeof value === 'string' && (CC_THEME_IDS as readonly string[]).includes(value);
}

export function getCcTheme(): CcThemeId {
  const fromDom = document.documentElement.dataset.ccTheme;
  if (isCcThemeId(fromDom)) return fromDom;
  return CC_DEFAULT_THEME;
}

function persistTheme(id: CcThemeId): void {
  try {
    localStorage.setItem(CC_THEME_STORAGE_KEY, id);
  } catch {
    /* private mode / quota */
  }
}

export function setCcTheme(id: CcThemeId): void {
  document.documentElement.dataset.ccTheme = id;
  persistTheme(id);
  window.dispatchEvent(new CustomEvent<CcThemeId>('ccreader:themechange', { detail: id }));
}

/**
 * 与 HTML 内联脚本对齐：校验 `data-cc-theme`、写回 storage、监听跨页签同步。
 */
export function initCcTheme(): void {
  const raw = document.documentElement.dataset.ccTheme;
  const fromStorage = (() => {
    try {
      return localStorage.getItem(CC_THEME_STORAGE_KEY);
    } catch {
      return null;
    }
  })();

  let next: CcThemeId = CC_DEFAULT_THEME;
  if (isCcThemeId(raw)) {
    next = raw;
  } else if (isCcThemeId(fromStorage)) {
    next = fromStorage;
  }

  document.documentElement.dataset.ccTheme = next;
  persistTheme(next);

  window.addEventListener('storage', (e) => {
    if (e.key !== CC_THEME_STORAGE_KEY || e.newValue == null) return;
    if (isCcThemeId(e.newValue)) {
      document.documentElement.dataset.ccTheme = e.newValue;
    }
  });
}

export function listCcThemes(): readonly CcThemeId[] {
  return CC_THEME_IDS;
}

export function cycleCcTheme(): CcThemeId {
  const i = CC_THEME_IDS.indexOf(getCcTheme());
  const next = CC_THEME_IDS[(i + 1) % CC_THEME_IDS.length] ?? CC_DEFAULT_THEME;
  setCcTheme(next);
  return next;
}
