<script lang="ts">
  import { looksLikeMarkdown } from "../../lib/strings";
  import type { MessageBodyOptions } from "../../lib/messageBodyOptions";
  import type { MessagePayload } from "../../types";
  import BubbleFooter from "./BubbleFooter.svelte";
  import ErrorTag from "./ErrorTag.svelte";
  import MessageBody from "./MessageBody.svelte";
import Pill from "./Pill.svelte";
  import SummaryTag from "./SummaryTag.svelte";
  import ToolResultImages from "./ToolResultImages.svelte";
  import ToolSection from "./ToolSection.svelte";
  import TypeTags from "./TypeTags.svelte";

  let { payload }: { payload: MessagePayload } = $props();

  function fmtTok(n: number): string {
    return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
  }

  const domId = $derived(payload.domId || "");
  const timestamp = $derived(payload.timeLabel || "");

  const isAgentDispatch = $derived(payload.bubbleKind === "agent_dispatch");
  const isToolOnly = $derived(payload.renderMode === "tool_only");
  const useFlatToolBody = $derived(isAgentDispatch || isToolOnly);
  const tools = $derived(Array.isArray(payload.tools) ? payload.tools : []);
  const tagRole = $derived(isAgentDispatch ? "dispatch" : "assistant");

  const inT = $derived(payload.inputTokens ?? 0);
  const outT = $derived(payload.outputTokens ?? 0);
  const cacheR = $derived(payload.cacheReadTokens ?? 0);

  const usageInPart = $derived.by(() => {
    if (inT <= 0 && outT <= 0) return "";
    let inPart = `${fmtTok(inT)} in`;
    if (cacheR > 0) {
      inPart += ` (${fmtTok(cacheR)} cached)`;
    }
    return `${inPart} / ${fmtTok(outT)} out`;
  });

  const showUsage = $derived(inT > 0 || outT > 0);

  const cardTone = $derived(
    isAgentDispatch
      ? "border border-[color:var(--bubble-dispatch-border)] bg-[color:var(--bubble-dispatch-bg)] shadow-[inset_0_0_0_1px_var(--bubble-dispatch-inset)]"
      : "border border-[color:var(--bubble-assistant-border)] bg-[color:var(--surface-assistant)]",
  );

  const userTags = $derived(
    Array.isArray(payload.metaTags) ? payload.metaTags : [],
  );
  const hasToolResultTag = $derived(
    userTags.some((tag) => String(tag || "").toLowerCase() === "tool_result"),
  );
  const toolResultShouldRenderMarkdown = $derived(
    hasToolResultTag && looksLikeMarkdown(payload.content || ""),
  );

  const bodyOpts = $derived.by((): MessageBodyOptions | undefined => {
    if (!payload.isUser) return undefined;
    if (hasToolResultTag) {
      return {
        preserveLineBreaks: !toolResultShouldRenderMarkdown,
        renderMarkdown: toolResultShouldRenderMarkdown,
        markdownTone: "user",
      };
    }
    return { markdownTone: "user" };
  });
</script>

{#if payload.isCompactSummary}
  <div class="row flex w-full justify-start" id={domId}>
    <div class="stack flex w-full max-w-timeline flex-col gap-2.5">
      <div
        class="bubble rounded-2xl border border-(--border-summary) bg-(--surface-summary) px-4 py-3"
      >
        <div class="flex gap-2.5 align-top">
          <div class="mt-0.5 shrink-0 text-base opacity-60">&#x21BB;</div>
          <div class="min-w-0 flex-1">
            <div class="cc-typo-label mb-0.5 text-(--accent-summary-fg)">
              {payload.summaryLabel || "Conversation summarized"}
            </div>
            <MessageBody
              content={payload.content || ""}
              options={{ markdownTone: "summary" }}
            />
          </div>
        </div>
        <BubbleFooter {timestamp} copyPayload={payload}>
          <SummaryTag label={payload.legendSummary || "Summary"} />
        </BubbleFooter>
      </div>
    </div>
  </div>
{:else if payload.isApiError}
  <div class="row flex w-full justify-start" id={domId}>
    <div class="stack flex w-full max-w-timeline flex-col gap-2.5">
      <div
        class="bubble rounded-2xl border border-(--accent-error-border) bg-(--accent-error-bg) px-4 py-3"
      >
        <BubbleFooter {timestamp} copyPayload={payload}>
          <ErrorTag label={payload.legendLabel || "API Error"} />
          {#if payload.specialTag}
            <ErrorTag label={payload.specialTag} />
          {/if}
        </BubbleFooter>
      </div>
    </div>
  </div>
{:else if payload.isUser}
  {#if payload.isSummary}
    <div class="row user flex w-full justify-end" id={domId}>
      <div class="stack flex w-full max-w-timeline flex-col items-end gap-2.5">
        <div
          class="bubble summary w-fit max-w-[min(100%,52rem)] rounded-2xl border border-(--border-summary) bg-(--surface-summary) px-4 py-3"
        >
          <div class="summary-title cc-typo-label mb-1 text-(--accent-summary-fg)">
            {payload.summaryLabel || "Summary"}
          </div>
          <MessageBody
            content={payload.content || ""}
            options={{ ...bodyOpts, markdownTone: "summary" }}
          />
          <ToolResultImages {payload} />
          <BubbleFooter userStyle={false} {timestamp} copyPayload={payload}>
            <SummaryTag label={payload.legendSummary || "Summary"} />
          </BubbleFooter>
        </div>
      </div>
    </div>
  {:else}
    <div class="row user flex w-full justify-end" id={domId}>
      <div class="stack flex w-full max-w-timeline flex-col items-end gap-2.5">
        <div
          class="bubble user relative w-fit max-w-[min(100%,52rem)] wrap-break-word rounded-2xl rounded-br-lg border border-(--bubble-user-rim) border-l-4 border-l-(--bubble-user-accent) bg-(--surface-user) px-4 py-3 text-(--surface-user-text) shadow-[0_2px_6px_rgba(0,0,0,0.07)]"
        >
          <MessageBody content={payload.content || ""} options={bodyOpts} />
          <ToolResultImages {payload} />
          <BubbleFooter userStyle {timestamp} copyPayload={payload}>
            <TypeTags
              {payload}
              fallbackLabel={payload.legendUser || "User"}
              role="user"
            />
            {#if payload.specialTag}
              <Pill
                label={payload.specialTag}
                class="pill agent-id cc-typo-chip cursor-pointer rounded-full bg-(--button) px-2.5 border-transparent"
                dataSessionId={payload.specialTag}
              />
            {/if}
          </BubbleFooter>
        </div>
      </div>
    </div>
  {/if}
{:else}
  <div class="row assistant flex w-full justify-start" id={domId}>
    <div class="stack flex w-full max-w-timeline flex-col gap-2.5">
      <div
        class={`bubble assistant-card ${isAgentDispatch ? "tone-dispatch" : "tone-assistant"} flex max-w-[min(100%,52rem)] flex-col gap-2.5 wrap-break-word rounded-2xl px-4 py-3 ${cardTone}`}
      >
        <div
          class={`assistant-header border-b px-0.5 pb-2 ${
            isAgentDispatch
              ? "border-dashed border-(--bubble-dispatch-header-border)"
              : "border-(--border)"
          }`}
        >
          <span class="cc-typo-masthead inline-flex h-7 shrink-0 items-center text-(--muted)">
            {payload.assistantLabel || "Assistant"}
          </span>
          {#if !isAgentDispatch && payload.specialTag}
            <span class="pill special">{payload.specialTag}</span>
          {/if}
          {#if payload.modelTitle}
            <span
              class="pill shrink-0 rounded-full bg-(--button) text-(--text)"
            >
              {payload.modelTitle}
            </span>
          {/if}
        </div>
        {#if payload.thinking}
          <div class="rounded-lg bg-(--surface-thinking) px-2.5 py-2">
            <div class="cc-typo-label mb-1.5 text-(--muted)">
              {payload.thinkingTitle || "Thinking"}
            </div>
            <MessageBody
              content={payload.thinking}
              options={{ markdownTone: "assistant" }}
            />
          </div>
        {/if}
        <ToolSection
          {tools}
          {useFlatToolBody}
          contextLabel={payload.contextLabel || "Context"}
        />
        {#if payload.content}
          <div class="rounded-lg px-0.5 py-1">
            <MessageBody
              content={payload.content}
              options={{ markdownTone: "assistant" }}
            />
          </div>
        {/if}
        <BubbleFooter {timestamp} copyPayload={payload}>
          <TypeTags
            {payload}
            fallbackLabel={payload.legendLabel ||
              payload.legendAssistant ||
              "Assistant"}
            role={tagRole}
          />
          {#if showUsage}
            <span
              class="cc-typo-caption inline-block min-w-0 max-w-full wrap-break-word rounded bg-(--usage-token-bg) px-1.5 py-px text-(--usage-token-text)"
            >
              {usageInPart}
            </span>
          {/if}
        </BubbleFooter>
      </div>
    </div>
  </div>
{/if}
