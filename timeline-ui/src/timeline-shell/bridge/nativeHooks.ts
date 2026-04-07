import { isNearBottom } from './scroll';

export function installNativeHooks(): void {
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
