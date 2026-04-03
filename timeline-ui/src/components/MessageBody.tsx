import type { JSX } from 'preact';
import { encodeBase64Utf8, escapeHTML } from '../lib/strings';

export type MarkdownTone = 'assistant' | 'user' | 'summary';

export interface MessageBodyOptions {
  preserveLineBreaks?: boolean;
  renderMarkdown?: boolean;
  /** Prose / code colors for rendered markdown */
  markdownTone?: MarkdownTone;
}

/** Chat-style reading: comfortable size, line length, link affordance (Tailwind Typography). */
function proseForTone(tone: MarkdownTone): string {
  const readability = [
    'max-w-[min(100%,65ch)]',
    'leading-[1.45]',
    'break-words',
    '[&_p]:my-[0.45em] [&_p:first-child]:mt-0 [&_p:last-child]:mb-0',
    '[&_li]:my-0.5',
    '[&_a]:font-medium [&_a]:underline [&_a]:underline-offset-[3px] [&_a]:transition-colors',
  ].join(' ');

  if (tone === 'user') {
    return [
      'markdown',
      'prose',
      'prose-sm',
      'markdown-prose-user',
      'text-[color:var(--surface-user-text)]',
      readability,
      '[&_a]:decoration-[color:color-mix(in_srgb,var(--bubble-user-link)_40%,transparent)]',
      '[&_a:hover]:decoration-[color:color-mix(in_srgb,var(--bubble-user-link)_75%,transparent)]',
      /* Code blocks: ember-tray hljs (hljs-user-bubble.css); pre shell transparent */
      '[&_pre]:bg-transparent [&_pre]:rounded-xl [&_pre]:overflow-hidden',
      '[&_pre_code]:bg-transparent',
      '[&_:not(pre)>code]:rounded-md [&_:not(pre)>code]:bg-[color:var(--bubble-user-inline-code-bg)] [&_:not(pre)>code]:text-[color:var(--bubble-user-inline-code-fg)] [&_:not(pre)>code]:px-1 [&_:not(pre)>code]:py-px',
      '[&_blockquote]:border-[color:var(--bubble-user-blockquote-border)]',
    ].join(' ');
  }
  return [
    'markdown',
    'prose',
    'prose-sm',
    'markdown-prose-assistant',
    'text-[color:var(--text)]',
    readability,
    '[&_a]:decoration-[color:color-mix(in_srgb,var(--accent-link)_35%,transparent)]',
    '[&_a:hover]:decoration-[color:color-mix(in_srgb,var(--accent-link)_65%,transparent)]',
    '[&_blockquote]:text-[color:var(--muted)] [&_blockquote]:border-[color:var(--border)]',
    '[&_th]:border-[color:var(--border)]',
    '[&_td]:border-[color:var(--border)]',
    '[&_strong]:text-[color:var(--text)] [&_strong]:font-semibold',
    '[&_:not(pre)>code]:rounded-md [&_:not(pre)>code]:bg-[color:var(--assistant-inline-code-bg)] [&_:not(pre)>code]:text-[color:var(--assistant-inline-code-fg)] [&_:not(pre)>code]:px-1 [&_:not(pre)>code]:py-px',
  ].join(' ');
}

export function MessageBody({
  content,
  options,
}: {
  content: string;
  options?: MessageBodyOptions;
}): JSX.Element {
  const preserveLineBreaks = options?.preserveLineBreaks === true;
  const renderMarkdown = options?.renderMarkdown !== false;
  const tone = options?.markdownTone ?? 'assistant';
  const source = String(content || '');

  if (!source) {
    return (
      <div
        class={['whitespace-pre-wrap break-words', tone === 'user' ? 'text-[color:var(--surface-user-text)]' : '']
          .filter(Boolean)
          .join(' ')}
      />
    );
  }

  if (preserveLineBreaks || !renderMarkdown) {
    const userPlain = tone === 'user' ? 'text-[color:var(--surface-user-text)]' : '';
    return (
      <div
        class={
          preserveLineBreaks
            ? `max-w-[min(100%,65ch)] whitespace-pre-wrap break-words font-mono text-[12px] leading-[1.6] ${userPlain}`
            : `max-w-[min(100%,65ch)] whitespace-pre-wrap break-words text-[13px] leading-[1.45] ${userPlain}`
        }
      >
        {source}
      </div>
    );
  }

  const fallback = escapeHTML(source).replace(/\n/g, '<br>');
  const encoded = encodeBase64Utf8(source);
  return (
    <div class={proseForTone(tone)} data-markdown-base64={encoded}>
      <div class="whitespace-pre-wrap break-words" dangerouslySetInnerHTML={{ __html: fallback }} />
    </div>
  );
}
