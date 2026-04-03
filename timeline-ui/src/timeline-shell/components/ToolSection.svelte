<script lang="ts">
  import type { ToolPayload } from "../../types";
  import MessageBody from "./MessageBody.svelte";

  let {
    tools,
    useFlatToolBody,
    contextLabel,
  }: {
    tools: ToolPayload[];
    useFlatToolBody: boolean;
    contextLabel: string;
  } = $props();
</script>

{#snippet toolItems()}
  {#each tools as tool, i (i)}
    <div>
      <div
        class="mb-1 text-[9px] font-bold uppercase tracking-[0.12em] text-(--muted)"
      >
        {tool.title || ""}
      </div>
      {#if tool.body}
        {#if String(tool.renderStyle || "") === "markdown"}
          <MessageBody
            content={tool.body}
            options={{ markdownTone: "assistant" }}
          />
        {:else}
          <pre
            class="my-2.5 whitespace-pre-wrap wrap-break-word rounded-xl bg-(--code-bg) p-3 font-mono text-xs leading-normal">{tool.body}</pre>
        {/if}
      {/if}
    </div>
  {/each}
{/snippet}

{#if tools.length > 0}
  {#if useFlatToolBody}
    <div class="rounded-xl p-0">
      {@render toolItems()}
    </div>
  {:else}
    <div class="rounded-xl bg-(--surface-tool) px-2.5 py-2">
      <div
        class="mb-1 text-[9px] font-bold uppercase tracking-[0.12em] text-(--muted)"
      >
        {contextLabel}
      </div>
      {@render toolItems()}
    </div>
  {/if}
{/if}
