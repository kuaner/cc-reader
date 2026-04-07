<script lang="ts">
  import type { MessagePayload } from '../../types';

  type Role = 'user' | 'assistant' | 'dispatch';

  const base =
    'cc-typo-caption inline-block rounded px-1.5 py-px leading-snug border';

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

  const tags = $derived(Array.isArray(payload.metaTags) ? payload.metaTags : []);
</script>

{#if tags.length === 0}
  <span class={classesForTag(payload, '', role)}>{fallbackLabel || 'Assistant'}</span>
{:else}
  {#each tags as tag (String(tag))}
    <span class={classesForTag(payload, String(tag), role)}>{tag}</span>
  {/each}
{/if}
