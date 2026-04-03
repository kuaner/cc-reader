/** Clipboard + code-block chrome + message copy (ported from WebRenderChrome.swift). */

export type CcreaderI18n = {
  copy: string;
  copied: string;
};

function getI18n(): CcreaderI18n {
  const w = window.__CCREADER_I18N__;
  return {
    copy: w?.copy ?? 'Copy',
    copied: w?.copied ?? 'Copied',
  };
}

function detectCodeLanguage(block: Element): string {
  if (!block) return '';
  const classNames = Array.from(block.classList || []);
  for (const className of classNames) {
    if (className.startsWith('language-')) return className.slice(9);
    if (className.startsWith('lang-')) return className.slice(5);
  }
  return block.getAttribute('data-language') || '';
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

function fallbackCopyText(text: string): Promise<void> {
  return new Promise((resolve, reject) => {
    try {
      const textArea = document.createElement('textarea');
      textArea.value = text;
      textArea.setAttribute('readonly', 'readonly');
      textArea.style.position = 'fixed';
      textArea.style.opacity = '0';
      textArea.style.pointerEvents = 'none';
      document.body.appendChild(textArea);
      textArea.focus();
      textArea.select();
      const successful = document.execCommand('copy');
      document.body.removeChild(textArea);
      if (successful) {
        resolve();
        return;
      }
      reject(new Error('execCommand copy failed'));
    } catch (error) {
      reject(error);
    }
  });
}

export function copyCodeText(text: string): Promise<void> {
  if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    return navigator.clipboard.writeText(text).catch(() => fallbackCopyText(text));
  }
  return fallbackCopyText(text);
}

export function enhanceCodeBlocks(root: ParentNode): void {
  if (!root || typeof (root as HTMLElement).querySelectorAll !== 'function') return;
  const { copy, copied } = getI18n();

  root.querySelectorAll('pre code').forEach((block) => {
    if (!(block instanceof HTMLElement)) return;
    const pre = block.parentElement;
    if (!pre || (pre.parentElement && pre.parentElement.classList.contains('code-block-body'))) {
      return;
    }

    const wrapper = document.createElement('div');
    wrapper.className = 'code-block';

    const header = document.createElement('div');
    header.className = 'code-block-header';

    const language = document.createElement('span');
    language.className = 'code-block-language';
    language.textContent = prettifyCodeLanguage(detectCodeLanguage(block));

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'code-copy-button';
    button.textContent = copy;
    button.addEventListener('click', () => {
      const codeText = block.innerText || block.textContent || '';
      copyCodeText(codeText)
        .then(() => {
          button.textContent = copied;
          button.classList.add('is-copied');
          window.setTimeout(() => {
            button.textContent = copy;
            button.classList.remove('is-copied');
          }, 1600);
        })
        .catch((error) => {
          console.error('copy code failed', error);
        });
    });

    header.appendChild(language);
    header.appendChild(button);

    const body = document.createElement('div');
    body.className = 'code-block-body';

    pre.parentNode!.insertBefore(wrapper, pre);
    body.appendChild(pre);
    wrapper.appendChild(header);
    wrapper.appendChild(body);
  });
}

function prettifyMessageCopyText(rawText: string): string {
  const text = String(rawText || '');
  const trimmed = text.trim();
  if (!trimmed) return text;
  if (!/^(\[|\{)/.test(trimmed)) return text;
  try {
    const parsed = JSON.parse(trimmed);
    return JSON.stringify(parsed, null, 2);
  } catch {
    return text;
  }
}

export function enhanceMessageCopyButtons(root: ParentNode): void {
  if (!root || typeof (root as HTMLElement).querySelectorAll !== 'function') return;
  const { copied } = getI18n();

  root.querySelectorAll('[data-message-copy-base64]').forEach((button) => {
    if (!(button instanceof HTMLElement)) return;
    if (button.dataset.copyBound === '1') return;
    button.dataset.copyBound = '1';

    button.addEventListener('click', () => {
      const source = button.getAttribute('data-message-copy-base64') || '';
      if (!source) return;

      let text = '';
      try {
        text = decodeURIComponent(escape(window.atob(source)));
      } catch (decodeError) {
        console.error('decode message copy failed', decodeError);
        return;
      }

      const textToCopy = prettifyMessageCopyText(text);
      copyCodeText(textToCopy)
        .then(() => {
          const resetLabel = button.getAttribute('data-copy-label') || '';
          button.textContent = copied;
          button.classList.add('is-copied');
          window.setTimeout(() => {
            if (resetLabel) button.textContent = resetLabel;
            button.classList.remove('is-copied');
          }, 1600);
        })
        .catch((error) => {
          console.error('copy message failed', error);
        });
    });
  });
}

