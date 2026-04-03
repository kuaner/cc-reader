<script lang="ts">
  import { messageRowKey } from '../lib/strings';
  import type { TimelineState } from '../types';
  import MessageRow from './MessageRow.svelte';
  import TimelineEmpty from './TimelineEmpty.svelte';

  let { state }: { state: TimelineState } = $props();

  const hasChrome = $derived(Boolean(state.loadOlderHTML || state.waitingHTML));
  const showEmpty = $derived(state.messages.length === 0 && !hasChrome);
</script>

{#if state.loadOlderHTML}
  <div class="ccreader-chrome-slot w-full min-w-0">{@html state.loadOlderHTML}</div>
{/if}
{#each state.messages as p (messageRowKey(p))}
  <MessageRow payload={p} />
{/each}
{#if state.waitingHTML}
  <div class="ccreader-chrome-slot w-full min-w-0">{@html state.waitingHTML}</div>
{/if}
{#if showEmpty}
  <TimelineEmpty />
{/if}
