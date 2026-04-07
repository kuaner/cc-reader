<script lang="ts">
  import Pill from "./Pill.svelte";

  let { label }: { label: string } = $props();
</script>

<Pill
  {label}
  class="border-transparent bg-(--tag-summary-bg) text-(--tag-summary-text)"
/>
