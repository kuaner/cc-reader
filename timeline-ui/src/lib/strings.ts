import type { MessagePayload } from '../types';

export function escapeHTML(s: string): string {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function encodeBase64Utf8(s: string): string {
  return window.btoa(unescape(encodeURIComponent(String(s || ''))));
}

export function looksLikeMarkdown(text: string): boolean {
  const source = String(text || '');
  if (!source) return false;
  return /```|^\s{0,3}#{1,6}\s|^\s*[-*+]\s|^\s*\d+\.\s|\[[^\]]+\]\([^)]+\)|!\[[^\]]*\]\([^)]+\)|^\s*>\s|^\s*\|.+\|/m.test(
    source,
  );
}

/** Stable key so list rows reconcile when streamed content changes. */
export function messageRowKey(p: MessagePayload): string {
  const c = p.content ?? '';
  const t = p.thinking ?? '';
  return `${p.uuid}\u0000${c.length}\u0000${t.length}\u0000${c.slice(-64)}`;
}
