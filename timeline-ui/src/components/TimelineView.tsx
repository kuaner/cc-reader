import type { JSX } from 'preact';
import { messageRowKey } from '../lib/strings';
import type { TimelineState } from '../types';
import { MessageRow } from './MessageRow';
import { TimelineEmpty } from './TimelineEmpty';

/**
 * Real block wrapper (not `display: contents`) — WKWebView mis-resolves % widths / flex stretch for
 * descendants of `contents`, so `#load-older-bar.topbar` stayed shrink-wrapped left. `w-full min-w-0`
 * matches `.timeline` flex children and lets injected HTML use full row width.
 */
function ChromeSlot({ html }: { html: string }): JSX.Element {
  return <div class="ccreader-chrome-slot w-full min-w-0" dangerouslySetInnerHTML={{ __html: html }} />;
}

export function TimelineView({ state }: { state: TimelineState }): JSX.Element {
  const hasChrome = Boolean(state.loadOlderHTML || state.waitingHTML);
  const showEmpty = state.messages.length === 0 && !hasChrome;

  return (
    <>
      {state.loadOlderHTML ? <ChromeSlot html={state.loadOlderHTML} /> : null}
      {state.messages.map((p) => (
        <MessageRow key={messageRowKey(p)} payload={p} />
      ))}
      {state.waitingHTML ? <ChromeSlot html={state.waitingHTML} /> : null}
      {showEmpty ? <TimelineEmpty /> : null}
    </>
  );
}
