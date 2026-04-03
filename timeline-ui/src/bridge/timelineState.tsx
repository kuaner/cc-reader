import { render } from 'preact';
import { TimelineView } from '../components/TimelineView';
import { enhanceSubtree } from '../markdown/markdown';
import type { TimelineState } from '../types';
import { getTimeline } from './scroll';

let timelineMount: HTMLElement | null = null;

export const state: TimelineState = {
  messages: [],
  loadOlderHTML: '',
  waitingHTML: '',
};

export function commit(): void {
  const el = timelineMount ?? getTimeline();
  if (!el) return;
  timelineMount = el;
  render(<TimelineView state={state} />, el);
  enhanceSubtree(el);
}
