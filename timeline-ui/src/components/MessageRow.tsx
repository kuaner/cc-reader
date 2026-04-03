import type { ComponentChildren, JSX } from 'preact';
import { memo } from 'preact/compat';
import { looksLikeMarkdown } from '../lib/strings';
import type { MessagePayload, ToolPayload } from '../types';
import { MessageBody, type MessageBodyOptions } from './MessageBody';
import { RawDataButton } from './RawDataButton';
import { ToolResultImages } from './ToolResultImages';
import { ErrorTag, SummaryTag, TypeTags } from './TypeTags';

function fmtTok(n: number): string {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
}

const footerBase =
  'bubble-footer mt-2 flex min-h-7 flex-wrap items-center gap-x-2 gap-y-1.5 border-t pt-2 text-[11px] font-medium';

function BubbleFooter({
  timestamp,
  children,
  copyPayload,
  userStyle,
}: {
  timestamp: string;
  children: ComponentChildren;
  copyPayload: MessagePayload;
  userStyle?: boolean;
}): JSX.Element {
  const borderMuted = userStyle
    ? 'border-[color:var(--bubble-user-footer-border)] text-[color:var(--bubble-user-footer-muted)]'
    : 'border-[color:var(--border)] text-[color:var(--muted)]';
  return (
    <div class={`${footerBase} ${borderMuted}`}>
      <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-1.5 gap-y-1">
        <span class="shrink-0">{timestamp}</span>
        {children}
      </div>
      <RawDataButton payload={copyPayload} class="shrink-0 ml-auto" />
    </div>
  );
}

function renderToolSection(
  tools: ToolPayload[],
  useFlatToolBody: boolean,
  contextLabel: string,
): JSX.Element | null {
  if (tools.length === 0) return null;
  const toolBody = (
    <>
      {tools.map((tool, i) => {
        const renderStyle = String(tool.renderStyle || '');
        let body: JSX.Element | null = null;
        if (tool.body) {
          if (renderStyle === 'markdown') {
            body = <MessageBody content={tool.body} options={{ markdownTone: 'assistant' }} />;
          } else {
            body = (
              <pre class="my-2.5 whitespace-pre-wrap break-words rounded-xl bg-[color:var(--code-bg)] p-3 font-mono text-xs leading-normal">
                {tool.body}
              </pre>
            );
          }
        }
        return (
          <div key={i}>
            <div class="mb-1 text-[9px] font-bold uppercase tracking-[0.12em] text-[color:var(--muted)]">
              {tool.title || ''}
            </div>
            {body}
          </div>
        );
      })}
    </>
  );
  if (useFlatToolBody) {
    return <div class="rounded-xl p-0">{toolBody}</div>;
  }
  return (
    <div class="rounded-xl bg-[color:var(--surface-tool)] px-2.5 py-2">
      <div class="mb-1 text-[9px] font-bold uppercase tracking-[0.12em] text-[color:var(--muted)]">{contextLabel}</div>
      {toolBody}
    </div>
  );
}

function MessageRowImpl({ payload }: { payload: MessagePayload }): JSX.Element {
  const domId = payload.domId || '';
  const timestamp = payload.timeLabel || '';

  if (payload.isCompactSummary) {
    return (
      <div class="row flex w-full justify-start" id={domId}>
        <div class="stack flex w-full max-w-timeline flex-col gap-2.5">
          <div class="bubble rounded-2xl border border-[color:var(--border-summary)] bg-[color:var(--surface-summary)] px-4 py-3">
            <div class="flex gap-2.5 align-top">
              <div class="mt-0.5 shrink-0 text-base opacity-60">&#x21BB;</div>
              <div class="min-w-0 flex-1">
                <div class="mb-0.5 text-[10px] font-bold uppercase tracking-[0.12em] text-[color:var(--accent-summary-fg)]">
                  {payload.summaryLabel || 'Conversation summarized'}
                </div>
                <MessageBody content={payload.content || ''} options={{ markdownTone: 'summary' }} />
              </div>
            </div>
            <BubbleFooter timestamp={timestamp} copyPayload={payload}>
              <SummaryTag label={payload.legendSummary || 'Summary'} />
            </BubbleFooter>
          </div>
        </div>
      </div>
    );
  }

  if (payload.isApiError) {
    return (
      <div class="row flex w-full justify-start" id={domId}>
        <div class="stack flex w-full max-w-timeline flex-col gap-2.5">
          <div class="bubble rounded-2xl border border-[color:var(--accent-error-border)] bg-[color:var(--accent-error-bg)] px-4 py-3">
            <BubbleFooter timestamp={timestamp} copyPayload={payload}>
              <ErrorTag>{payload.legendLabel || 'API Error'}</ErrorTag>
              {payload.specialTag ? <ErrorTag>{payload.specialTag}</ErrorTag> : null}
            </BubbleFooter>
          </div>
        </div>
      </div>
    );
  }

  if (payload.isUser) {
    const userTags = Array.isArray(payload.metaTags) ? payload.metaTags : [];
    const hasToolResultTag = userTags.some((tag) => String(tag || '').toLowerCase() === 'tool_result');
    const toolResultShouldRenderMarkdown =
      hasToolResultTag && looksLikeMarkdown(payload.content || '');
    const bodyOpts: MessageBodyOptions | undefined = hasToolResultTag
      ? {
          preserveLineBreaks: !toolResultShouldRenderMarkdown,
          renderMarkdown: toolResultShouldRenderMarkdown,
          markdownTone: 'user',
        }
      : { markdownTone: 'user' };

    if (payload.isSummary) {
      return (
        <div class="row user flex w-full justify-end" id={domId}>
          <div class="stack flex w-full max-w-timeline flex-col items-end gap-2.5">
            <div class="bubble summary w-fit max-w-[min(100%,52rem)] rounded-2xl border border-[color:var(--border-summary)] bg-[color:var(--surface-summary)] px-4 py-3">
              <div class="summary-title mb-1 text-[10px] font-bold uppercase tracking-[0.12em] text-[color:var(--accent-summary-fg)]">
                {payload.summaryLabel || 'Summary'}
              </div>
              <MessageBody content={payload.content || ''} options={{ ...bodyOpts, markdownTone: 'summary' }} />
              <ToolResultImages payload={payload} />
              <BubbleFooter userStyle={false} timestamp={timestamp} copyPayload={payload}>
                <SummaryTag label={payload.legendSummary || 'Summary'} />
              </BubbleFooter>
            </div>
          </div>
        </div>
      );
    }

    return (
      <div class="row user flex w-full justify-end" id={domId}>
        <div class="stack flex w-full max-w-timeline flex-col items-end gap-2.5">
          <div class="bubble user relative w-fit max-w-[min(100%,52rem)] break-words rounded-2xl rounded-br-lg border border-[color:var(--bubble-user-rim)] border-l-[4px] border-l-[color:var(--bubble-user-accent)] bg-[color:var(--surface-user)] px-4 py-3 text-[color:var(--surface-user-text)] shadow-[0_2px_6px_rgba(0,0,0,0.07)]">
            <MessageBody content={payload.content || ''} options={bodyOpts} />
            <ToolResultImages payload={payload} />
            <BubbleFooter userStyle timestamp={timestamp} copyPayload={payload}>
              <TypeTags payload={payload} fallbackLabel={payload.legendUser || 'User'} role="user" />
              {payload.specialTag ? (
                <a
                  class="pill agent-id inline-block cursor-pointer rounded-full bg-[color:var(--button)] px-2.5 py-1 text-xs no-underline"
                  data-cc-session-id={payload.specialTag}
                >
                  {payload.specialTag}
                </a>
              ) : null}
            </BubbleFooter>
          </div>
        </div>
      </div>
    );
  }

  const isAgentDispatch = payload.bubbleKind === 'agent_dispatch';
  const isToolOnly = payload.renderMode === 'tool_only';
  const useFlatToolBody = isAgentDispatch || isToolOnly;
  const tools = Array.isArray(payload.tools) ? payload.tools : [];
  const tagRole = isAgentDispatch ? 'dispatch' : 'assistant';

  let usageEl: JSX.Element | null = null;
  const inT = payload.inputTokens ?? 0;
  const outT = payload.outputTokens ?? 0;
  if (inT > 0 || outT > 0) {
    let inPart = `${fmtTok(inT)} in`;
    const cacheR = payload.cacheReadTokens ?? 0;
    if (cacheR > 0) {
      inPart += ` (${fmtTok(cacheR)} cached)`;
    }
    usageEl = (
      <span class="inline-block min-w-0 max-w-full break-words rounded px-1.5 py-px text-[9px] font-bold leading-snug tracking-wide bg-[color:var(--usage-token-bg)] text-[color:var(--usage-token-text)]">
        {inPart} / {fmtTok(outT)} out
      </span>
    );
  }

  const cardTone = isAgentDispatch
    ? 'border border-[color:var(--bubble-dispatch-border)] bg-[color:var(--bubble-dispatch-bg)] shadow-[inset_0_0_0_1px_var(--bubble-dispatch-inset)]'
    : 'border border-[color:var(--bubble-assistant-border)] bg-[color:var(--surface-assistant)]';

  return (
    <div class="row assistant flex w-full justify-start" id={domId}>
      <div class="stack flex w-full max-w-timeline flex-col gap-2.5">
        <div
          class={`bubble assistant-card ${isAgentDispatch ? 'tone-dispatch' : 'tone-assistant'} flex max-w-[min(100%,52rem)] flex-col gap-2.5 break-words rounded-2xl px-4 py-3 ${cardTone}`}
        >
          <div
            class={`assistant-header border-b px-0.5 pb-2 ${
              isAgentDispatch
                ? 'border-dashed border-[color:var(--bubble-dispatch-header-border)]'
                : 'border-[color:var(--border)]'
            }`}
          >
            <span class="inline-flex h-6 shrink-0 items-center text-[10px] font-bold uppercase leading-none tracking-[0.16em] text-[color:var(--muted)]">
              {payload.assistantLabel || 'Assistant'}
            </span>
            {!isAgentDispatch && payload.specialTag ? (
              <span class="pill special">{payload.specialTag}</span>
            ) : null}
            {payload.modelTitle ? (
              <span class="pill shrink-0 rounded-full bg-[color:var(--button)] text-[color:var(--text)]">
                {payload.modelTitle}
              </span>
            ) : null}
          </div>
          {payload.thinking ? (
            <div class="rounded-lg bg-[color:var(--surface-thinking)] px-2.5 py-2">
              <div class="mb-1.5 text-[10px] font-bold uppercase tracking-[0.14em] text-[color:var(--muted)]">
                {payload.thinkingTitle || 'Thinking'}
              </div>
              <MessageBody content={payload.thinking} options={{ markdownTone: 'assistant' }} />
            </div>
          ) : null}
          {renderToolSection(tools, useFlatToolBody, payload.contextLabel || 'Context')}
          {payload.content ? (
            <div class="rounded-lg px-0.5 py-1">
              <MessageBody content={payload.content} options={{ markdownTone: 'assistant' }} />
            </div>
          ) : null}
          <BubbleFooter timestamp={timestamp} copyPayload={payload}>
            <TypeTags
              payload={payload}
              fallbackLabel={payload.legendLabel || payload.legendAssistant || 'Assistant'}
              role={tagRole}
            />
            {usageEl}
          </BubbleFooter>
        </div>
      </div>
    </div>
  );
}

export const MessageRow = memo(
  MessageRowImpl,
  (prev: { payload: MessagePayload }, next: { payload: MessagePayload }) => prev.payload === next.payload,
);
