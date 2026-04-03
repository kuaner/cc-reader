import { registerCcreaderApi } from './ccreaderApi';
import { installNativeHooks } from './nativeHooks';

export function installCcreader(): void {
  const ccreader = (window.ccreader = window.ccreader || {}) as Window['ccreader'];
  registerCcreaderApi(ccreader);
  installNativeHooks();
}
