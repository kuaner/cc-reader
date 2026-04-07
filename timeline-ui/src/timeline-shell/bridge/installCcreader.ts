import { registerCcreaderApi } from './ccreaderApi';
import { installNativeHooks } from './nativeHooks';
import { registerThemeApi } from './themeApi';

export function installCcreader(): void {
  const ccreader = (window.ccreader = window.ccreader || {}) as Window['ccreader'];
  registerCcreaderApi(ccreader);
  registerThemeApi(ccreader);
  installNativeHooks();
}
