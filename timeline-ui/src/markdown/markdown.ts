import hljs from 'highlight.js/lib/common';
import { decodeUtf8Base64 } from '../lib/decodeUtf8Base64';
import { ensureCcreaderMarkedConfigured, marked } from './ccreaderMarkedConfig';

export function renderMarkdownIn(root: ParentNode): void {
  ensureCcreaderMarkedConfigured();
  /* Only nodes not yet rendered — avoids scanning every markdown cell on each commit */
  root.querySelectorAll('[data-markdown-base64]:not([data-md-rendered])').forEach((node) => {
    if (!(node instanceof HTMLElement)) return;
    const source = node.getAttribute('data-markdown-base64') || '';
    if (!source) return;
    try {
      node.innerHTML = marked.parse(decodeUtf8Base64(source)) as string;
      node.dataset.mdRendered = '1';
    } catch (e) {
      console.error('markdown render failed', e);
    }
  });
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

export function enhanceSubtree(node: ParentNode): void {
  renderMarkdownIn(node);
  highlightCodeBlocksIn(node);
}
