<script lang="ts">
  import Pill from "./Pill.svelte";

  let { label }: { label: string } = $props();
</script>

<Pill
  {label}
  class="border-transparent bg-(--tag-error-bg) text-(--tag-error-text)"
/>
