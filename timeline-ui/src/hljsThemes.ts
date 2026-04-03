import githubDarkRaw from 'highlight.js/styles/github-dark.css?raw';
import githubLightRaw from 'highlight.js/styles/github.css?raw';
import hljsUserBubbleCss from './styles/hljs-user-bubble.css?raw';

/** Same files as `markdownHljs.css` (preview bundle uses build-time @import). */
export const githubHljsThemeLightCss = githubLightRaw;
export const githubHljsThemeDarkCss = githubDarkRaw;

let injected = false;

/**
 * GitHub light/dark for assistant + default; warm ember hljs scoped to `.bubble.user`
 * so code stays readable on the amber user bubble (GitHub palette is for light gray bg).
 */
export function injectHljsThemes(): void {
  if (injected) return;
  injected = true;
  const el = document.createElement('style');
  el.setAttribute('data-ccreader', 'hljs-themes');
  el.textContent = `
@media (prefers-color-scheme: light) {
${githubHljsThemeLightCss}
}
@media (prefers-color-scheme: dark) {
${githubHljsThemeDarkCss}
}
${hljsUserBubbleCss}
`;
  document.head.appendChild(el);
}
