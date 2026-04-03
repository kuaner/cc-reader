import type { JSX } from 'preact';
import { escapeHTML } from '../lib/strings';
import type { MessagePayload } from '../types';

export function ToolResultImages({ payload }: { payload: MessagePayload }): JSX.Element | null {
  const images = Array.isArray(payload.resultImages) ? payload.resultImages : [];
  if (images.length === 0) return null;
  const items = images
    .map((item) => {
      const base64 = String(item?.base64 || '');
      if (!base64) return null;
      const mediaType = escapeHTML(String(item?.mediaType || 'image/png'));
      return (
        <div
          class="flex h-[220px] w-[min(360px,100%)] items-center justify-center overflow-hidden rounded-[10px] border border-[color:var(--border)] bg-[color:var(--attachment-bg)]"
          key={base64.slice(0, 24)}
        >
          <img class="block h-full w-full object-contain" src={`data:${mediaType};base64,${base64}`} loading="lazy" alt="" />
        </div>
      );
    })
    .filter(Boolean);
  if (items.length === 0) return null;
  return <div class="mt-2 flex flex-col gap-2">{items}</div>;
}
