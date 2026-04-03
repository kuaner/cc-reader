/**
 * MarkdownRenderView bundle: `marked` + `hljs` globals, page CSS, code-block chrome.
 */
import '../markdownPreviewPage.css';
import '../markdownHljs.css';
import '../styles/web-chrome.css';
import hljs from 'highlight.js/lib/common';
import { decodeUtf8Base64 } from '../lib/decodeUtf8Base64';
import { ensureCcreaderMarkedConfigured, marked } from './ccreaderMarkedConfig';
import { enhanceCodeBlocks } from '../webChrome';

ensureCcreaderMarkedConfigured();

(window as unknown as { marked: typeof marked }).marked = marked;
(window as unknown as { hljs: typeof hljs }).hljs = hljs;

function applyPlainTextFallback(root: HTMLElement, source: string): void {
  let text = '';
  try {
    text = decodeUtf8Base64(source);
  } catch {
    text = '';
  }
  root.replaceChildren();
  const wrap = document.createElement('div');
  wrap.className = 'plain-text';
  wrap.textContent = text;
  root.appendChild(wrap);
}

function runMarkdownPreview(): void {
  const node = document.getElementById('content');
  if (!node) return;
  const source = node.getAttribute('data-markdown-base64') || '';
  if (!source) return;
  const w = window as unknown as { marked?: { parse: (s: string) => unknown }; hljs?: typeof hljs };
  if (!w.marked) {
    applyPlainTextFallback(node, source);
    return;
  }
  try {
    const markdown = decodeUtf8Base64(source);
    node.innerHTML = w.marked.parse(markdown) as string;
    if (w.hljs) {
      node.querySelectorAll('pre code').forEach((block) => {
        if (!(block instanceof HTMLElement)) return;
        try {
          w.hljs!.highlightElement(block);
        } catch (highlightError) {
          console.error('markdown highlight failed', highlightError);
        }
      });
    }
    enhanceCodeBlocks(node);
  } catch (error) {
    console.error('markdown render failed', error);
    applyPlainTextFallback(node, source);
  }
}

runMarkdownPreview();
