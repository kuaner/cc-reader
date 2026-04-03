/**
 * MarkdownRenderView bundle: `marked` + hljs + page CSS (code-block 无复制按钮).
 */
import '../styles/markdown-preview.css';
import { decodeUtf8Base64 } from '../lib/decodeUtf8Base64';
import { highlightCodeBlocksIn, renderMarkdownToHtml } from './markdown';

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
  try {
    const markdown = decodeUtf8Base64(source);
    node.innerHTML = renderMarkdownToHtml(markdown);
    highlightCodeBlocksIn(node);
  } catch (error) {
    console.error('markdown render failed', error);
    applyPlainTextFallback(node, source);
  }
}

runMarkdownPreview();

