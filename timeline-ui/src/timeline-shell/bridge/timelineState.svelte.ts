import { mount, tick } from 'svelte';
import TimelineView from '../components/TimelineView.svelte';
import { getTimeline } from './scroll';
import type { MessagePayload } from '../../types';

export const state = $state({
  messages: [] as MessagePayload[],
  loadOlderHTML: '',
  waitingHTML: '',
});

let timelineMount: HTMLElement | null = null;
let instance: ReturnType<typeof mount> | null = null;

/**
 * Waits for Svelte to flush `$state` into the DOM (Preact `render` was synchronous).
 * Without `tick()`, follow-up scroll logic can run against stale layout —
 * long timelines look like a mid-page pause then a snap to the bottom.
 */
export async function commit(): Promise<void> {
  const el = timelineMount ?? getTimeline();
  if (!el) return;
  timelineMount = el;
  if (!instance) {
    instance = mount(TimelineView, { target: el, props: { state } });
  }
  await tick();
}
