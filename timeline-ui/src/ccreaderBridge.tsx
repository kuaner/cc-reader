import { render } from 'preact';
import type { MessagePayload, PrependOlderOpts, ReplaceTimelineOpts, TimelineState } from './types';
import { TimelineView } from './components/TimelineView';
import { enhanceSubtree } from './markdown';

function getTimeline(): HTMLElement | null {
  return document.querySelector('.timeline');
}

/** Set by Swift in `timeline-shell.html` boot script before this bundle runs. */
function followBottomThreshold(): number {
  const w = (window as unknown as { __FOLLOW_BOTTOM_THRESHOLD__?: number }).__FOLLOW_BOTTOM_THRESHOLD__;
  if (typeof w === 'number' && Number.isFinite(w)) return w;
  return 96;
}

function isNearBottom(): boolean {
  return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - followBottomThreshold();
}

let timelineMount: HTMLElement | null = null;
const state: TimelineState = {
  messages: [],
  loadOlderHTML: '',
  waitingHTML: '',
};

function commit(): void {
  const el = timelineMount ?? getTimeline();
  if (!el) return;
  timelineMount = el;
  render(<TimelineView state={state} />, el);
  enhanceSubtree(el);
}

function scrollBottomStable(): void {
  let attempts = 0;
  let lastH = -1;

  function scrollStep(): void {
    attempts++;
    const h = document.documentElement.scrollHeight;

    const timeline = getTimeline();
    const lastNode = timeline?.lastElementChild ?? null;
    if (lastNode && typeof lastNode.scrollIntoView === 'function') {
      lastNode.scrollIntoView(false);
    } else {
      window.scrollTo(0, h);
    }

    if (attempts < 8 && h !== lastH) {
      lastH = h;
      window.requestAnimationFrame(scrollStep);
    } else {
      const finalTimeline = getTimeline();
      const finalLast = finalTimeline?.lastElementChild ?? null;
      if (finalLast && typeof finalLast.scrollIntoView === 'function') {
        finalLast.scrollIntoView(false);
      } else {
        window.scrollTo(0, document.documentElement.scrollHeight);
      }
    }
  }

  window.requestAnimationFrame(scrollStep);
}

export function installCcreader(): void {
  const ccreader = (window.ccreader = window.ccreader || {}) as Window['ccreader'];

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
    commit();

    const scrollHeightAfter = document.documentElement.scrollHeight;
    window.scrollTo(0, scrollYBefore + (scrollHeightAfter - scrollHeightBefore));

    if (opts.removeOlderBar) {
      state.loadOlderHTML = '';
      commit();
    }
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

  const scrollState = { followingBottom: true, ticking: false };

  function emitScrollState(): void {
    const following = isNearBottom();
    if (following !== scrollState.followingBottom) {
      scrollState.followingBottom = following;
      window.webkit?.messageHandlers.ccreader.postMessage({
        action: 'scrollState',
        following,
      });
    }
  }

  window.addEventListener(
    'scroll',
    function () {
      if (scrollState.ticking) return;
      scrollState.ticking = true;
      window.requestAnimationFrame(function () {
        scrollState.ticking = false;
        emitScrollState();
      });
    },
    { passive: true },
  );

  document.addEventListener('click', function (e) {
    const target = e.target as HTMLElement | null;
    const pill = target?.closest?.('.agent-id[data-cc-session-id]') as HTMLElement | null;
    if (pill) {
      const sessionId = pill.getAttribute('data-cc-session-id');
      if (sessionId) {
        window.webkit?.messageHandlers.ccreader.postMessage({
          action: 'navigateToSession',
          sessionId,
        });
      }
    }
  });

  (function resizePin(): void {
    let resizeTimer: ReturnType<typeof setTimeout> | null = null;
    let rafId: number | null = null;
    let wasFollowing = false;

    function pinToBottom(): void {
      window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'auto' });
      rafId = requestAnimationFrame(pinToBottom);
    }

    window.addEventListener('resize', function () {
      if (!resizeTimer) {
        wasFollowing = scrollState.followingBottom;
        if (wasFollowing && rafId == null) {
          rafId = requestAnimationFrame(pinToBottom);
        }
      }
      if (resizeTimer) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(function () {
        resizeTimer = null;
        if (rafId != null) {
          cancelAnimationFrame(rafId);
          rafId = null;
        }
        if (wasFollowing) {
          window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'auto' });
        }
        emitScrollState();
      }, 300);
    });
  })();
}
