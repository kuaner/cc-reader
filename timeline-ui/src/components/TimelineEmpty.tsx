import type { JSX } from 'preact';

function readEmptyI18n(): { title: string; hint: string } {
  const i18n = typeof window !== 'undefined' ? window.__CCREADER_I18N__ : undefined;
  return {
    title: i18n?.emptyTitle ?? 'No messages',
    hint: i18n?.emptyHint ?? '',
  };
}

/** Empty session: no rows yet (Inspector — not a reading view). */
export function TimelineEmpty(): JSX.Element {
  const { title, hint } = readEmptyI18n();
  return (
    <div class="timeline-empty" role="status">
      <h2 class="timeline-empty-title">{title}</h2>
      {hint ? <p class="timeline-empty-hint">{hint}</p> : null}
    </div>
  );
}
