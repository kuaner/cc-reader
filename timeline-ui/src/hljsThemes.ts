import githubDark from 'highlight.js/styles/github-dark.css?raw';
import githubLight from 'highlight.js/styles/github.css?raw';

let injected = false;

/** GitHub / GitHub Dark to match former highlight-light/dark.css */
export function injectHljsThemes(): void {
  if (injected) return;
  injected = true;
  const el = document.createElement('style');
  el.setAttribute('data-ccreader', 'hljs-themes');
  el.textContent = `
@media (prefers-color-scheme: light) {
${githubLight}
}
@media (prefers-color-scheme: dark) {
${githubDark}
}
`;
  document.head.appendChild(el);
}
