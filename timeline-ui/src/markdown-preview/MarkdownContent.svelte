<script lang="ts">
  import { renderMarkdownToHtml, highlightCodeBlocksIn } from './markdown';

  let {
    content,
    fallbackClass,
  }: {
    content: string;
    fallbackClass: string;
  } = $props();

  let root = $state<HTMLDivElement | null>(null);

  const source = $derived(String(content || ''));
  const renderResult = $derived.by(() => {
    if (!source) return { html: '', failed: false };
    try {
      return { html: renderMarkdownToHtml(source), failed: false };
    } catch (error) {
      console.error('markdown render failed', error);
      return { html: '', failed: true };
    }
  });

  $effect(() => {
    if (!root || !renderResult.html || renderResult.failed) return;
    highlightCodeBlocksIn(root);
  });
</script>

{#if renderResult.failed}
  <div class={fallbackClass}>{source}</div>
{:else}
  <div bind:this={root}>{@html renderResult.html}</div>
{/if}

