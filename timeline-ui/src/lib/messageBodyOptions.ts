export type MarkdownTone = 'assistant' | 'user' | 'summary';

export interface MessageBodyOptions {
  preserveLineBreaks?: boolean;
  renderMarkdown?: boolean;
  /** Prose / code colors for rendered markdown */
  markdownTone?: MarkdownTone;
}
