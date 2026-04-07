<script lang="ts">
  const base =
    "cc-typo-caption inline-block rounded px-1.5 py-px leading-snug border";

  let { label }: { label: string } = $props();
</script>

<span
  class={`${base} border-transparent bg-(--tag-summary-bg) text-(--tag-summary-text)`}
>
  {label}
</span>
