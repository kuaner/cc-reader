/**
 * Decode Base64 that was produced from UTF-8 text (same as legacy `decodeURIComponent(escape(atob(...)))`).
 * Uses `atob` in browsers; falls back for environments without it (e.g. some test runners).
 */
export function decodeUtf8Base64(source: string): string {
  const binary =
    typeof atob === 'function'
      ? atob(source)
      : Buffer.from(source, 'base64').toString('binary');
  return decodeURIComponent(escape(binary));
}
