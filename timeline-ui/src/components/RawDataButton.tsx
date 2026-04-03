import type { JSX } from 'preact';
import { encodeBase64Utf8 } from '../lib/strings';
import type { MessagePayload } from '../types';

export function RawDataButton({
  payload,
  class: className,
}: {
  payload: MessagePayload;
  class?: string;
}): JSX.Element | null {
  const raw = String(payload.rawData || '');
  if (!raw) return null;
  const encoded = encodeBase64Utf8(raw);
  const rawLabel = payload.rawDataLabel || 'Raw Data';
  return (
    <button
      type="button"
      class={['message-copy-button', className].filter(Boolean).join(' ')}
      data-message-copy-base64={encoded}
      data-copy-label={rawLabel}
    >
      {rawLabel}
    </button>
  );
}
