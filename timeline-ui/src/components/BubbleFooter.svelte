<script lang="ts">
  import type { Snippet } from 'svelte';
  import type { MessagePayload } from '../types';
  import RawDataButton from './RawDataButton.svelte';

  const footerBase =
    'bubble-footer mt-2 flex min-h-7 flex-wrap items-center gap-x-2 gap-y-1.5 border-t pt-2 text-[11px] font-medium';

  let {
    timestamp,
    copyPayload,
    userStyle = false,
    children,
  }: {
    timestamp: string;
    copyPayload: MessagePayload;
    userStyle?: boolean;
    children: Snippet;
  } = $props();

  const borderMuted = $derived(
    userStyle
      ? 'border-[color:var(--bubble-user-footer-border)] text-[color:var(--bubble-user-footer-muted)]'
      : 'border-[color:var(--border)] text-[color:var(--muted)]',
  );
</script>

<div class={`${footerBase} ${borderMuted}`}>
  <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-1.5 gap-y-1">
    <span class="shrink-0">{timestamp}</span>
    {@render children()}
  </div>
  <RawDataButton payload={copyPayload} class="shrink-0 ml-auto" />
</div>
