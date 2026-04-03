import type { JSX } from 'preact';
import type { MessagePayload } from '../types';

type Role = 'user' | 'assistant' | 'dispatch';

const base =
  'inline-block rounded px-[7px] py-px text-[9px] font-semibold leading-snug';

function classesForTag(
  payload: MessagePayload,
  tag: string,
  role: Role,
): string {
  const token = String(tag || '').toLowerCase();
  if (!payload.isUser && token === 'tool_use') {
    return `${base} border border-blue-400/40 bg-blue-500/25 text-blue-100`;
  }
  if (payload.isUser && token === 'tool_result') {
    return `${base} border border-green-400/40 bg-green-500/25 text-green-100`;
  }
  if (role === 'user') {
    return `${base} bg-white/20 text-white`;
  }
  if (role === 'dispatch') {
    return `${base} border border-teal-500/40 bg-teal-500/25 text-teal-800 dark:text-teal-100`;
  }
  return `${base} bg-violet-500/25 text-violet-950 dark:text-violet-100`;
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
    <span class={`${base} bg-orange-400/25 text-orange-600 dark:text-orange-300`}>{label}</span>
  );
}

export function ErrorTag({ children }: { children: string }): JSX.Element {
  return (
    <span class={`${base} bg-red-500/20 text-red-600 dark:text-red-400`}>{children}</span>
  );
}
