<script lang="ts">
  function readEmptyI18n(): { title: string; hint: string } {
    const i18n = typeof window !== 'undefined' ? window.__CCREADER_I18N__ : undefined;
    return {
      title: i18n?.emptyTitle ?? 'No messages',
      hint: i18n?.emptyHint ?? '',
    };
  }

  const { title, hint } = readEmptyI18n();
</script>

<div class="timeline-empty" role="status">
  <h2 class="timeline-empty-title">{title}</h2>
  {#if hint}
    <p class="timeline-empty-hint">{hint}</p>
  {/if}
</div>
