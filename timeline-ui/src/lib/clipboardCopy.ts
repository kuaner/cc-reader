/** Clipboard helpers + i18n labels for copy actions (timeline + preview). */

export type CcreaderI18n = {
  copy: string;
  copied: string;
};

export function getCcreaderI18n(): CcreaderI18n {
  const w = typeof window !== 'undefined' ? window.__CCREADER_I18N__ : undefined;
  return {
    copy: w?.copy ?? 'Copy',
    copied: w?.copied ?? 'Copied',
  };
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

/** Pretty-print JSON-looking payloads when copying message raw data. */
export function prettifyMessageCopyText(rawText: string): string {
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
