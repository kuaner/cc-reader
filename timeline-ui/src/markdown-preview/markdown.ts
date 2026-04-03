import hljs from 'highlight.js/lib/common';
import { ensureCcreaderMarkedConfigured, marked } from './ccreaderMarkedConfig';

export function renderMarkdownToHtml(source: string): string {
  ensureCcreaderMarkedConfigured();
  return marked.parse(source) as string;
}

export function highlightCodeBlocksIn(root: ParentNode): void {
  root.querySelectorAll('pre code:not([data-hl-rendered])').forEach((block) => {
    if (!(block instanceof HTMLElement)) return;
    try {
      hljs.highlightElement(block);
      block.dataset.hlRendered = '1';
    } catch (e) {
      console.error('highlight failed', e);
    }
  });
}

