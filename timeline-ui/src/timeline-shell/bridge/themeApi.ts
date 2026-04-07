import {
  cycleCcTheme,
  getCcTheme,
  isCcThemeId,
  listCcThemes,
  setCcTheme,
  type CcThemeId,
} from '../../lib/ccTheme';

export function registerThemeApi(ccreader: Window['ccreader']): void {
  ccreader.getTheme = function (): CcThemeId {
    return getCcTheme();
  };

  ccreader.setTheme = function (id: string): void {
    if (!isCcThemeId(id)) {
      console.warn(`ccreader.setTheme: unknown theme "${id}", expected one of: ${listCcThemes().join(', ')}`);
      return;
    }
    setCcTheme(id);
  };

  ccreader.cycleTheme = function (): CcThemeId {
    return cycleCcTheme();
  };

  ccreader.listThemes = function (): readonly CcThemeId[] {
    return listCcThemes();
  };
}
