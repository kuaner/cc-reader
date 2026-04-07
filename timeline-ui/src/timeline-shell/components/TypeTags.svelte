<script lang="ts">
  import Pill from "./Pill.svelte";
  import type { MessagePayload } from "../../types";

  type Role = "user" | "assistant" | "dispatch";

  let {
    payload,
    fallbackLabel,
    role,
  }: {
    payload: MessagePayload;
    fallbackLabel?: string;
    role: Role;
  } = $props();

  function classesForTag(payload: MessagePayload, tag: string, role: Role): string {
    const token = String(tag || '').toLowerCase();
    if (!payload.isUser && token === 'tool_use') {
      return "border-[color:var(--tag-tool-use-border)] bg-[color:var(--tag-tool-use-bg)] text-[color:var(--tag-tool-use-text)]";
    }
    if (payload.isUser && token === 'tool_result') {
      return "border-[color:var(--tag-tool-result-border)] bg-[color:var(--tag-tool-result-bg)] text-[color:var(--tag-tool-result-text)]";
    }
    if (role === 'user') {
      return "border-transparent bg-[color:var(--tag-user-bg)] text-[color:var(--tag-user-text)]";
    }
    if (role === 'dispatch') {
      return "border-[color:var(--tag-dispatch-border)] bg-[color:var(--tag-dispatch-bg)] text-[color:var(--tag-dispatch-text)]";
    }
    return "border-transparent bg-[color:var(--tag-assistant-bg)] text-[color:var(--tag-assistant-text)]";
  }

  const tags = $derived(Array.isArray(payload.metaTags) ? payload.metaTags : []);
</script>

{#if tags.length === 0}
  <Pill
    label={fallbackLabel || "Assistant"}
    class={classesForTag(payload, "", role)}
  />
{:else}
  {#each tags as tag (String(tag))}
    <Pill
      label={String(tag)}
      class={classesForTag(payload, String(tag), role)}
    />
  {/each}
{/if}
