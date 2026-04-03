import hljs from 'highlight.js/lib/common';
import { ensureCcreaderMarkedConfigured, marked } from './ccreaderMarkedConfig';
import { enhanceCodeBlocks, enhanceMessageCopyButtons } from './webChrome';

function decodeMarkdownBase64(source: string): string {
  return decodeURIComponent(escape(window.atob(source)));
}

export function renderMarkdownIn(root: ParentNode): void {
  ensureCcreaderMarkedConfigured();
  root.querySelectorAll('[data-markdown-base64]').forEach((node) => {
    if (!(node instanceof HTMLElement)) return;
    if (node.dataset.mdRendered === '1') return;
    const source = node.getAttribute('data-markdown-base64') || '';
    if (!source) return;
    try {
      node.innerHTML = marked.parse(decodeMarkdownBase64(source)) as string;
      node.dataset.mdRendered = '1';
    } catch (e) {
      console.error('markdown render failed', e);
    }
  });
}

export function highlightCodeBlocksIn(root: ParentNode): void {
  root.querySelectorAll('pre code').forEach((block) => {
    if (!(block instanceof HTMLElement)) return;
    if (block.dataset.hlRendered === '1') return;
    try {
      hljs.highlightElement(block);
      block.dataset.hlRendered = '1';
    } catch (e) {
      console.error('highlight failed', e);
    }
  });
}

export function enhanceSubtree(node: ParentNode): void {
  renderMarkdownIn(node);
  highlightCodeBlocksIn(node);
  enhanceCodeBlocks(node);
  enhanceMessageCopyButtons(node);
}
