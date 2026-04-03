import type { ComponentChildren, JSX } from 'preact';
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
  'bubble-footer mt-2 flex min-h-7 flex-wrap items-center gap-2 border-t pt-2 text-[11px] max-[560px]:min-h-0 max-[560px]:items-start max-[560px]:gap-1.5';

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
    ? 'border-white/20 text-white/70'
    : 'border-[color:var(--border)] text-[color:var(--muted)]';
  return (
    <div class={`${footerBase} ${borderMuted}`}>
      <span>{timestamp}</span>
      {children}
      <span class="flex-1 max-[560px]:order-2 max-[560px]:h-0 max-[560px]:basis-full" />
      <RawDataButton
        payload={copyPayload}
        class="max-[560px]:order-3 max-[560px]:ml-auto max-[560px]:max-w-full"
      />
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
              <pre class="my-2.5 whitespace-pre-wrap break-words rounded-[10px] bg-[color:var(--code-bg)] p-3 font-mono text-xs leading-normal">
                {tool.body}
              </pre>
            );
          }
        }
        return (
          <div key={i}>
            <div class="mb-1.5 text-xs font-semibold text-[color:var(--muted)]">{tool.title || ''}</div>
            {body}
          </div>
        );
      })}
    </>
  );
  if (useFlatToolBody) {
    return <div class="rounded-[10px] p-0">{toolBody}</div>;
  }
  return (
    <div class="rounded-[10px] bg-[color:var(--surface-tool)] px-2.5 py-2">
      <div class="mb-1.5 text-xs font-semibold text-[color:var(--muted)]">{contextLabel}</div>
      {toolBody}
    </div>
  );
}

export function MessageRow({ payload }: { payload: MessagePayload }): JSX.Element {
  const domId = payload.domId || '';
  const timestamp = payload.timeLabel || '';

  if (payload.isCompactSummary) {
    return (
      <div class="row flex w-full justify-start" id={domId}>
        <div class="stack flex w-full max-w-timeline flex-col gap-2">
          <div class="bubble rounded-[10px] border border-orange-400/30 bg-[color:var(--surface-summary)] p-2.5">
            <div class="flex gap-2.5 align-top">
              <div class="mt-0.5 shrink-0 text-base opacity-60">&#x21BB;</div>
              <div class="min-w-0 flex-1">
                <div class="mb-1 text-xs font-semibold text-orange-500">
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
        <div class="stack flex w-full max-w-timeline flex-col gap-2">
          <div class="bubble rounded-[10px] border border-red-500/20 bg-red-500/10 p-2.5">
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
          <div class="stack flex w-full max-w-timeline flex-col gap-2">
            <div class="bubble summary rounded-[10px] border border-orange-400/30 bg-[color:var(--surface-summary)] p-2.5">
              <div class="summary-title mb-1.5 text-xs font-semibold text-orange-500">
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
        <div class="stack flex w-full max-w-timeline flex-col gap-2">
          <div class="bubble user relative break-words rounded-[10px] bg-[color:var(--surface-user)] p-2.5 text-[color:var(--surface-user-text)]">
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
      <span class="inline-block rounded px-[7px] py-px text-[9px] font-semibold leading-snug bg-violet-500/25">
        {inPart} / {fmtTok(outT)} out
      </span>
    );
  }

  const cardTone = isAgentDispatch
    ? 'border border-teal-500/40 bg-teal-500/10 shadow-[inset_0_0_0_1px_rgba(20,184,166,0.16)]'
    : 'bg-[color:var(--surface-assistant)]';

  return (
    <div class="row assistant flex w-full justify-start" id={domId}>
      <div class="stack flex w-full max-w-timeline flex-col gap-2">
        <div
          class={`bubble assistant-card flex flex-col gap-2 break-words rounded-[10px] p-2.5 ${cardTone}`}
        >
          <div
            class={`assistant-header flex min-h-5 items-center gap-2.5 px-0.5 ${isAgentDispatch ? 'border-b border-dashed border-teal-500/30 pb-1.5' : ''}`}
          >
            <span class="text-xs font-bold leading-none text-[color:var(--muted)]">
              {payload.assistantLabel || 'Assistant'}
            </span>
            {!isAgentDispatch && payload.specialTag ? (
              <span class="pill special text-xs">{payload.specialTag}</span>
            ) : null}
            {payload.modelTitle ? (
              <span class="pill inline-block rounded-full bg-[color:var(--button)] px-2.5 py-1 text-xs">
                {payload.modelTitle}
              </span>
            ) : null}
          </div>
          {payload.thinking ? (
            <div class="rounded-[10px] bg-[color:var(--surface-thinking)] px-2.5 py-2">
              <div class="mb-1.5 text-xs font-semibold text-[color:var(--muted)]">
                {payload.thinkingTitle || 'Thinking'}
              </div>
              <MessageBody content={payload.thinking} options={{ markdownTone: 'assistant' }} />
            </div>
          ) : null}
          {renderToolSection(tools, useFlatToolBody, payload.contextLabel || 'Context')}
          {payload.content ? (
            <div class="rounded-[10px] px-2.5 py-2">
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
