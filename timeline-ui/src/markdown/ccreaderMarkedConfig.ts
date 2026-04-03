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

function prettifyCodeLanguage(rawLanguage: string): string {
  const normalized = (rawLanguage || '').toLowerCase();
  if (!normalized) return 'Code';

  const aliases: Record<string, string> = {
    js: 'JavaScript',
    jsx: 'JSX',
    ts: 'TypeScript',
    tsx: 'TSX',
    py: 'Python',
    sh: 'Shell',
    shell: 'Shell',
    zsh: 'Zsh',
    bash: 'Bash',
    swift: 'Swift',
    objc: 'Objective-C',
    json: 'JSON',
    yml: 'YAML',
    yaml: 'YAML',
    md: 'Markdown',
    html: 'HTML',
    xml: 'XML',
    css: 'CSS',
    scss: 'SCSS',
    sql: 'SQL',
    text: 'Text',
    plaintext: 'Text',
    txt: 'Text',
  };

  if (aliases[normalized]) return aliases[normalized];

  return normalized
    .split(/[-_]/g)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function fenceLangClass(lang: string): string {
  const raw = String(lang || 'plaintext').trim().split(/\s/)[0] || 'plaintext';
  const safe = raw.replace(/[^\w.+-]+/g, '-');
  return `language-${safe}`;
}

let configured = false;

/** WKWebView-safe markdown: no raw HTML; images → links; fenced code → code-block（仅语言条，无复制）. */
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
        code({ text, lang, escaped }: Tokens.Code) {
          const codeInner = escaped ? text : escapeHtmlText(text);
          const langKey = String(lang || 'plaintext').trim().split(/\s/)[0] || 'plaintext';
          const langClass = fenceLangClass(langKey);
          const label = prettifyCodeLanguage(langKey);
          return (
            `<div class="code-block">` +
            `<div class="code-block-header">` +
            `<span class="code-block-language">${escapeHtmlText(label)}</span>` +
            `</div>` +
            `<div class="code-block-body"><pre><code class="${escapeHtmlText(langClass)}">${codeInner}</code></pre></div>` +
            `</div>\n`
          );
        },
      },
    });
  } catch {
    /* ignore */
  }
}

export { marked };
