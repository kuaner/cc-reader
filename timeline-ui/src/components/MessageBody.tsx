import type { JSX } from 'preact';
import { encodeBase64Utf8, escapeHTML } from '../lib/strings';

export type MarkdownTone = 'assistant' | 'user' | 'summary';

export interface MessageBodyOptions {
  preserveLineBreaks?: boolean;
  renderMarkdown?: boolean;
  /** Prose / code colors for rendered markdown */
  markdownTone?: MarkdownTone;
}

function proseForTone(tone: MarkdownTone): string {
  if (tone === 'user') {
    return [
      'markdown',
      'prose',
      'prose-sm',
      'prose-invert',
      'max-w-none',
      'break-words',
      '[&_pre]:bg-white/15',
      '[&_pre_code]:bg-transparent',
      '[&_:not(pre)>code]:bg-white/15',
      '[&_blockquote]:text-white/80',
    ].join(' ');
  }
  return [
    'markdown',
    'prose',
    'prose-sm',
    'max-w-none',
    'break-words',
    'text-neutral-900',
    'dark:prose-invert',
    'dark:text-neutral-100',
    '[&_blockquote]:text-[color:var(--muted)]',
    '[&_th]:border-[color:var(--border)]',
    '[&_td]:border-[color:var(--border)]',
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
    return <div class="whitespace-pre-wrap break-words" />;
  }

  if (preserveLineBreaks || !renderMarkdown) {
    return (
      <div
        class={
          preserveLineBreaks
            ? 'whitespace-pre-wrap break-words font-mono text-xs'
            : 'whitespace-pre-wrap break-words'
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
