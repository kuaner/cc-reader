import type { JSX } from 'preact';
import { messageRowKey } from '../lib/strings';
import type { TimelineState } from '../types';
import { MessageRow } from './MessageRow';

/** `display: contents` so Swift-injected chrome participates in `.timeline` flex like direct children. */
function ChromeSlot({ html }: { html: string }): JSX.Element {
  return <div style={{ display: 'contents' }} dangerouslySetInnerHTML={{ __html: html }} />;
}

export function TimelineView({ state }: { state: TimelineState }): JSX.Element {
  return (
    <>
      {state.loadOlderHTML ? <ChromeSlot html={state.loadOlderHTML} /> : null}
      {state.messages.map((p) => (
        <MessageRow key={messageRowKey(p)} payload={p} />
      ))}
      {state.waitingHTML ? <ChromeSlot html={state.waitingHTML} /> : null}
    </>
  );
}
