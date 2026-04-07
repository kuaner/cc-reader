<script lang="ts">
  import MarkdownContent from "../../markdown-preview/MarkdownContent.svelte";
  import type {
    MessageBodyOptions,
    MarkdownTone,
  } from "../../lib/messageBodyOptions";

  let {
    content,
    options,
  }: {
    content: string;
    options?: MessageBodyOptions;
  } = $props();

  const preserveLineBreaks = $derived(options?.preserveLineBreaks === true);
  const renderMarkdown = $derived(options?.renderMarkdown !== false);
  const tone = $derived(options?.markdownTone ?? "assistant");
  const source = $derived(String(content || ""));

  function proseForTone(t: MarkdownTone): string {
    const readability = [
      "max-w-[min(100%,65ch)]",
      "cc-typo-md-leading",
      "break-words",
      "[&_p]:my-[0.45em] [&_p:first-child]:mt-0 [&_p:last-child]:mb-0",
      "[&_li]:my-0.5",
      "[&_a]:font-medium [&_a]:underline [&_a]:underline-offset-[3px] [&_a]:transition-colors",
    ].join(" ");

    if (t === "user") {
      return [
        "markdown",
        "prose",
        "prose-ccreader-user",
        "text-[color:var(--surface-user-text)]",
        readability,
        "[&_a]:decoration-[color:color-mix(in_srgb,var(--bubble-user-link)_40%,transparent)]",
        "[&_a:hover]:decoration-[color:color-mix(in_srgb,var(--bubble-user-link)_75%,transparent)]",
        "[&_pre]:bg-transparent [&_pre]:rounded-xl [&_pre]:overflow-hidden",
        "[&_pre_code]:bg-transparent",
        "[&_:not(pre)>code]:rounded-md [&_:not(pre)>code]:bg-[color:var(--bubble-user-inline-code-bg)] [&_:not(pre)>code]:text-[color:var(--bubble-user-inline-code-fg)] [&_:not(pre)>code]:px-1 [&_:not(pre)>code]:py-px",
        "[&_blockquote]:border-[color:var(--bubble-user-blockquote-border)]",
      ].join(" ");
    }
    return [
      "markdown",
      "prose",
      "prose-ccreader-assistant",
      "text-[color:var(--text)]",
      readability,
      "[&_a]:decoration-[color:color-mix(in_srgb,var(--accent-link)_35%,transparent)]",
      "[&_a:hover]:decoration-[color:color-mix(in_srgb,var(--accent-link)_65%,transparent)]",
      "[&_th]:border-[color:var(--border)]",
      "[&_td]:border-[color:var(--border)]",
      "[&_:not(pre)>code]:rounded-md [&_:not(pre)>code]:bg-[color:var(--assistant-inline-code-bg)] [&_:not(pre)>code]:text-[color:var(--assistant-inline-code-fg)] [&_:not(pre)>code]:px-1 [&_:not(pre)>code]:py-px",
    ].join(" ");
  }

  const plainUserClass = $derived(
    tone === "user" ? "text-[color:var(--surface-user-text)]" : "",
  );

  const plainBlockClass = $derived(
    preserveLineBreaks
      ? `max-w-[min(100%,65ch)] whitespace-pre-wrap break-words cc-typo-plain-mono ${plainUserClass}`
      : `max-w-[min(100%,65ch)] whitespace-pre-wrap break-words cc-typo-plain ${plainUserClass}`,
  );

  const emptyClass = $derived(
    [
      "whitespace-pre-wrap break-words",
      tone === "user" ? "text-[color:var(--surface-user-text)]" : "",
    ]
      .filter(Boolean)
      .join(" "),
  );
</script>

{#if !source}
  <div class={emptyClass}></div>
{:else if preserveLineBreaks || !renderMarkdown}
  <div class={plainBlockClass}>{source}</div>
{:else}
  <div class={proseForTone(tone)}>
    <MarkdownContent content={source} fallbackClass={plainBlockClass} />
  </div>
{/if}
