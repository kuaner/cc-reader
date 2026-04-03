import type { MessagePayload, PrependOlderOpts, ReplaceTimelineOpts } from '../types';
import { commit, state } from './timelineState';
import { isNearBottom, scrollBottomStable } from './scroll';

export function registerCcreaderApi(ccreader: Window['ccreader']): void {
  ccreader.scrollBottomStable = scrollBottomStable;

  ccreader.replaceTimelineFromPayloads = function (opts: ReplaceTimelineOpts): void {
    const payloads = Array.isArray(opts.messages) ? opts.messages : [];
    state.messages = payloads.slice();
    state.loadOlderHTML = String(opts.loadOlderBarHTML || '');
    state.waitingHTML = String(opts.waitingHTML || '');
    commit();
    scrollBottomStable();
  };

  ccreader.replaceTimelineFromPayloadsProgressive = function (opts: ReplaceTimelineOpts): void {
    const payloads = Array.isArray(opts.messages) ? opts.messages : [];
    if (payloads.length === 0) {
      ccreader.replaceTimelineFromPayloads?.(opts);
      return;
    }

    let initialLatestCount = Number(opts.initialLatestCount || 18);
    let prependChunkSize = Number(opts.prependChunkSize || 16);
    initialLatestCount = Math.max(1, initialLatestCount);
    prependChunkSize = Math.max(1, prependChunkSize);

    const tailStart = Math.max(0, payloads.length - initialLatestCount);
    const latestTail = payloads.slice(tailStart);
    ccreader.replaceTimelineFromPayloads?.({
      messages: latestTail,
      loadOlderBarHTML: opts.loadOlderBarHTML,
      waitingHTML: opts.waitingHTML,
    });

    const olderHead = payloads.slice(0, tailStart);
    if (olderHead.length === 0) return;

    let cursor = olderHead.length;
    function prependStep(): void {
      if (cursor <= 0) return;
      const start = Math.max(0, cursor - prependChunkSize);
      const chunk = olderHead.slice(start, cursor);
      ccreader.prependOlderFromPayloads?.({ messages: chunk, removeOlderBar: false });
      cursor = start;
      if (cursor > 0) {
        window.requestAnimationFrame(prependStep);
      }
    }

    window.requestAnimationFrame(prependStep);
  };

  ccreader.prependOlderFromPayloads = function (opts: PrependOlderOpts): void {
    const payloads = Array.isArray(opts.messages) ? opts.messages : [];
    if (payloads.length === 0) return;

    const scrollHeightBefore = document.documentElement.scrollHeight;
    const scrollYBefore = window.scrollY;

    state.messages = [...payloads, ...state.messages];
    if (opts.removeOlderBar) {
      state.loadOlderHTML = '';
    }
    commit();

    const scrollHeightAfter = document.documentElement.scrollHeight;
    window.scrollTo(0, scrollYBefore + (scrollHeightAfter - scrollHeightBefore));
  };

  ccreader.appendMessagesFromPayload = function (payloads: MessagePayload[]): void {
    if (!Array.isArray(payloads) || payloads.length === 0) return;
    const wasAtBottom = isNearBottom();

    state.messages = [...state.messages, ...payloads];
    commit();

    if (wasAtBottom) {
      window.scrollTo(0, document.body.scrollHeight);
    }
  };

  ccreader.replaceMessagesFromPayload = function (payloads: MessagePayload[]): void {
    if (!Array.isArray(payloads) || payloads.length === 0) return;
    const wasAtBottom = isNearBottom();
    for (let i = 0; i < payloads.length; i++) {
      const payload = payloads[i];
      const domId = payload?.domId;
      if (!domId) continue;
      const idx = state.messages.findIndex((m) => m.domId === domId);
      if (idx >= 0) {
        state.messages[idx] = payload;
      }
    }
    commit();
    if (wasAtBottom) {
      scrollBottomStable();
    }
  };

  ccreader.setWaitingIndicator = function (htmlOrEmpty: string): void {
    state.waitingHTML = htmlOrEmpty || '';
    commit();
    if (isNearBottom()) {
      window.scrollTo(0, document.body.scrollHeight);
    }
  };

  ccreader.setLoadOlderBar = function (htmlOrEmpty: string): void {
    state.loadOlderHTML = htmlOrEmpty || '';
    commit();
  };
}
