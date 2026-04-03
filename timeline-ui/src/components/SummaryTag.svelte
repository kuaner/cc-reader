<script lang="ts">
  const base =
    'inline-block rounded px-1.5 py-px text-[9px] font-bold tracking-wide leading-snug border';

  let { label }: { label: string } = $props();
</script>

<span
  class={`${base} border-transparent bg-[color:var(--tag-summary-bg)] text-[color:var(--tag-summary-text)]`}
>
  {label}
</span>
