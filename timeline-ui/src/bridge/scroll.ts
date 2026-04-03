export function getTimeline(): HTMLElement | null {
  return document.querySelector('.timeline');
}

/** Set by Swift in `timeline-shell.html` boot script before this bundle runs. */
export function followBottomThreshold(): number {
  const w = window.__FOLLOW_BOTTOM_THRESHOLD__;
  if (typeof w === 'number' && Number.isFinite(w)) return w;
  return 96;
}

export function isNearBottom(): boolean {
  return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - followBottomThreshold();
}

export function scrollBottomStable(): void {
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
