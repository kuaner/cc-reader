import type { JSX } from 'preact';
import type { MessagePayload } from '../types';

type Role = 'user' | 'assistant' | 'dispatch';

const base =
  'inline-block rounded px-1.5 py-px text-[9px] font-bold tracking-wide leading-snug border';

function classesForTag(payload: MessagePayload, tag: string, role: Role): string {
  const token = String(tag || '').toLowerCase();
  if (!payload.isUser && token === 'tool_use') {
    return `${base} border-[color:var(--tag-tool-use-border)] bg-[color:var(--tag-tool-use-bg)] text-[color:var(--tag-tool-use-text)]`;
  }
  if (payload.isUser && token === 'tool_result') {
    return `${base} border-[color:var(--tag-tool-result-border)] bg-[color:var(--tag-tool-result-bg)] text-[color:var(--tag-tool-result-text)]`;
  }
  if (role === 'user') {
    return `${base} border-transparent bg-[color:var(--tag-user-bg)] text-[color:var(--tag-user-text)]`;
  }
  if (role === 'dispatch') {
    return `${base} border-[color:var(--tag-dispatch-border)] bg-[color:var(--tag-dispatch-bg)] text-[color:var(--tag-dispatch-text)]`;
  }
  return `${base} border-transparent bg-[color:var(--tag-assistant-bg)] text-[color:var(--tag-assistant-text)]`;
}

export function TypeTags({
  payload,
  fallbackLabel,
  role,
}: {
  payload: MessagePayload;
  fallbackLabel?: string;
  role: Role;
}): JSX.Element {
  const tags = Array.isArray(payload.metaTags) ? payload.metaTags : [];
  if (tags.length === 0) {
    return <span class={classesForTag(payload, '', role)}>{fallbackLabel || 'Assistant'}</span>;
  }
  return (
    <>
      {tags.map((tag) => (
        <span key={String(tag)} class={classesForTag(payload, String(tag), role)}>
          {tag}
        </span>
      ))}
    </>
  );
}

export function SummaryTag({ label }: { label: string }): JSX.Element {
  return (
    <span
      class={`${base} border-transparent bg-[color:var(--tag-summary-bg)] text-[color:var(--tag-summary-text)]`}
    >
      {label}
    </span>
  );
}

export function ErrorTag({ children }: { children: string }): JSX.Element {
  return (
    <span class={`${base} border-transparent bg-[color:var(--tag-error-bg)] text-[color:var(--tag-error-text)]`}>
      {children}
    </span>
  );
}
