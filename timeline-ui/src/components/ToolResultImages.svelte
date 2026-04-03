<script lang="ts">
  import { escapeHTML } from '../lib/strings';
  import type { MessagePayload } from '../types';

  let { payload }: { payload: MessagePayload } = $props();

  const images = $derived(Array.isArray(payload.resultImages) ? payload.resultImages : []);
  const items = $derived(images.filter((item) => String(item?.base64 || '')));
</script>

{#if items.length > 0}
  <div class="mt-2 flex flex-col gap-2">
    {#each items as item (String(item?.base64 || '').slice(0, 24))}
      {@const base64 = String(item?.base64 || '')}
      {@const mediaType = escapeHTML(String(item?.mediaType || 'image/png'))}
      <div
        class="flex h-[220px] w-[min(360px,100%)] items-center justify-center overflow-hidden rounded-[10px] border border-[color:var(--border)] bg-[color:var(--attachment-bg)]"
      >
        <img
          class="block h-full w-full object-contain"
          src={`data:${mediaType};base64,${base64}`}
          loading="lazy"
          alt=""
        />
      </div>
    {/each}
  </div>
{/if}
