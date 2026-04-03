import { marked, use } from 'marked';
import type { Tokens } from 'marked';

function escapeHtmlText(s: string): string {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

let configured = false;

/** WKWebView-safe markdown: no raw HTML; images → links (WebP etc.). */
export function ensureCcreaderMarkedConfigured(): void {
  if (configured) return;
  configured = true;
  try {
    use({
      renderer: {
        html(_token: Tokens.HTML | Tokens.Tag) {
          return escapeHtmlText(_token.text);
        },
        image(_token: Tokens.Image) {
          const url = String(_token.href || '').trim();
          const safeUrl = escapeHtmlText(url);
          const safeLabel = safeUrl || 'image';
          return `<a href="${safeUrl}" target="_blank" rel="noreferrer noopener">[image: ${safeLabel}]</a>`;
        },
      },
    });
  } catch {
    /* ignore */
  }
}

export { marked };
