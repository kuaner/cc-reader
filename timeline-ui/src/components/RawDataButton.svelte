<script lang="ts">
  import { copyCodeText, getCcreaderI18n, prettifyMessageCopyText } from '../lib/clipboardCopy';
  import { decodeUtf8Base64 } from '../lib/decodeUtf8Base64';
  import { encodeBase64Utf8 } from '../lib/strings';
  import type { MessagePayload } from '../types';

  let {
    payload,
    class: className,
  }: {
    payload: MessagePayload;
    class?: string;
  } = $props();

  const raw = $derived(String(payload.rawData || ''));
  const encoded = $derived(raw ? encodeBase64Utf8(raw) : '');
  const rawLabel = $derived(payload.rawDataLabel || 'Raw Data');
</script>

{#if raw}
  <button
    type="button"
    class={['message-copy-button', className].filter(Boolean).join(' ')}
    onclick={(e) => {
      const btn = e.currentTarget as HTMLButtonElement;
      let text = '';
      try {
        text = decodeUtf8Base64(encoded);
      } catch (err) {
        console.error('decode raw data failed', err);
        return;
      }
      const { copied } = getCcreaderI18n();
      copyCodeText(prettifyMessageCopyText(text))
        .then(() => {
          btn.textContent = copied;
          btn.classList.add('is-copied');
          window.setTimeout(() => {
            btn.textContent = rawLabel;
            btn.classList.remove('is-copied');
          }, 1600);
        })
        .catch((err) => {
          console.error('copy raw data failed', err);
        });
    }}
  >
    {rawLabel}
  </button>
{/if}
