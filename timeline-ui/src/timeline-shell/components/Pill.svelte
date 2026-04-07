<script lang="ts">
  const base =
    "cc-typo-caption inline-flex min-h-5 items-center rounded px-1.5 py-0 border leading-none tracking-normal";

  let {
    label,
    class: className = "",
    dataSessionId,
  }: {
    label: string;
    class?: string;
    dataSessionId?: string;
  } = $props();
</script>

<span
  class={[base, className].filter(Boolean).join(" ")}
  data-cc-session-id={dataSessionId}
>
  {label}
</span>
